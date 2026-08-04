#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: generate_quay_lab_mass.sh
#
# Objetivo:
#   Criar massa de teste no Quay PRD e configurar mirrors no Quay DR.
#
# O que ele faz:
#   - cria organizations no PRD e DR
#   - cria repositories no PRD e DR
#   - cria robot account no DR por organization
#   - dá permissão do robot nos repos do DR
#   - cria imagens/tags no PRD
#   - configura repository mirror no DR apontando para o PRD
#   - executa sync-cancel + sync-now
#   - opcionalmente aguarda sync_status estabilizar
#
# Requisitos:
#   - bash
#   - curl
#   - jq
#   - podman
#
# Tokens:
#   PRD token precisa conseguir criar org/repo e consultar repo.
#   DR token precisa criar org/repo/robot, permissões e mirror config.
#
# Segurança:
#   Por padrão cria apenas orgs com prefixo qsync-lab.
###############################################################################

###############################################################################
# Variáveis obrigatórias
###############################################################################

: "${QUAY_PRD_URL:?Informe QUAY_PRD_URL. Ex: https://quay-prd.apps.cluster.com}"
: "${QUAY_DR_URL:?Informe QUAY_DR_URL. Ex: https://quay-dr.apps.cluster.com}"

: "${QUAY_PRD_API_TOKEN:?Informe QUAY_PRD_API_TOKEN}"
: "${QUAY_DR_API_TOKEN:?Informe QUAY_DR_API_TOKEN}"

: "${QUAY_PRD_PUSH_USER:?Informe QUAY_PRD_PUSH_USER. Ex: quayadmin ou org+robot}"
: "${QUAY_PRD_PUSH_PASSWORD:?Informe QUAY_PRD_PUSH_PASSWORD}"

# Credencial que o mirror do DR usará para puxar do PRD.
# Se não informar, usa a mesma credencial do push.
QUAY_PRD_PULL_USER="${QUAY_PRD_PULL_USER:-$QUAY_PRD_PUSH_USER}"
QUAY_PRD_PULL_PASSWORD="${QUAY_PRD_PULL_PASSWORD:-$QUAY_PRD_PUSH_PASSWORD}"

###############################################################################
# Variáveis opcionais
###############################################################################

TLS_VERIFY="${TLS_VERIFY:-false}"

LAB_ORG_PREFIX="${LAB_ORG_PREFIX:-qsync-lab}"
LAB_ORG_COUNT="${LAB_ORG_COUNT:-6}"

QUAY_DR_ROBOT_SHORTNAME="${QUAY_DR_ROBOT_SHORTNAME:-quay_sync}"

REPO_VISIBILITY="${REPO_VISIBILITY:-private}"

MIRROR_SYNC_INTERVAL="${MIRROR_SYNC_INTERVAL:-86400}"
MIRROR_SKOPEO_TIMEOUT="${MIRROR_SKOPEO_TIMEOUT:-600}"
MIRROR_VERIFY_TLS="${MIRROR_VERIFY_TLS:-false}"

TRIGGER_MIRROR="${TRIGGER_MIRROR:-true}"
CANCEL_BEFORE_SYNC="${CANCEL_BEFORE_SYNC:-true}"
WAIT_FOR_SYNC="${WAIT_FOR_SYNC:-true}"
SYNC_POLL_RETRIES="${SYNC_POLL_RETRIES:-20}"
SYNC_POLL_DELAY="${SYNC_POLL_DELAY:-15}"

# Se true, cria novas imagens com novo conteúdo.
# Isso é útil para gerar DIGEST_MISMATCH depois.
GENERATE_NEW_DIGESTS="${GENERATE_NEW_DIGESTS:-true}"

# Proteção para não mexer em orgs fora do prefixo de lab.
ALLOW_NON_LAB_ORGS="${ALLOW_NON_LAB_ORGS:-false}"

# Quando true, não cria orgs. Útil se você quiser criar manualmente pela UI.
SKIP_ORG_CREATE="${SKIP_ORG_CREATE:-false}"

# Quando true, não cria repos. Útil para testar só push/mirror em repos já existentes.
SKIP_REPO_CREATE="${SKIP_REPO_CREATE:-false}"

# Tenta payload alternativo de root_rule se o Quay rejeitar o primeiro formato.
TRY_MIRROR_PAYLOAD_FALLBACK="${TRY_MIRROR_PAYLOAD_FALLBACK:-true}"

