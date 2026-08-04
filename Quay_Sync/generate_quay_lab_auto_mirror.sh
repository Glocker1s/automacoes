#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# generate_quay_lab_auto_mirror.sh
#
# Massa de teste para criação automática de mirrors no Quay DR.
#
# Cenários:
#
# qsync-auto-01
#   baseline         -> PRD + DR MIRROR
#   missing-api      -> somente PRD
#   missing-worker   -> somente PRD
#   conflict-normal  -> PRD + repository NORMAL no DR
#
# qsync-auto-02
#   missing-backend  -> somente PRD
#   missing-frontend -> somente PRD
#   robot mirror NÃO existe no DR
#
# qsync-auto-03
#   missing-reports  -> somente PRD
#   robot mirror JÁ existe no DR
#
# Resultado esperado antes da automação:
#   Repositories PRD:      7
#   Mirrors existentes DR: 1
#   Mirrors ausentes:      5
#   Conflitos no DR:       1
# =============================================================================

# -----------------------------------------------------------------------------
# Variáveis obrigatórias
# -----------------------------------------------------------------------------

: "${QUAY_PRD_URL:?Defina QUAY_PRD_URL}"
: "${QUAY_DR_URL:?Defina QUAY_DR_URL}"

: "${QUAY_PRD_API_TOKEN:?Defina QUAY_PRD_API_TOKEN}"
: "${QUAY_DR_API_TOKEN:?Defina QUAY_DR_API_TOKEN}"

: "${QUAY_PRD_PUSH_USER:?Defina QUAY_PRD_PUSH_USER}"
: "${QUAY_PRD_PUSH_PASSWORD:?Defina QUAY_PRD_PUSH_PASSWORD}"

# -----------------------------------------------------------------------------
# Variáveis opcionais
# -----------------------------------------------------------------------------

TLS_VERIFY="${TLS_VERIFY:-false}"

LAB_ORG_PREFIX="${LAB_ORG_PREFIX:-qsync-auto}"

RESET_LAB="${RESET_LAB:-false}"
CREATE_CONFLICT="${CREATE_CONFLICT:-true}"

DR_ROBOT_SHORT_NAME="${DR_ROBOT_SHORT_NAME:-mirror}"

QUAY_PRD_PULL_USER="${QUAY_PRD_PULL_USER:-$QUAY_PRD_PUSH_USER}"
QUAY_PRD_PULL_PASSWORD="${QUAY_PRD_PULL_PASSWORD:-$QUAY_PRD_PUSH_PASSWORD}"

MIRROR_SYNC_INTERVAL="${MIRROR_SYNC_INTERVAL:-86400}"
MIRROR_SKOPEO_TIMEOUT="${MIRROR_SKOPEO_TIMEOUT:-600}"

TRIGGER_BASELINE_MIRROR="${TRIGGER_BASELINE_MIRROR:-true}"
WAIT_BASELINE_SYNC="${WAIT_BASELINE_SYNC:-true}"
BASELINE_SYNC_RETRIES="${BASELINE_SYNC_RETRIES:-20}"
BASELINE_SYNC_DELAY="${BASELINE_SYNC_DELAY:-10}"

RUN_ID="${RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')}"

QUAY_PRD_URL="${QUAY_PRD_URL%/}"
QUAY_DR_URL="${QUAY_DR_URL%/}"

QUAY_PRD_HOST="${QUAY_PRD_URL#http://}"
QUAY_PRD_HOST="${QUAY_PRD_HOST#https://}"

QUAY_DR_HOST="${QUAY_DR_URL#http://}"
QUAY_DR_HOST="${QUAY_DR_HOST#https://}"

ORG1="${LAB_ORG_PREFIX}-01"
ORG2="${LAB_ORG_PREFIX}-02"
ORG3="${LAB_ORG_PREFIX}-03"

# -----------------------------------------------------------------------------
# Dependências
# -----------------------------------------------------------------------------

for cmd in curl jq podman; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERROR] Comando obrigatório não encontrado: $cmd"
    exit 1
  }
done

# -----------------------------------------------------------------------------
# Helpers gerais
# -----------------------------------------------------------------------------

