#!/usr/bin/env bash
set -euo pipefail
IMAGE=${1:-mca-supported-community:2.18-rc1}
podman run --rm --entrypoint /bin/bash "$IMAGE" -ec '
  echo "=== OS ==="; cat /etc/os-release
  echo "=== Core e Python ==="; ansible --version; /usr/bin/python3.12 --version
  echo "=== Pip check ==="; /usr/bin/python3.12 -m pip check
  echo "=== Imports Python ==="
  /usr/bin/python3.12 -c "import ldap, psycopg2, kubernetes, winrm, psrp; from pyVim import connect; print(\"Imports OK\")"
  echo "=== Binarios ==="
  command -v smbclient; smbclient --version
  command -v openssl; openssl version
  command -v oc; oc version --client
  command -v kubectl; kubectl version --client
  command -v jq
  echo "=== Collections ==="; ansible-galaxy collection list
  echo "=== Resolução de módulos ==="
  for mod in community.vmware.vmware_guest_snapshot community.vmware.vmware_vm_info community.general.ldap_search community.general.ldap_attrs community.postgresql.postgresql_db kubernetes.core.k8s_info redhat.openshift.k8s_info ansible.windows.win_powershell; do
    ansible-doc -t module "$mod" >/dev/null || { echo "Falha ao carregar modulo: $mod" >&2; exit 1; }
    echo "$mod: OK"
  done
'