###############################################################################
# Definição da massa
#
# Formato:
#   repo|filtro_do_mirror|tags
#
# Exemplos:
#   backend|*|latest,v1,v2,release-1,dev-1
#   api|release-*|release-1,release-2,dev-1
###############################################################################

REPO_SPECS_DEFAULT=(
  "backend|*|latest,v1,v2,release-1,dev-1"
  "frontend|*|latest,v1,release-1,feature-1"
  "api|release-*|release-1,release-2,dev-1,dev-2"
  "worker|v*|v1,v2,v3,latest,release-1"
  "batch|stable-*|stable-1,stable-2,canary-1,dev-1"
  "reports|*|latest,v1,v2,v3"
)

###############################################################################
# Funções utilitárias
###############################################################################

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERRO: comando obrigatório não encontrado: $cmd" >&2
    exit 1
  fi
}

normalize_url() {
  local raw="$1"
  raw="${raw%/}"
  echo "$raw"
}

normalize_host() {
  local raw="$1"
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%/}"
  echo "$raw"
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

log() {
  echo
  echo "======================================================================"
  echo "$*"
  echo "======================================================================"
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERRO] $*" >&2
  exit 1
}

api_call() {
  local base_url="$1"
  local token="$2"
  local method="$3"
  local path="$4"
  local body="${5:-}"

  local tmp
  tmp="$(mktemp)"

  if [ -n "$body" ]; then
    API_STATUS="$(
      curl -ksS \
        -o "$tmp" \
        -w "%{http_code}" \
        -X "$method" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "${base_url}${path}"
    )"
  else
    API_STATUS="$(
      curl -ksS \
        -o "$tmp" \
        -w "%{http_code}" \
        -X "$method" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        "${base_url}${path}"
    )"
  fi

  API_CONTENT="$(cat "$tmp")"
  rm -f "$tmp"
}

api_prd() {
  api_call "$QUAY_PRD_URL_NORM" "$QUAY_PRD_API_TOKEN" "$@"
}

api_dr() {
  api_call "$QUAY_DR_URL_NORM" "$QUAY_DR_API_TOKEN" "$@"
}

status_is_ok() {
  local status="$1"
  shift
  local accepted
  for accepted in "$@"; do
    if [ "$status" = "$accepted" ]; then
      return 0
    fi
  done
  return 1
}

ensure_org() {
  local side="$1"
  local org="$2"

  if [ "$ALLOW_NON_LAB_ORGS" != "true" ] && [[ "$org" != "${LAB_ORG_PREFIX}"* ]]; then
    fail "Org '$org' não começa com prefixo '${LAB_ORG_PREFIX}'. Ajuste LAB_ORG_PREFIX ou use ALLOW_NON_LAB_ORGS=true."
  fi

  if [ "$SKIP_ORG_CREATE" = "true" ]; then
    info "[$side] Pulando criação da org $org"
    return 0
  fi

  if [ "$side" = "PRD" ]; then
    api_prd GET "/api/v1/organization/${org}"
  else
    api_dr GET "/api/v1/organization/${org}"
  fi

  if [ "$API_STATUS" = "200" ]; then
    info "[$side] Org já existe: $org"
    return 0
  fi

  local payload
  payload="$(jq -nc --arg name "$org" --arg email "${org}@example.com" \
    '{name: $name, email: $email}')"

  if [ "$side" = "PRD" ]; then
    api_prd POST "/api/v1/organization/" "$payload"
  else
    api_dr POST "/api/v1/organization/" "$payload"
  fi

  if status_is_ok "$API_STATUS" 200 201; then
    info "[$side] Org criada: $org"
  elif [ "$API_STATUS" = "400" ]; then
    warn "[$side] Criação da org $org retornou 400. Pode já existir. Resposta: $API_CONTENT"
  else
    fail "[$side] Falha ao criar org $org. HTTP=$API_STATUS Resposta=$API_CONTENT"
  fi
}