section() {
  echo
  echo "======================================================================"
  echo "$*"
  echo "======================================================================"
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

CURL_ARGS=(-sS)

if [[ "$TLS_VERIFY" != "true" ]]; then
  CURL_ARGS+=(-k)
fi

PODMAN_TLS_ARGS=()

if [[ "$TLS_VERIFY" != "true" ]]; then
  PODMAN_TLS_ARGS+=(--tls-verify=false)
fi

API_STATUS=""
API_BODY=""

api_call() {
  local method="$1"
  local url="$2"
  local token="$3"
  local data="${4:-}"
  local tmp
  local cmd

  tmp="$(mktemp)"

  cmd=(
    curl
    "${CURL_ARGS[@]}"
    -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/json"
    -o "$tmp"
    -w "%{http_code}"
  )

  if [[ -n "$data" ]]; then
    cmd+=(
      -H "Content-Type: application/json"
      -d "$data"
    )
  fi

  API_STATUS="$("${cmd[@]}" "$url")"
  API_BODY="$(cat "$tmp")"

  rm -f "$tmp"
}

expect_status() {
  local description="$1"
  local allowed="$2"

  if [[ " $allowed " != *" $API_STATUS "* ]]; then
    echo "[ERROR] $description"
    echo "[ERROR] HTTP: $API_STATUS"
    echo "[ERROR] Body: $API_BODY"
    exit 1
  fi
}

# Quay pode retornar:
#
# HTTP 404
#
# ou:
#
# HTTP 400
# {"message":"Could not find robot with specified username"}
#
# quando o robot não existe.
robot_not_found_response() {
  local message=""

  if [[ "$API_STATUS" == "404" ]]; then
    return 0
  fi

  if [[ "$API_STATUS" == "400" ]]; then
    message="$(jq -r '.message // ""' <<< "$API_BODY" 2>/dev/null || true)"
    message="${message,,}"

    if [[ "$message" == *"could not find robot with specified username"* ]]; then
      return 0
    fi
  fi

  return 1
}

# -----------------------------------------------------------------------------
# Organization
# -----------------------------------------------------------------------------

ensure_org() {
  local base_url="$1"
  local token="$2"
  local side="$3"
  local org="$4"
  local encoded_org

  encoded_org="$(urlencode "$org")"

  api_call GET \
    "$base_url/api/v1/organization/$encoded_org" \
    "$token"

  case "$API_STATUS" in
    200)
      info "[$side] Org já existe: $org"
      ;;

    404)
      api_call POST \
        "$base_url/api/v1/organization/" \
        "$token" \
        "$(jq -nc --arg name "$org" '{name:$name}')"

      expect_status "[$side] Falha criando organization $org" "201"
      info "[$side] Org criada: $org"
      ;;

    *)
      die "[$side] Erro consultando organization $org HTTP=$API_STATUS body=$API_BODY"
      ;;
  esac
}

delete_org_if_exists() {
  local base_url="$1"
  local token="$2"
  local side="$3"
  local org="$4"
  local encoded_org

  encoded_org="$(urlencode "$org")"

  api_call GET \
    "$base_url/api/v1/organization/$encoded_org" \
    "$token"

  if [[ "$API_STATUS" == "404" ]]; then
    return
  fi

  expect_status "[$side] Falha consultando organization $org" "200"

  info "[$side] Removendo organization de teste: $org"

  api_call DELETE \
    "$base_url/api/v1/organization/$encoded_org" \
    "$token"

  expect_status "[$side] Falha removendo organization $org" "204"
}

# -----------------------------------------------------------------------------
# Repository
# -----------------------------------------------------------------------------

