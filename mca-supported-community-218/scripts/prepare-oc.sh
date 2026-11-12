#!/usr/bin/env bash
# Extrai o tarball oficial de clientes OpenShift Linux recebido da Red Hat.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCHIVE=${1:-}
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo 'Uso: scripts/prepare-oc.sh /caminho/openshift-client-linux.tar.gz' >&2
  exit 2
fi
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
# Trava extracao em diretorio temporario; usa somente os dois membros previstos.
tar -xzf "$ARCHIVE" -C "$TEMP" oc kubectl
[[ -f "$TEMP/oc" && -f "$TEMP/kubectl" ]] || { echo 'Tarball sem oc/kubectl' >&2; exit 1; }
chmod 0755 "$TEMP/oc" "$TEMP/kubectl"
if ! "$TEMP/oc" version --client 2>&1 | grep -q '4\.20\.'; then
  echo 'ERRO: binario oc nao e da linha 4.20 ou arquitetura nao compativel' >&2
  exit 1
fi
install -m 0755 "$TEMP/oc" "$ROOT/files/oc"
install -m 0755 "$TEMP/kubectl" "$ROOT/files/kubectl"
echo "Binarios oc/kubectl 4.20 copiados para $ROOT/files"
