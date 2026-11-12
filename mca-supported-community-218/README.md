# mca-supported-community 2.18 — primeira versão de homologação

**Objetivo:** consolidar os EEs `mca-supported-community`, DNS/LDAP, OpenSSL e DBA Minimal em um EE RHEL 9, Python 3.12, Core 2.18. Mantem `community.postgresql`, `smbclient`, LDAP, VMware, Windows, OpenShift 4.20.

**Estado:** arquivos preparados e YAML validado localmente; imagem NAO foi construida. Testes de registry, AppStream, Galaxy/Automation Hub, dependencias e jobs reais dependem da infraestrutura do cliente.

## 1. Pre-requisitos do HOST (nao do EE)

- Python 3.11+ e `ansible-builder` 3.2.0 (ou Builder 3.1.x, schema v3).
- Podman instalado e operacional (modo rootless ou rootful conforme host).
- Login `podman login registry.redhat.io` e permissao de pull da imagem-base.
- Repositorios RHEL 9 AppStream acessiveis no build para `samba-client`, `openldap-devel`, `libpq-devel` e demais RPMs. O repo UBI sozinho pode nao bastar.
- Acesso ao Automation Hub/Private Automation Hub necessario para collections como `redhat.openshift`. Preparar credenciais fora do repositório; NAO salvar tokens nos YAMLs ou na imagem final.
- Acesso ao PyPI ou mirror interno para bibliotecas Python.
- Binario Linux da CLI OpenShift 4.20 da origem oficial e verificacao de integridade do tarball.

## 2. A estrutura

- `execution-environment.yml`: definicao principal do Builder. Usa `ee-minimal-rhel9:2.18` e adiciona os binarios oc/kubectl.
- `execution-environment-no-oc.yml`: variante para testar resolucao das collections e RPMs antes de ter o tarball oc. Nao utilizar como versao final para OpenShift.
- `requirements.yml`: collections Ansible e suas versoes fixadas.
- `requirements.txt`: bibliotecas do Python 3.12; `python-ldap` e `psycopg2` serao compilados com RPMs `compile`.
- `bindep.txt`: pacotes RHEL 9; `compile` indica ferramentas presentes durante o build, nao obrigatoriamente no container final.
- `scripts/preflight.sh`: testa imagem-base, AppStream, SMB e bibliotecas de compilacao em container temporario.
- `scripts/prepare-oc.sh`: extrai binarios oficiais para `files/`.
- `scripts/smoke-test.sh`: verifica o EE compilado, imports e modules sem conectar aos ambientes alvo.

## 3. Passos (host Linux com Podman)

```bash
# Instalar Builder isolado (caso necessario)
python3.12 -m venv ~/venvs/ansible-builder
source ~/venvs/ansible-builder/bin/activate
python -m pip install 'ansible-builder==3.2.0'

podman login registry.redhat.io
./scripts/preflight.sh

# Se quiser validar as dependencias antes do binario oc:
ansible-builder build -f execution-environment-no-oc.yml --container-runtime podman \
  -t mca-supported-community:2.18-no-oc

# Obter o tarball OFICIAL do cliente OpenShift 4.20 para a arquitetura do EE.
# Exemplo de local de obtencao x86_64 (revisar checksum da fonte oficial):
# https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.20/openshift-client-linux.tar.gz
./scripts/prepare-oc.sh /caminho/openshift-client-linux.tar.gz

ansible-builder create -f execution-environment.yml
ansible-builder build -f execution-environment.yml --container-runtime podman \
  -t mca-supported-community:2.18-rc1
./scripts/smoke-test.sh mca-supported-community:2.18-rc1
```

Se o nome do executavel `python3.12` nao existir no host, use um Python >=3.11 para instalar Builder 3.2; nao e necessario executar o Builder com o mesmo Python 3.12 do EE.

## 4. Pacotes e collections

**Riscos importantes:**