ensure_repo() {
  local base_url="$1"
  local token="$2"
  local side="$3"
  local org="$4"
  local repo="$5"
  local full_repo="$org/$repo"

  api_call GET \
    "$base_url/api/v1/repository/$full_repo" \
    "$token"

  case "$API_STATUS" in
    200)
      info "[$side] Repo já existe: $full_repo"
      ;;

    404)
      api_call POST \
        "$base_url/api/v1/repository" \
        "$token" \
        "$(jq -nc \
          --arg repository "$repo" \
          --arg namespace "$org" \
          --arg description "Repository de teste Quay Sync Manager - $RUN_ID" \
          '{
            repository:$repository,
            namespace:$namespace,
            visibility:"private",
            description:$description
          }')"

      expect_status "[$side] Falha criando repository $full_repo" "201"
      info "[$side] Repo criado: $full_repo"
      ;;

    *)
      die "[$side] Erro consultando repository $full_repo HTTP=$API_STATUS body=$API_BODY"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Robot
# -----------------------------------------------------------------------------

robot_exists() {
  local org="$1"
  local short_name="$2"
  local full_robot="$org+$short_name"
  local encoded_org
  local encoded_robot

  encoded_org="$(urlencode "$org")"
  encoded_robot="$(urlencode "$short_name")"

  api_call GET \
    "$QUAY_DR_URL/api/v1/organization/$encoded_org/robots/$encoded_robot" \
    "$QUAY_DR_API_TOKEN"

  if [[ "$API_STATUS" == "200" ]]; then
    return 0
  fi

  if robot_not_found_response; then
    return 1
  fi

  die "[DR] Erro consultando robot $full_robot HTTP=$API_STATUS body=$API_BODY"
}

ensure_robot() {
  local org="$1"
  local short_name="$2"
  local full_robot="$org+$short_name"
  local encoded_org
  local encoded_robot

  encoded_org="$(urlencode "$org")"
  encoded_robot="$(urlencode "$short_name")"

  api_call GET \
    "$QUAY_DR_URL/api/v1/organization/$encoded_org/robots/$encoded_robot" \
    "$QUAY_DR_API_TOKEN"

  if [[ "$API_STATUS" == "200" ]]; then
    info "[DR] Robot já existe: $full_robot"
    return
  fi

  if ! robot_not_found_response; then
    die "[DR] Erro consultando robot $full_robot HTTP=$API_STATUS body=$API_BODY"
  fi

  info "[DR] Robot não encontrado. Criando: $full_robot"

  api_call PUT \
    "$QUAY_DR_URL/api/v1/organization/$encoded_org/robots/$encoded_robot" \
    "$QUAY_DR_API_TOKEN" \
    "$(jq -nc \
      --arg description "Robot de teste Quay Sync Manager" \
      '{description:$description}')"

  expect_status "[DR] Falha criando robot $full_robot" "200 201"

  info "[DR] Robot criado: $full_robot"
}

# -----------------------------------------------------------------------------
# Permissão robot -> repository
# -----------------------------------------------------------------------------

set_robot_permission() {
  local org="$1"
  local repo="$2"
  local short_name="$3"
  local role="${4:-write}"
  local full_repo="$org/$repo"
  local robot="$org+$short_name"
  local encoded_robot

  encoded_robot="$(urlencode "$robot")"

  api_call PUT \
    "$QUAY_DR_URL/api/v1/repository/$full_repo/permissions/user/$encoded_robot" \
    "$QUAY_DR_API_TOKEN" \
    "$(jq -nc --arg role "$role" '{role:$role}')"

  expect_status "[DR] Falha aplicando permissão $role para $robot em $full_repo" "200"

  info "[DR] Permissão $role aplicada para $robot em $full_repo"
}

# -----------------------------------------------------------------------------
# Mirror
# -----------------------------------------------------------------------------