ensure_repo() {
  local side="$1"
  local org="$2"
  local repo="$3"

  if [ "$SKIP_REPO_CREATE" = "true" ]; then
    info "[$side] Pulando criação do repo $org/$repo"
    return 0
  fi

  if [ "$side" = "PRD" ]; then
    api_prd GET "/api/v1/repository/${org}/${repo}"
  else
    api_dr GET "/api/v1/repository/${org}/${repo}"
  fi

  if [ "$API_STATUS" = "200" ]; then
    info "[$side] Repo já existe: $org/$repo"
    return 0
  fi

  local payload
  payload="$(jq -nc \
    --arg namespace "$org" \
    --arg repository "$repo" \
    --arg visibility "$REPO_VISIBILITY" \
    --arg description "Repository criado pelo seed de massa do Quay Sync Manager" \
    '{
      namespace: $namespace,
      repository: $repository,
      visibility: $visibility,
      description: $description,
      repo_kind: "image"
    }')"

  if [ "$side" = "PRD" ]; then
    api_prd POST "/api/v1/repository" "$payload"
  else
    api_dr POST "/api/v1/repository" "$payload"
  fi

  if status_is_ok "$API_STATUS" 200 201; then
    info "[$side] Repo criado: $org/$repo"
  elif [ "$API_STATUS" = "400" ]; then
    warn "[$side] Criação do repo $org/$repo retornou 400. Pode já existir. Resposta: $API_CONTENT"
  else
    fail "[$side] Falha ao criar repo $org/$repo. HTTP=$API_STATUS Resposta=$API_CONTENT"
  fi
}

ensure_dr_robot() {
  local org="$1"
  local robot_short="$2"

  api_dr GET "/api/v1/organization/${org}/robots/${robot_short}"

  if [ "$API_STATUS" = "200" ]; then
    info "[DR] Robot já existe: ${org}+${robot_short}"
    return 0
  fi

  local payload
  payload="$(jq -nc \
    --arg description "Robot usado pelo repository mirror PRD -> DR no lab" \
    '{description: $description}')"

  api_dr PUT "/api/v1/organization/${org}/robots/${robot_short}" "$payload"

  if status_is_ok "$API_STATUS" 200 201; then
    info "[DR] Robot criado: ${org}+${robot_short}"
  elif [ "$API_STATUS" = "400" ]; then
    warn "[DR] Criação do robot ${org}+${robot_short} retornou 400. Pode já existir. Resposta: $API_CONTENT"
  else
    fail "[DR] Falha ao criar robot ${org}+${robot_short}. HTTP=$API_STATUS Resposta=$API_CONTENT"
  fi
}

grant_dr_robot_repo_admin() {
  local org="$1"
  local repo="$2"
  local robot_short="$3"
  local robot_full="${org}+${robot_short}"
  local robot_encoded
  robot_encoded="$(urlencode "$robot_full")"

  local payload
  payload="$(jq -nc '{role: "admin"}')"

  api_dr PUT "/api/v1/repository/${org}/${repo}/permissions/user/${robot_encoded}" "$payload"

  if status_is_ok "$API_STATUS" 200 201; then
    info "[DR] Permissão admin aplicada para ${robot_full} em ${org}/${repo}"
  elif [ "$API_STATUS" = "400" ]; then
    warn "[DR] Permissão para ${robot_full} em ${org}/${repo} retornou 400. Resposta: $API_CONTENT"
  else
    fail "[DR] Falha ao aplicar permissão do robot em ${org}/${repo}. HTTP=$API_STATUS Resposta=$API_CONTENT"
  fi
}

build_and_push_image() {
  local org="$1"
  local repo="$2"
  local tag="$3"

  local image_ref="${QUAY_PRD_HOST}/${org}/${repo}:${tag}"
  local build_dir="${WORKDIR}/${org}-${repo}-${tag}"
  mkdir -p "$build_dir"

  cat > "${build_dir}/payload.txt" <<EOF
quay sync manager mass test
org=${org}
repo=${repo}
tag=${tag}
run_id=${RUN_ID}
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
generate_new_digests=${GENERATE_NEW_DIGESTS}
EOF

  cat > "${build_dir}/Containerfile" <<EOF
FROM scratch
LABEL org.opencontainers.image.title="Quay Sync Manager mass test ${org}/${repo}:${tag}"
LABEL quay.lab.org="${org}"
LABEL quay.lab.repo="${repo}"
LABEL quay.lab.tag="${tag}"
LABEL quay.lab.run_id="${RUN_ID}"
COPY payload.txt /payload.txt
EOF

  info "[PRD] Build ${image_ref}"
  podman build -q -f "${build_dir}/Containerfile" -t "${image_ref}" "${build_dir}" >/dev/null

  info "[PRD] Push ${image_ref}"
  podman push --tls-verify="${TLS_VERIFY}" "${image_ref}" >/dev/null
}

