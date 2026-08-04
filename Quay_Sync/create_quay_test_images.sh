#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script: create_quay_test_images.sh
#
# Objetivo:
#   Criar imagens de teste e fazer push no Quay PRD.
#
# Importante:
#   - As imagens devem ser criadas primeiro somente no PRD.
#   - O DR deve receber via repository mirror.
#   - Use este script novamente depois do mirror para gerar novas tags/digests
#     e simular divergência entre PRD e DR.
#
# Requisitos:
#   - podman instalado
#   - usuário/senha ou robot token com permissão de push no Quay PRD
###############################################################################

: "${QUAY_PRD_URL:?Informe QUAY_PRD_URL. Ex: https://quay-prd.apps.cluster.com}"
: "${QUAY_PRD_USER:?Informe QUAY_PRD_USER. Ex: quayadmin ou apps+robot}"
: "${QUAY_PRD_PASSWORD:?Informe QUAY_PRD_PASSWORD. Senha do usuário ou token do robot}"

QUAY_ORG="${QUAY_ORG:-apps}"
TLS_VERIFY="${TLS_VERIFY:-false}"

# Se quiser alterar a lista, edite aqui.
TEST_IMAGES=(
  "backend:v1"
  "backend:v2"
  "backend:latest"
  "frontend:v1"
  "frontend:latest"
  "api:release-1"
  "api:dev-1"
)

normalize_registry_host() {
  local raw="$1"
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%/}"
  echo "$raw"
}

QUAY_PRD_HOST="$(normalize_registry_host "$QUAY_PRD_URL")"

WORKDIR="$(mktemp -d)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "======================================================================"
echo "Criando imagens de teste no Quay PRD"
echo "Registry : ${QUAY_PRD_HOST}"
echo "Org      : ${QUAY_ORG}"
echo "Run ID   : ${RUN_ID}"
echo "TLS      : ${TLS_VERIFY}"
echo "======================================================================"

echo
echo "[1/4] Login no Quay PRD..."
podman login \
  --tls-verify="${TLS_VERIFY}" \
  -u "${QUAY_PRD_USER}" \
  -p "${QUAY_PRD_PASSWORD}" \
  "${QUAY_PRD_HOST}"

echo
echo "[2/4] Criando e publicando imagens..."
for image_def in "${TEST_IMAGES[@]}"; do
  repo="${image_def%%:*}"
  tag="${image_def##*:}"

  image_ref="${QUAY_PRD_HOST}/${QUAY_ORG}/${repo}:${tag}"
  build_dir="${WORKDIR}/${repo}-${tag}"
  mkdir -p "${build_dir}"

  cat > "${build_dir}/payload.txt" <<EOF
quay test image
repo=${repo}
tag=${tag}
run_id=${RUN_ID}
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
purpose=quay-prd-to-dr-mirror-lab
EOF

  cat > "${build_dir}/Containerfile" <<EOF
FROM scratch
LABEL org.opencontainers.image.title="quay mirror lab ${repo}:${tag}"
LABEL org.opencontainers.image.description="Imagem de teste para validação de mirror Quay PRD -> DR"
LABEL quay.lab.repo="${repo}"
LABEL quay.lab.tag="${tag}"
LABEL quay.lab.run_id="${RUN_ID}"
COPY payload.txt /payload.txt
EOF

  echo
  echo "Build: ${image_ref}"
  podman build -q -f "${build_dir}/Containerfile" -t "${image_ref}" "${build_dir}"

  echo "Push : ${image_ref}"
  podman push --tls-verify="${TLS_VERIFY}" "${image_ref}"
done

echo
echo "[3/4] Listando imagens criadas localmente..."
for image_def in "${TEST_IMAGES[@]}"; do
  repo="${image_def%%:*}"
  tag="${image_def##*:}"
  image_ref="${QUAY_PRD_HOST}/${QUAY_ORG}/${repo}:${tag}"
  podman image inspect "${image_ref}" \
    --format "local={{ .Id }} image=${image_ref}" || true
done

echo
echo "[4/4] Finalizado."
echo
echo "Imagens publicadas no PRD:"
for image_def in "${TEST_IMAGES[@]}"; do
  repo="${image_def%%:*}"
  tag="${image_def##*:}"
  echo "  ${QUAY_PRD_HOST}/${QUAY_ORG}/${repo}:${tag}"
done

echo
echo "Próximo passo:"
echo "  1. Criar/configurar repository mirror no Quay DR apontando para esses repos do PRD."
echo "  2. Executar Sync Now no DR."
echo "  3. Rodar o playbook de validação da API."
echo