configure_mirror() {
  local org="$1"
  local repo="$2"
  local robot_short_name="$3"
  local full_repo="$org/$repo"
  local robot="$org+$robot_short_name"
  local source_ref="$QUAY_PRD_HOST/$full_repo"
  local sync_start
  local payload

  sync_start="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  payload="$(jq -nc \
    --arg external_reference "$source_ref" \
    --arg external_registry_username "$QUAY_PRD_PULL_USER" \
    --arg external_registry_password "$QUAY_PRD_PULL_PASSWORD" \
    --arg sync_start_date "$sync_start" \
    --arg robot_username "$robot" \
    --argjson sync_interval "$MIRROR_SYNC_INTERVAL" \
    --argjson skopeo_timeout_interval "$MIRROR_SKOPEO_TIMEOUT" \
    '{
      is_enabled:true,
      external_reference:$external_reference,
      external_registry_username:$external_registry_username,
      external_registry_password:$external_registry_password,
      sync_start_date:$sync_start_date,
      sync_interval:$sync_interval,
      robot_username:$robot_username,
      skopeo_timeout_interval:$skopeo_timeout_interval,
      root_rule:{
        rule_kind:"tag_glob_csv",
        rule_value:["*"]
      }
    }')"

  api_call GET \
    "$QUAY_DR_URL/api/v1/repository/$full_repo/mirror" \
    "$QUAY_DR_API_TOKEN"

  case "$API_STATUS" in
    200)
      info "[DR] Mirror já existe, atualizando: $full_repo"

      api_call PUT \
        "$QUAY_DR_URL/api/v1/repository/$full_repo/mirror" \
        "$QUAY_DR_API_TOKEN" \
        "$payload"

      expect_status "[DR] Falha atualizando mirror $full_repo" "200 201"
      ;;

    404)
      api_call POST \
        "$QUAY_DR_URL/api/v1/repository/$full_repo/mirror" \
        "$QUAY_DR_API_TOKEN" \
        "$payload"

      expect_status "[DR] Falha criando mirror $full_repo" "201"
      ;;

    *)
      die "[DR] Falha consultando mirror $full_repo HTTP=$API_STATUS body=$API_BODY"
      ;;
  esac

  info "[DR] Mirror configurado: $full_repo root_rule=*"
}

trigger_sync() {
  local org="$1"
  local repo="$2"
  local full_repo="$org/$repo"

  api_call POST \
    "$QUAY_DR_URL/api/v1/repository/$full_repo/mirror/sync-now" \
    "$QUAY_DR_API_TOKEN"

  expect_status "[DR] Falha executando sync-now $full_repo" "200 201 202 204"

  info "[DR] sync-now executado: $full_repo"
}

wait_sync() {
  local org="$1"
  local repo="$2"
  local full_repo="$org/$repo"
  local attempt
  local status

  for ((attempt=1; attempt<=BASELINE_SYNC_RETRIES; attempt++)); do
    api_call GET \
      "$QUAY_DR_URL/api/v1/repository/$full_repo/mirror" \
      "$QUAY_DR_API_TOKEN"

    if [[ "$API_STATUS" != "200" ]]; then
      warn "[DR] Falha consultando status $full_repo HTTP=$API_STATUS"
      sleep "$BASELINE_SYNC_DELAY"
      continue
    fi

    status="$(jq -r '.sync_status // "UNKNOWN"' <<< "$API_BODY")"

    info "[DR] $full_repo sync_status=$status tentativa=$attempt/$BASELINE_SYNC_RETRIES"

    if [[ "$status" == "SUCCESS" ]]; then
      return 0
    fi

    sleep "$BASELINE_SYNC_DELAY"
  done

  warn "[DR] Baseline não retornou SUCCESS dentro do tempo. Continuando."
}

# -----------------------------------------------------------------------------
# Build/push de imagens
# -----------------------------------------------------------------------------

BUILD_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$BUILD_DIR"
}

trap cleanup EXIT

push_test_tag() {
  local org="$1"
  local repo="$2"
  local tag="$3"
  local image="$QUAY_PRD_HOST/$org/$repo:$tag"

  cat > "$BUILD_DIR/payload.txt" <<EOF
quay-sync-manager-test
run_id=$RUN_ID
organization=$org
repository=$repo
tag=$tag
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

  cat > "$BUILD_DIR/Containerfile" <<'EOF'
FROM scratch
COPY payload.txt /payload.txt
EOF

  info "[PRD] Build $image"

  podman build \
    --no-cache \
    -f "$BUILD_DIR/Containerfile" \
    -t "$image" \
    "$BUILD_DIR" >/dev/null

  info "[PRD] Push $image"

  podman push \
    "${PODMAN_TLS_ARGS[@]}" \
    "$image"

  podman rmi "$image" >/dev/null 2>&1 || true
}