mirror_payload_kind_rule_value() {
  local org="$1"
  local repo="$2"
  local filter_csv="$3"
  local rule_value_json="$4"
  local external_ref="${QUAY_PRD_HOST}/${org}/${repo}"
  local robot_username="${org}+${QUAY_DR_ROBOT_SHORTNAME}"

  jq -nc \
    --arg external_reference "$external_ref" \
    --arg external_registry_username "$QUAY_PRD_PULL_USER" \
    --arg external_registry_password "$QUAY_PRD_PULL_PASSWORD" \
    --arg sync_start_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson sync_interval "$MIRROR_SYNC_INTERVAL" \
    --arg robot_username "$robot_username" \
    --argjson skopeo_timeout_interval "$MIRROR_SKOPEO_TIMEOUT" \
    --argjson rule_value "$rule_value_json" \
    --argjson verify_tls "$MIRROR_VERIFY_TLS" \
    '{
      is_enabled: true,
      external_reference: $external_reference,
      external_registry_username: $external_registry_username,
      external_registry_password: $external_registry_password,
      sync_start_date: $sync_start_date,
      sync_interval: $sync_interval,
      robot_username: $robot_username,
      skopeo_timeout_interval: $skopeo_timeout_interval,
      root_rule: {
        rule_kind: "tag_glob_csv",
        rule_value: $rule_value
      },
      external_registry_config: {
        verify_tls: $verify_tls,
        unsigned_images: false,
        proxy: {
          http_proxy: null,
          https_proxy: null,
          no_proxy: null
        }
      }
    }'
}

mirror_payload_docs_rule() {
  local org="$1"
  local repo="$2"
  local filter_csv="$3"
  local external_ref="${QUAY_PRD_HOST}/${org}/${repo}"
  local robot_username="${org}+${QUAY_DR_ROBOT_SHORTNAME}"

  jq -nc \
    --arg external_reference "$external_ref" \
    --arg external_registry_username "$QUAY_PRD_PULL_USER" \
    --arg external_registry_password "$QUAY_PRD_PULL_PASSWORD" \
    --arg sync_start_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson sync_interval "$MIRROR_SYNC_INTERVAL" \
    --arg robot_username "$robot_username" \
    --argjson skopeo_timeout_interval "$MIRROR_SKOPEO_TIMEOUT" \
    --arg rule "$filter_csv" \
    --argjson verify_tls "$MIRROR_VERIFY_TLS" \
    '{
      is_enabled: true,
      external_reference: $external_reference,
      external_registry_username: $external_registry_username,
      external_registry_password: $external_registry_password,
      sync_start_date: $sync_start_date,
      sync_interval: $sync_interval,
      robot_username: $robot_username,
      skopeo_timeout_interval: $skopeo_timeout_interval,
      root_rule: {
        rule: $rule,
        rule_type: "tag_glob_csv"
      },
      external_registry_config: {
        verify_tls: $verify_tls,
        unsigned_images: false,
        proxy: {
          http_proxy: null,
          https_proxy: null,
          no_proxy: null
        }
      }
    }'
}

