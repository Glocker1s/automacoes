#!/usr/bin/env bash
set -euo pipefail
BASE='registry.redhat.io/ansible-automation-platform/ee-minimal-rhel9:2.18'
echo '== Versoes do host de build =='
ansible-builder --version
podman --version
python3 --version

echo '== Pull da imagem-base =='
podman pull "$BASE"
echo '== Informacoes e teste de RPM (somente container descartavel) =='
podman run --rm --user 0 --entrypoint /bin/sh "$BASE" -ec '
  cat /etc/os-release
  /usr/bin/python3.12 --version
  ansible --version
  microdnf repolist
  microdnf install -y samba-client gcc python3.12-devel openldap-devel cyrus-sasl-devel libpq-devel pkgconf-pkg-config
  smbclient --version
  command -v pg_config
'
echo 'RPMs e imagem-base validados; seguir para o build.'