prepare_source_repo() {
  local org="$1"
  local repo="$2"

  ensure_repo \
    "$QUAY_PRD_URL" \
    "$QUAY_PRD_API_TOKEN" \
    "PRD" \
    "$org" \
    "$repo"

  push_test_tag "$org" "$repo" "latest"
  push_test_tag "$org" "$repo" "v1"
  push_test_tag "$org" "$repo" "release-1"
}

# =============================================================================
# Configuração
# =============================================================================

section "Configuração"

echo "PRD URL                : $QUAY_PRD_URL"
echo "DR URL                 : $QUAY_DR_URL"
echo "PRD HOST               : $QUAY_PRD_HOST"
echo "DR HOST                : $QUAY_DR_HOST"
echo "LAB_ORG_PREFIX         : $LAB_ORG_PREFIX"
echo "DR ROBOT               : +$DR_ROBOT_SHORT_NAME"
echo "TLS_VERIFY             : $TLS_VERIFY"
echo "RESET_LAB              : $RESET_LAB"
echo "CREATE_CONFLICT         : $CREATE_CONFLICT"
echo "TRIGGER_BASELINE       : $TRIGGER_BASELINE_MIRROR"
echo "WAIT_BASELINE_SYNC     : $WAIT_BASELINE_SYNC"
echo "RUN_ID                 : $RUN_ID"

# =============================================================================
# Reset opcional
# =============================================================================

if [[ "$RESET_LAB" == "true" ]]; then
  section "Resetando massa anterior"

  for org in "$ORG1" "$ORG2" "$ORG3"; do
    delete_org_if_exists \
      "$QUAY_PRD_URL" \
      "$QUAY_PRD_API_TOKEN" \
      "PRD" \
      "$org"

    delete_org_if_exists \
      "$QUAY_DR_URL" \
      "$QUAY_DR_API_TOKEN" \
      "DR" \
      "$org"
  done
fi

# =============================================================================
# Login PRD
# =============================================================================

section "Login no Quay PRD para push"

podman login \
  "${PODMAN_TLS_ARGS[@]}" \
  -u "$QUAY_PRD_PUSH_USER" \
  -p "$QUAY_PRD_PUSH_PASSWORD" \
  "$QUAY_PRD_HOST"

# =============================================================================
# Criar organizations
# =============================================================================

section "Criando organizations"

for org in "$ORG1" "$ORG2" "$ORG3"; do
  ensure_org \
    "$QUAY_PRD_URL" \
    "$QUAY_PRD_API_TOKEN" \
    "PRD" \
    "$org"

  ensure_org \
    "$QUAY_DR_URL" \
    "$QUAY_DR_API_TOKEN" \
    "DR" \
    "$org"
done

# =============================================================================
# ORG 01
#
# baseline        -> mirror já configurado
# missing-api     -> somente PRD
# missing-worker  -> somente PRD
# conflict-normal -> repo normal também existe no DR
# =============================================================================

section "Organization $ORG1"

prepare_source_repo "$ORG1" "baseline"
prepare_source_repo "$ORG1" "missing-api"
prepare_source_repo "$ORG1" "missing-worker"

if [[ "$CREATE_CONFLICT" == "true" ]]; then
  prepare_source_repo "$ORG1" "conflict-normal"
fi

ensure_robot "$ORG1" "$DR_ROBOT_SHORT_NAME"

ensure_repo \
  "$QUAY_DR_URL" \
  "$QUAY_DR_API_TOKEN" \
  "DR" \
  "$ORG1" \
  "baseline"

set_robot_permission \
  "$ORG1" \
  "baseline" \
  "$DR_ROBOT_SHORT_NAME" \
  "write"

configure_mirror \
  "$ORG1" \
  "baseline" \
  "$DR_ROBOT_SHORT_NAME"

if [[ "$CREATE_CONFLICT" == "true" ]]; then
  ensure_repo \
    "$QUAY_DR_URL" \
    "$QUAY_DR_API_TOKEN" \
    "DR" \
    "$ORG1" \
    "conflict-normal"

  info "[DR] Repository deixado NORMAL propositalmente: $ORG1/conflict-normal"
fi