configure_repo_mirror() {
  local org="$1"
  local repo="$2"
  local filter_csv="$3"

  local rule_value_json
  rule_value_json="$(jq -nc --arg csv "$filter_csv" '$csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"

  local payload
  payload="$(mirror_payload_kind_rule_value "$org" "$repo" "$filter_csv" "$rule_value_json")"

  api_dr GET "/api/v1/repository/${org}/${repo}/mirror"

  local method
  local expected_success
  if [ "$API_STATUS" = "200" ]; then
    method="PUT"
    expected_success="200 201"
    info "[DR] Mirror já existe, atualizando: ${org}/${repo} filtro=${filter_csv}"
  else
    method="POST"
    expected_success="200 201"
    info "[DR] Criando mirror: ${org}/${repo} -> ${QUAY_PRD_HOST}/${org}/${repo} filtro=${filter_csv}"
  fi

  api_dr "$method" "/api/v1/repository/${org}/${repo}/mirror" "$payload"

  if status_is_ok "$API_STATUS" 200 201; then
    info "[DR] Mirror configurado: ${org}/${repo}"
    return 0
  fi

  warn "[DR] Mirror ${org}/${repo} falhou com formato rule_kind/rule_value. HTTP=$API_STATUS Resposta=$API_CONTENT"

  if [ "$TRY_MIRROR_PAYLOAD_FALLBACK" = "true" ]; then
    warn "[DR] Tentando payload alternativo root_rule.rule/root_rule.rule_type para ${org}/${repo}"
    payload="$(mirror_payload_docs_rule "$org" "$repo" "$filter_csv")"
    api_dr "$method" "/api/v1/repository/${org}/${repo}/mirror" "$payload"

    if status_is_ok "$API_STATUS" 200 201; then
      info "[DR] Mirror configurado com payload alternativo: ${org}/${repo}"
      return 0
    fi
  fi

  fail "[DR] Falha ao configurar mirror ${org}/${repo}. HTTP=$API_STATUS Resposta=$API_CONTENT"
}

trigger_repo_sync() {
  local org="$1"
  local repo="$2"

  if [ "$CANCEL_BEFORE_SYNC" = "true" ]; then
    api_dr POST "/api/v1/repository/${org}/${repo}/mirror/sync-cancel" ""
    if status_is_ok "$API_STATUS" 200 201 202 204 400 404; then
      info "[DR] sync-cancel ${org}/${repo}: HTTP=$API_STATUS"
    else
      warn "[DR] sync-cancel ${org}/${repo} retornou HTTP=$API_STATUS Resposta=$API_CONTENT"
    fi
  fi

  api_dr POST "/api/v1/repository/${org}/${repo}/mirror/sync-now" ""
  if status_is_ok "$API_STATUS" 200 201 202 204; then
    info "[DR] sync-now ${org}/${repo}: HTTP=$API_STATUS"
  else
    fail "[DR] sync-now falhou para ${org}/${repo}. HTTP=$API_STATUS Resposta=$API_CONTENT"
  fi
}

wait_for_sync() {
  local repos_file="$1"

  log "Aguardando sync_status dos mirrors"

  local attempt
  for attempt in $(seq 1 "$SYNC_POLL_RETRIES"); do
    local pending=0
    local failed=0
    local success=0

    while IFS='|' read -r org repo filter; do
      [ -z "$org" ] && continue

      api_dr GET "/api/v1/repository/${org}/${repo}/mirror"

      if [ "$API_STATUS" != "200" ]; then
        warn "[DR] Não foi possível consultar mirror ${org}/${repo}. HTTP=$API_STATUS"
        pending=$((pending + 1))
        continue
      fi

      local status
      status="$(echo "$API_CONTENT" | jq -r '.sync_status // "UNKNOWN"')"

      case "$status" in
        SUCCESS)
          success=$((success + 1))
          ;;
        FAIL|FAILED|ERROR)
          failed=$((failed + 1))
          ;;
        *)
          pending=$((pending + 1))
          ;;
      esac
    done < "$repos_file"

    info "Tentativa ${attempt}/${SYNC_POLL_RETRIES}: SUCCESS=${success} PENDENTE=${pending} FALHA=${failed}"

    if [ "$pending" -eq 0 ]; then
      if [ "$failed" -gt 0 ]; then
        warn "Alguns mirrors terminaram com falha. Verifique a UI/logs do Quay."
      fi
      return 0
    fi

    sleep "$SYNC_POLL_DELAY"
  done

  warn "Timeout aguardando sync dos mirrors após $((SYNC_POLL_RETRIES * SYNC_POLL_DELAY)) segundos."
}

###############################################################################
# Pré-check
###############################################################################

require_cmd curl
require_cmd jq
require_cmd podman

QUAY_PRD_URL_NORM="$(normalize_url "$QUAY_PRD_URL")"
QUAY_DR_URL_NORM="$(normalize_url "$QUAY_DR_URL")"

QUAY_PRD_HOST="$(normalize_host "$QUAY_PRD_URL_NORM")"
QUAY_DR_HOST="$(normalize_host "$QUAY_DR_URL_NORM")"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d)"
MIRROR_REPOS_FILE="${WORKDIR}/mirror_repos.txt"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

