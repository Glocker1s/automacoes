#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: generate_quay_lab_drift_only.sh
#
# Objetivo:
#   Gerar divergência no Quay PRD sem tocar no Quay DR.
#
# Importante:
#   - Este script NÃO chama API do DR.
#   - Este script NÃO atualiza mirror config.
#   - Este script NÃO executa sync-now.
#   - Ele apenas faz push de novas imagens/tags no PRD.
#
# Uso:
#   1. Primeiro rode generate_quay_lab_mass.sh normalmente para criar orgs,
#      repos e mirrors.
#   2. Depois rode este script para gerar divergência.
#   3. Rode Quay Sync Manager em quay_mode=check.
###############################################################################

: "${QUAY_PRD_URL:?Informe QUAY_PRD_URL. Ex: https://quay-prd.apps.cluster.com}"
: "${QUAY_PRD_PUSH_USER:?Informe QUAY_PRD_PUSH_USER. Ex: quayadmin ou org+robot}"
: "${QUAY_PRD_PUSH_PASSWORD:?Informe QUAY_PRD_PUSH_PASSWORD}"

TLS_VERIFY="${TLS_VERIFY:-false}"

LAB_ORG_PREFIX="${LAB_ORG_PREFIX:-qsync-lab}"
LAB_ORG_COUNT="${LAB_ORG_COUNT:-6}"

# digest  -> recria tags já existentes, gerando DIGEST_MISMATCH
# missing -> cria tag nova que casa com o filtro do mirror, gerando MISSING_TAG
DRIFT_TYPE="${DRIFT_TYPE:-digest}"

REPO_SPECS_DEFAULT=(
  "backend|*|latest,v1,v2,release-1,dev-1"
  "frontend|*|latest,v1,release-1,feature-1"
  "api|release-*|release-1,release-2,dev-1,dev-2"
  "worker|v*|v1,v2,v3,latest,release-1"
  "batch|stable-*|stable-1,stable-2,canary-1,dev-1"
  "reports|*|latest,v1,v2,v3"
)

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERRO: comando obrigatório não encontrado: $cmd" >&2
    exit 1
  fi
}

normalize_host() {
  local raw="$1"
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%/}"
  echo "$raw"
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

new_tag_for_filter() {
  local filter="$1"
  local suffix="$2"
  local first_filter

  first_filter="${filter%%,*}"
  first_filter="$(echo "$first_filter" | sed 's/^ *//;s/ *$//')"

  case "$first_filter" in
    "*")
      echo "drift-${suffix}"
      ;;
    "release-"*)
      echo "release-${suffix}"
      ;;
    "v"*)
      echo "v${suffix}"
      ;;
    "stable-"*)
      echo "stable-${suffix}"
      ;;
    *)
      echo "drift-${suffix}"
      ;;
  esac
}

build_and_push_image() {
  local org="$1"
  local repo="$2"
  local tag="$3"

  local image_ref="${QUAY_PRD_HOST}/${org}/${repo}:${tag}"
  local build_dir="${WORKDIR}/${org}-${repo}-${tag}"
  mkdir -p "$build_dir"

  cat > "${build_dir}/payload.txt" <<EOF
quay sync manager drift test
org=${org}
repo=${repo}
tag=${tag}
run_id=${RUN_ID}
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
drift_type=${DRIFT_TYPE}
purpose=generate-prd-dr-divergence-without-touching-dr
EOF

  cat > "${build_dir}/Containerfile" <<EOF
FROM scratch
LABEL org.opencontainers.image.title="Quay Sync Manager drift ${org}/${repo}:${tag}"
LABEL quay.lab.org="${org}"
LABEL quay.lab.repo="${repo}"
LABEL quay.lab.tag="${tag}"
LABEL quay.lab.run_id="${RUN_ID}"
LABEL quay.lab.drift_type="${DRIFT_TYPE}"
COPY payload.txt /payload.txt
EOF

  info "[PRD] Build ${image_ref}"
  podman build -q -f "${build_dir}/Containerfile" -t "${image_ref}" "${build_dir}" >/dev/null

  info "[PRD] Push ${image_ref}"
  podman push --tls-verify="${TLS_VERIFY}" "${image_ref}" >/dev/null
}

require_cmd podman

QUAY_PRD_HOST="$(normalize_host "$QUAY_PRD_URL")"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID_SHORT="$(date -u +%H%M%S)"
WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

log "Configuração"
cat <<EOF
PRD HOST        : ${QUAY_PRD_HOST}
LAB_ORG_PREFIX  : ${LAB_ORG_PREFIX}
LAB_ORG_COUNT   : ${LAB_ORG_COUNT}
TLS_VERIFY      : ${TLS_VERIFY}
DRIFT_TYPE      : ${DRIFT_TYPE}
RUN_ID          : ${RUN_ID}
EOF

if [ "$DRIFT_TYPE" != "digest" ] && [ "$DRIFT_TYPE" != "missing" ]; then
  echo "ERRO: DRIFT_TYPE inválido. Use digest ou missing." >&2
  exit 1
fi

log "Login no Quay PRD"
podman login \
  --tls-verify="${TLS_VERIFY}" \
  -u "${QUAY_PRD_PUSH_USER}" \
  -p "${QUAY_PRD_PUSH_PASSWORD}" \
  "${QUAY_PRD_HOST}"

log "Gerando divergência somente no PRD"

for i in $(seq 1 "$LAB_ORG_COUNT"); do
  org="${LAB_ORG_PREFIX}-$(printf '%02d' "$i")"

  log "Organization ${org}"

  for spec in "${REPO_SPECS_DEFAULT[@]}"; do
    IFS='|' read -r repo filter_csv tags_csv <<< "$spec"

    if [ "$DRIFT_TYPE" = "digest" ]; then
      info "Gerando DIGEST_MISMATCH em ${org}/${repo}"
      IFS=',' read -ra tags <<< "$tags_csv"

      for tag in "${tags[@]}"; do
        tag="$(echo "$tag" | sed 's/^ *//;s/ *$//')"
        [ -z "$tag" ] && continue
        build_and_push_image "$org" "$repo" "$tag"
      done
    else
      new_tag="$(new_tag_for_filter "$filter_csv" "$RUN_ID_SHORT")"
      info "Gerando MISSING_TAG em ${org}/${repo} com tag ${new_tag} filtro=${filter_csv}"
      build_and_push_image "$org" "$repo" "$new_tag"
    fi
  done
done

log "Finalizado"

cat <<EOF
Divergência gerada somente no PRD.

Agora rode a automação:

  quay_mode: check

Resultado esperado:

- DRIFT_TYPE=digest:
    Diferença de digest / DIGEST_MISMATCH

- DRIFT_TYPE=missing:
    Tag ausente no DR / MISSING_TAG

Depois rode:

  quay_mode: sync

para validar a correção via sync-cancel + sync-now.
EOF