- `samba-client` requer repositorios RHEL 9 acessiveis. Se surgir `No package matches`, ajustar AppStream/subscription antes de tentar bypass ou copiar RPM de outro sistema.
- `python-ldap` depende de headers/compilador, possivelmente acessiveis somente pelo AppStream. Confirmar `import ldap` no Python 3.12.
- `psycopg2` e instalado a partir do fonte, ligado a `libpq` do RHEL 9; nao foi usado `psycopg2-binary`.
- `community.vmware 5.10.0` preserva `vmware_guest_snapshot` e `vmware_vm_info`; o modulo de snapshot tem deprecacao anunciada para versoes posteriores, mas seu uso deve ser homologado.
- `redhat.openshift 2.3.0` deve ser resolvida no servidor de collections configurado (Automation Hub); conferir o modulo `redhat.openshift.k8s_info` com `ansible-doc` apos build.
- `community.postgresql 3.8.0` mantida. Se os modulos forem executados nos servidores PostgreSQL, estes precisam do driver no INTERPRETADOR REMOTO. O driver no EE nao substitui o driver remoto.
- WinRM/PSRP definidos com CredSSP. Se os jobs usarem Kerberos, adicionar extras e RPMs de compilacao Kerberos em uma revisao controlada, apos teste.
- **Core 2.18 nao garante suporte a hosts RHEL 8 legados na matriz de suporte empresarial da Red Hat.** Mapear RHEL/Python remotos antes de substituir o EE antigo. Core 2.16 pode continuar necessario para alguns jobs.
- `oc` 4.20 corresponde ao OpenShift do cliente, mas nao e carregado automaticamente do registry. Arquivo oficial deve ser preparado em `files/`.

## 5. Galaxy / Automation Hub

`requirements.yml` inclui `redhat.openshift`, que pode nao existir no Galaxy publico e exigir Automation Hub corporativo. O build deve ser executado em ambiente com credenciais e endereco do Hub configurados para a etapa **Galaxy**.

Nao colocar tokens, senhas ou um `ansible.cfg` com credenciais dentro do ZIP nem adicionar ENV permanente de token ao Containerfile. Usar mecanimos seguros da CI para secrets de build ou a estrategia oficial de variaveis de ambiente do Ansible Builder, com avaliacao de exposicao em logs/historico.

## 6. Apos homologar

1. Guardar `podman image inspect` e o digest do EE validado.
2. Registrar as versoes efetivas (`ansible-galaxy collection list`, `python3.12 -m pip freeze`, `rpm -qa`).
3. Reexecutar pelo menos uma automacao LDAP, uma de snapshot VMware, uma WinRM/PSRP, uma OpenShift com `k8s_info`, uma com SMB e uma PostgreSQL.
4. Publicar uma tag versionada no Quay e criar novo cadastro de EE no AAP, sem substituir o antigo durante os testes.
5. Validar todos os Job Templates que serao migrados, preservando rollback.

## 7. Criterio de consolidacao

Este primeiro conjunto nao replica as 54 collections historicas. As demais devem ser adicionadas apenas se algum Job Template ativo as requerer. O `community.windows`, `ansible.posix`, `ansible.utils` e `community.dns` foram preservados preventivamente por constarem do EE principal; isso nao comprova uso de cada um.

Documentacao: https://docs.ansible.com/projects/builder/en/latest/definition/ | https://access.redhat.com/support/policy/updates/ansible-automation-platform


## Nota de correção - fontes de collections (Automation Hub + Galaxy)

O build da versão inicial pode falhar em `redhat.openshift:2.3.0 (direct request)` porque o Ansible Galaxy público não disponibiliza necessariamente collections certificadas da Red Hat.

As duas definições do EE agora configuram as fontes `automation_hub,galaxy` na fase `galaxy`. Não inserir token nos arquivos do projeto. Para o build de laboratório, obtenha um token válido no portal Red Hat Automation Hub com acesso ao conteúdo certificado e exporte-o na sessão, sem ecoá-lo:

```bash
read -r -s -p 'Automation Hub token: ' ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN; echo
export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN

ansible-builder build -f execution-environment-no-oc.yml \
  --container-runtime podman \
  --build-arg ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN \
  -t mca-supported-community:2.18-no-oc

unset ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN
```

O acesso ao `registry.redhat.io` e a subscrição do RHEL não substituem o token do Automation Hub. A presença da collection 2.3.0 no Hub autenticado ainda precisa ser confirmada; se não existir, não usar `--pre` como correção nem atualizar cegamente sem testes. O argumento de build é a abordagem prevista na documentação do Ansible Builder, mas trate as camadas/cache do processo como sensíveis enquanto houver builds com token.