log "Configuração"
cat <<EOF
PRD URL                : ${QUAY_PRD_URL_NORM}
DR URL                 : ${QUAY_DR_URL_NORM}
PRD HOST               : ${QUAY_PRD_HOST}
DR HOST                : ${QUAY_DR_HOST}
LAB_ORG_PREFIX         : ${LAB_ORG_PREFIX}
LAB_ORG_COUNT          : ${LAB_ORG_COUNT}
DR ROBOT               : +${QUAY_DR_ROBOT_SHORTNAME}
TLS_VERIFY             : ${TLS_VERIFY}
TRIGGER_MIRROR         : ${TRIGGER_MIRROR}
WAIT_FOR_SYNC          : ${WAIT_FOR_SYNC}
RUN_ID                 : ${RUN_ID}
EOF

###############################################################################
# Login no PRD para push
###############################################################################

log "Login no Quay PRD para push"

podman login \
  --tls-verify="${TLS_VERIFY}" \
  -u "${QUAY_PRD_PUSH_USER}" \
  -p "${QUAY_PRD_PUSH_PASSWORD}" \
  "${QUAY_PRD_HOST}"

###############################################################################
# Criar massa
###############################################################################

log "Criando organizations, repositories, imagens e mirrors"

for i in $(seq 1 "$LAB_ORG_COUNT"); do
  org="${LAB_ORG_PREFIX}-$(printf '%02d' "$i")"

  log "Organization ${org}"

  ensure_org "PRD" "$org"
  ensure_org "DR" "$org"

  ensure_dr_robot "$org" "$QUAY_DR_ROBOT_SHORTNAME"

  for spec in "${REPO_SPECS_DEFAULT[@]}"; do
    IFS='|' read -r repo filter_csv tags_csv <<< "$spec"

    info "Preparando ${org}/${repo} filtro=${filter_csv} tags=${tags_csv}"

    ensure_repo "PRD" "$org" "$repo"
    ensure_repo "DR" "$org" "$repo"

    grant_dr_robot_repo_admin "$org" "$repo" "$QUAY_DR_ROBOT_SHORTNAME"

    IFS=',' read -ra tags <<< "$tags_csv"
    for tag in "${tags[@]}"; do
      tag="$(echo "$tag" | xargs)"
      [ -z "$tag" ] && continue
      build_and_push_image "$org" "$repo" "$tag"
    done

    configure_repo_mirror "$org" "$repo" "$filter_csv"

    echo "${org}|${repo}|${filter_csv}" >> "$MIRROR_REPOS_FILE"

    if [ "$TRIGGER_MIRROR" = "true" ]; then
      trigger_repo_sync "$org" "$repo"
    fi
  done
done

###############################################################################
# Aguardar sync, se habilitado
###############################################################################

if [ "$TRIGGER_MIRROR" = "true" ] && [ "$WAIT_FOR_SYNC" = "true" ]; then
  wait_for_sync "$MIRROR_REPOS_FILE"
fi

###############################################################################
# Resumo final
###############################################################################

log "Resumo final"

total_orgs="$LAB_ORG_COUNT"
total_repos_per_org="${#REPO_SPECS_DEFAULT[@]}"
total_repos=$((total_orgs * total_repos_per_org))

echo "Organizations criadas/atualizadas: ${total_orgs}"
echo "Repositories por organization     : ${total_repos_per_org}"
echo "Repositories mirrored totais      : ${total_repos}"

echo
echo "Namespaces para usar na automação Quay Sync Manager:"
echo
echo "quay_discovery_namespaces:"
for i in $(seq 1 "$LAB_ORG_COUNT"); do
  echo "  - ${LAB_ORG_PREFIX}-$(printf '%02d' "$i")"
done

echo
echo "Próximos testes sugeridos:"
echo "1. Rodar Quay Sync Manager em quay_mode=check."
echo "2. Rodar este script novamente com TRIGGER_MIRROR=false para gerar DIGEST_MISMATCH."
echo "3. Rodar Quay Sync Manager em quay_mode=check para validar divergência."
echo "4. Rodar Quay Sync Manager em quay_mode=sync para corrigir."
echo
echo "Exemplo para gerar divergência sem sincronizar:"
echo "  TRIGGER_MIRROR=false WAIT_FOR_SYNC=false ./generate_quay_lab_mass.sh"