if [[ "$TRIGGER_BASELINE_MIRROR" == "true" ]]; then
  trigger_sync "$ORG1" "baseline"

  if [[ "$WAIT_BASELINE_SYNC" == "true" ]]; then
    wait_sync "$ORG1" "baseline"
  fi
fi

# =============================================================================
# ORG 02
#
# missing-backend  -> somente PRD
# missing-frontend -> somente PRD
#
# Robot NÃO deve existir.
# A automação deverá criá-lo.
# =============================================================================

section "Organization $ORG2"

prepare_source_repo "$ORG2" "missing-backend"
prepare_source_repo "$ORG2" "missing-frontend"

if robot_exists "$ORG2" "$DR_ROBOT_SHORT_NAME"; then
  warn "[DR] Robot $ORG2+$DR_ROBOT_SHORT_NAME já existe."
  warn "O cenário não validará a criação automática do robot."
  warn "Execute novamente com RESET_LAB=true para recriar o cenário."
else
  info "[DR] Robot propositalmente ausente: $ORG2+$DR_ROBOT_SHORT_NAME"
fi

# =============================================================================
# ORG 03
#
# missing-reports -> somente PRD
#
# Robot já existe para validar reutilização.
# =============================================================================

section "Organization $ORG3"

prepare_source_repo "$ORG3" "missing-reports"

ensure_robot "$ORG3" "$DR_ROBOT_SHORT_NAME"

info "[DR] Nenhum repository criado em $ORG3. Robot existente será reutilizado."

# =============================================================================
# Resumo
# =============================================================================

section "Massa preparada"

if [[ "$CREATE_CONFLICT" == "true" ]]; then
  SOURCE_REPOS=7
  MISSING_REPOS=5
  CONFLICT_REPOS=1
else
  SOURCE_REPOS=6
  MISSING_REPOS=5
  CONFLICT_REPOS=0
fi

echo
echo "Organizations:"
echo "  - $ORG1"
echo "  - $ORG2"
echo "  - $ORG3"
echo
echo "Repositories PRD esperados       : $SOURCE_REPOS"
echo "Mirrors existentes no DR         : 1"
echo "Mirrors ausentes no DR           : $MISSING_REPOS"
echo "Conflitos repo NORMAL no DR      : $CONFLICT_REPOS"
echo
echo "Robots existentes:"
echo "  - $ORG1+$DR_ROBOT_SHORT_NAME"
echo "  - $ORG3+$DR_ROBOT_SHORT_NAME"
echo
echo "Robot propositalmente ausente:"
echo "  - $ORG2+$DR_ROBOT_SHORT_NAME"
echo

section "Namespaces para o Quay Sync Manager"

cat <<EOF
quay_discovery_namespaces:
  - $ORG1
  - $ORG2
  - $ORG3
EOF

section "Teste 1 - CHECK"

cat <<EOF
quay_mode: "check"

quay_discovery_namespaces:
  - $ORG1
  - $ORG2
  - $ORG3

quay_auto_create_missing_mirrors: false
EOF

echo
echo "Esperado:"
echo "  Mirrors identificados como ausentes : $MISSING_REPOS"
echo "  Mirrors criados                      : 0"
echo "  Mirrors ainda ausentes               : $MISSING_REPOS"
echo "  Conflitos no DR                      : $CONFLICT_REPOS"

section "Teste 2 - SYNC + criação automática"

cat <<EOF
quay_mode: "sync"

quay_discovery_namespaces:
  - $ORG1
  - $ORG2
  - $ORG3

quay_auto_create_missing_mirrors: true
quay_auto_mirror_robot_short_name: "$DR_ROBOT_SHORT_NAME"

quay_auto_mirror_source_username: "<credencial PRD>"
quay_auto_mirror_source_password: "<senha/token PRD>"
EOF

echo
echo "Esperado após execução:"
echo "  Mirrors identificados inicialmente : $MISSING_REPOS"
echo "  Mirrors criados automaticamente    : $MISSING_REPOS"
echo "  Mirrors ainda ausentes             : 0"
echo "  Conflitos no DR                    : $CONFLICT_REPOS"
echo
echo "O repository conflict-normal NÃO deve ser convertido automaticamente."

section "Concluído"