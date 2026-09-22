# F5 Certs Manager

Playbook para **inventário, rotação, validação, comparação e limpeza de certificados no F5 BIG-IP**, com suporte a execução em **modo list/check/compare/apply**, descoberta automática de **certificado atual**, **Client SSL Profiles**, **Server SSL Profiles**, **Virtual Servers / VIPs** relacionados, validação **TLS + HTTP** para Client SSL, validação **config_only** para Server SSL, **Config Sync HA** e relatório HTML consolidado.

A automação:

- localiza a pasta correta no CIFS;
- processa o certificado novo, key e cadeia;
- suporta `CADEIA.TXT` pronto ou montagem automática da cadeia a partir de `CADEIA*.zip`;
- identifica o certificado atualmente em uso no F5;
- descobre os profiles que usam esse certificado, podendo considerar Client SSL, Server SSL ou ambos;
- descobre automaticamente os VIPs / targets de validação para Client SSL;
- importa os objetos no F5 com sufixo de mês/ano para rastreabilidade;
- aplica a troca nos profiles impactados;
- executa validação TLS + HTTP para Client SSL;
- executa validação config_only para Server SSL;
- executa compare entre sites, como PRD x DR;
- executa cleanup de duplicados e de certificados expirados sem uso, quando habilitado;
- protege certificados em uso por Client SSL, Server SSL ou chain contra cleanup indevido;
- executa Config Sync HA após alterações, quando habilitado;
- gera relatório HTML consolidado e e-mail de falha tratado.

---

## 1. Variáveis

| Variável | Tipo | Descrição |
| --- | --- | --- |
| `f5_certs_mode` | string | Modo da automação: `list`, `check`, `compare` ou `apply`. |
| `f5_target_scope` | string | Escopo dos sites F5 a considerar. Deve bater com os nomes definidos em `f5_sites`. Ex.: `hml`, `prd,dr`, `prd-interno,dr-interno`. |
| `f5_ssl_profile_scope` | string | Define o tipo de profile considerado nas ações. Valores: `client`, `server` ou `all`. |
| `certificate_prefix` | string | Prefixo do(s) certificado(s) no CIFS. Pode receber **um ou mais valores separados por vírgula**. Ex.: `agorascan.lab,portal-cert.lab,api-cert.lab`. |
| `single_validate_path` | string | Path HTTP usado na validação pós-troca de Client SSL. Ex.: `/` ou `/health`. |

### Variáveis operacionais importantes (defaults)

| Variável | Tipo | Descrição |
| --- | --- | --- |
| `f5_warning_days` | int | Janela de alerta para certificados próximos do vencimento. |
| `f5_critical_days` | int | Janela crítica de vencimento. |
| `f5_collect_server_ssl_for_safety` | bool | Se `true`, coleta Server SSL Profiles para evitar cleanup inseguro de certificados usados por Server SSL. |
| `f5_apply_allow_all_profile_types` | bool | Se `true`, permite `apply` com `f5_ssl_profile_scope=all`. Por padrão, deve ficar `false` por segurança. |
| `f5_server_ssl_validation_mode` | string | Validação pós-apply para Server SSL. Atualmente usado como `config_only`. |
| `f5_compare_baseline_site` | string | Site base usado no modo `compare`. Ex.: `prd` ou `prd-interno`. |
| `f5_compare_only_in_use` | bool | Se `true`, o compare considera apenas certificados em uso por profiles. |
| `f5_compare_expiration_tolerance_days` | int | Tolerância em dias para diferença de vencimento no compare. |
| `f5_compare_fail_on_drift` | bool | Se `true`, falha a job quando o compare encontra divergências. |
| `f5_duplicate_delete_grace_days` | int | Quantos dias após a expiração um duplicado pode virar candidato à remoção. |
| `f5_enable_duplicate_cleanup` | bool | Se `true`, permite limpeza automática de duplicados no modo `check`. |
| `f5_duplicate_cleanup_only_if_not_in_use` | bool | Se `true`, não remove duplicado ainda referenciado por profile/chain. Se `false`, pode reapontar Client SSL Profile para outro certificado válido antes de remover o antigo. O reapontamento agressivo automático para Server SSL foi mantido como evolução futura. |
| `f5_cleanup_delete_key` | bool | Se `true`, remove também a key associada ao certificado duplicado deletado. |
| `f5_enable_expired_unused_cleanup` | bool | Se `true`, permite cleanup de certificados expirados sem uso no modo `check`. |
| `f5_expired_unused_delete_grace_days` | int | Quantos dias após a expiração um certificado sem uso pode ser removido. |
| `f5_expired_unused_only_non_duplicated` | bool | Se `true`, evita que o cleanup de expirados sem uso remova certificados que pertencem a grupos duplicados. |
| `f5_expired_unused_delete_key` | bool | Se `true`, remove também a key associada ao certificado expirado sem uso. |
| `f5_min_valid_days_after_install` | int | Mínimo de dias de validade exigido para o certificado novo antes do `apply`. |
| `f5_enable_chain_import` | bool | Se `true`, importa a chain no F5 quando existir cadeia no CIFS. |
| `f5_enable_chain_on_profile` | bool | Se `true`, associa a chain importada ao profile durante o apply. Em Client SSL, no `certKeyChain`; em Server SSL, no campo `chain`. |
| `f5_source_chain_from_zip_enabled` | bool | Se `true`, permite montar `CADEIA.TXT` a partir de `CADEIA*.zip`. |
| `f5_source_chain_required` | bool | Se `true`, exige cadeia. Se `false`, segue sem chain quando não existir `CADEIA.TXT` nem `CADEIA*.zip`. |
| `f5_import_name_suffix_enabled` | bool | Se `true`, adiciona sufixo de mês/ano nos objetos importados no F5. |
| `f5_import_name_suffix_format` | string | Formato do sufixo. Padrão recomendado: `%m-%Y`, gerando nomes como `05-2026`. |
| `f5_import_name_collision_strategy` | string | Estratégia quando o nome importado já existe no F5. `increment` tenta `-2`, `-3`, etc. `fail` interrompe. |
| `f5_enable_configsync` | bool | Se `true`, executa Config Sync HA após alterações no F5. |
| `f5_configsync_device_group_by_site` | dict | Mapeia o device group de Config Sync por site. |
| `f5_enable_post_handshake_validation` | bool | Se `true`, executa validação TLS após a troca de Client SSL. |
| `f5_enable_post_http_validation` | bool | Se `true`, executa validação HTTP após a troca de Client SSL. |
| `f5_validate_path_default` | string | Path default usado na validação quando não informado. |
| `f5_validate_ok_codes_default` | list[int] | Lista default de códigos HTTP considerados válidos. Normalmente `[200]`. |
| `f5_report_timezone` | string | Timezone usado no cabeçalho do relatório. Ex.: `America/Sao_Paulo`. |
| `f5_timewarp_days` | int | Ajuste de data usado em laboratório/simulação. Em produção, manter `0`. |

---

## 2. Estrutura esperada

- **Entrada simplificada no Survey**: no fluxo atual, o operador informa `f5_certs_mode`, `f5_target_scope`, `f5_ssl_profile_scope`, `certificate_prefix` e `single_validate_path`.
- **Sites dinâmicos**: `f5_target_scope` não é fixo em `prd/dr`; os valores aceitos são os nomes configurados em `f5_sites`.
- **Escopo de SSL Profiles**: `f5_ssl_profile_scope` define se as ações consideram `client`, `server` ou `all`.
- **Client SSL**: usado no fluxo usuário/navegador -> F5. O F5 apresenta o certificado para o cliente.
- **Server SSL**: usado no fluxo F5 -> backend. Quando possui `cert`, `key` e `chain`, o F5 pode apresentar certificado ao backend, normalmente em cenários de mTLS.
- **Suporte a múltiplos certificados**: `certificate_prefix` aceita múltiplos valores separados por vírgula; a automação monta um `f5_rotation_plan` interno automaticamente.
- **Fonte dos certificados novos**: o CIFS deve conter uma pasta por certificado, contendo o leaf cert (`.cer/.crt/.pem`), a key (`.key`) e opcionalmente cadeia (`CADEIA.TXT` ou `CADEIA*.zip`).
- **Extensões maiúsculas/minúsculas**: a automação aceita extensões como `.cer`, `.CER`, `.crt`, `.CRT`, `.pem`, `.PEM`, `.key` e `.KEY`.
- **Cadeia de certificados**: se existir `CADEIA.TXT`, usa direto. Se não existir e houver `CADEIA*.zip`, extrai e concatena arquivos `.crt/.cer/.pem/.txt` para gerar uma cadeia temporária.
- **Nome no F5 com sufixo**: no `apply`, os objetos importados podem receber sufixo de mês/ano. Ex.: `troca-modelo-webapp-05-2026.crt`.
- **Descoberta automática**: a automação não depende mais de `profile_name`, `target`, `sni` ou `rotation_plan_yaml` fornecidos pelo usuário.
- **Match do certificado atual**: o certificado atual em uso no F5 é descoberto a partir das **SANs** do certificado novo processado no CIFS.
- **Expansão do grupo**: uma vez identificado o certificado atual, a automação troca todos os profiles do escopo selecionado que usam esse mesmo certificado no site.
- **Descoberta de VIP / target**: para Client SSL, a automação usa o índice de Virtual Servers para descobrir automaticamente `target` (`IP:PORT`) para validação.
- **Validação sem dependência de DNS externo**: a validação TLS/HTTP de Client SSL usa o `target` descoberto e a SNI das SANs do certificado novo; quando há `curl`, a automação usa `--resolve`, evitando depender de DNS real do ambiente.
- **Validação Server SSL**: para Server SSL, a validação padrão é `config_only`, relendo o profile pela API e confirmando se `cert`, `key` e `chain` foram aplicados.
- **Cleanup de duplicados**: no modo `check`, duplicados expirados podem ser limpos automaticamente.
- **Cleanup de expirados sem uso**: no modo `check`, certificados expirados sem uso podem ser removidos automaticamente, se habilitado.
- **Proteção de Server SSL no cleanup**: certificados em uso por Server SSL ou como chain de Server SSL não devem ser removidos como “sem uso”.
- **Compare entre sites**: no modo `compare`, a automação compara certificados entre sites conforme o escopo `client`, `server` ou `all`.
- **Config Sync HA**: após `apply` ou cleanup com alteração, a automação pode executar sync device-to-group.
- **Relatório consolidado**: o HTML final inclui resumo do `apply`, inventário por site, compare, duplicidade, cleanups, Config Sync e resultado das validações.

---

## 3. YAML de exemplo

### 3.1 Defaults / parâmetros principais

```yaml
f5_certs_mode: "check"
f5_target_scope: "prd"
f5_ssl_profile_scope: "client"
certificate_prefix: ""

f5_sites:
  - name: "prd"
    server: "192.168.141.10"
    port: 443
  - name: "dr"
    server: "192.168.150.10"
    port: 443

f5_warning_days: 30
f5_critical_days: 7

f5_collect_server_ssl_for_safety: true
f5_apply_allow_all_profile_types: false
f5_server_ssl_validation_mode: "config_only"

f5_compare_baseline_site: ""
f5_compare_only_in_use: true
f5_compare_expiration_tolerance_days: 0
f5_compare_fail_on_drift: false

f5_duplicate_delete_grace_days: 10
f5_enable_duplicate_cleanup: false
f5_duplicate_cleanup_only_if_not_in_use: true
f5_cleanup_delete_key: false

f5_enable_expired_unused_cleanup: false
f5_expired_unused_delete_grace_days: 30
f5_expired_unused_only_non_duplicated: true
f5_expired_unused_delete_key: true

mount_cifs: ""
mount_path: "/opt/ansiblefiles/files/f5-certs"

f5_min_valid_days_after_install: 25

f5_enable_chain_import: false
f5_enable_chain_on_profile: false
f5_source_chain_from_zip_enabled: true
f5_source_chain_required: false

f5_import_name_suffix_enabled: true
f5_import_name_suffix_format: "%m-%Y"
f5_import_name_collision_strategy: "increment"

f5_enable_post_handshake_validation: true
f5_enable_post_http_validation: true
f5_validate_path_default: "/"
f5_validate_ok_codes_default: [200]

f5_enable_configsync: false
f5_configsync_device_group_by_site: {}

f5_report_timezone: "America/Sao_Paulo"
f5_timewarp_days: 0
```

### 3.2 Survey simplificado

```yaml
f5_certs_mode: apply
f5_target_scope: prd,dr
f5_ssl_profile_scope: client
certificate_prefix: agorascan.lab,portal-cert.lab,api-cert.lab
single_validate_path: /
```

### 3.3 Apply de Server SSL

```yaml
f5_certs_mode: apply
f5_target_scope: prd
f5_ssl_profile_scope: server
certificate_prefix: lab-serverssl-apply
single_validate_path: /
f5_server_ssl_validation_mode: config_only
```

### 3.4 Compare PRD x DR

```yaml
f5_certs_mode: compare
f5_target_scope: prd,dr
f5_compare_baseline_site: prd
f5_ssl_profile_scope: all
```

### 3.5 Exemplo com sites internos/externos

```yaml
f5_target_scope: prd-interno,dr-interno

f5_sites:
  - name: "prd-interno"
    server: "10.10.10.10"
    port: 443
  - name: "dr-interno"
    server: "10.10.20.10"
    port: 443
  - name: "prd-externo"
    server: "10.10.30.10"
    port: 443
  - name: "dr-externo"
    server: "10.10.40.10"
    port: 443
```

### 3.6 Config Sync HA

```yaml
f5_enable_configsync: true
f5_configsync_fail_on_error: false

f5_configsync_device_group_by_site:
  prd: "grp_sync"
  dr: "grp_sync"
```

### 3.7 Exemplo de item interno montado automaticamente

```yaml
f5_rotation_plan:
  - certificate_prefix: agorascan.lab
    validate_path: /
    validate_ok_codes: [200]

  - certificate_prefix: portal-cert.lab
    validate_path: /
    validate_ok_codes: [200]
```

> Esse plano é montado automaticamente pelo playbook a partir do `certificate_prefix`, sem necessidade de `rotation_plan_yaml` manual.

---

## 4. Estrutura de arquivos da automação

| Arquivo | Descrição |
| --- | --- |
| `f5_certs_playbook.yml` | Playbook principal. Normaliza entradas do survey, monta plano de rotação no `apply`, executa a role e trata falhas com e-mail detalhado. |
| `f5_certs_manager/defaults/main.yml` | Parâmetros padrão da role: credenciais, sites, CIFS, thresholds, cleanup, cadeia, Config Sync, Server SSL, compare e relatório. |
| `f5_certs_manager/tasks/main.yml` | Orquestra o fluxo principal da role. |
| `00_f5_collect_certs.yml` | Coleta certificados instalados e enriquece com `full_path`, `expiration_epoch`, `days_left` e SAN. |
| `10_f5_collect_profiles.yml` | Coleta Client SSL Profiles e Server SSL Profiles. |
| `11_map_profile_usage.yml` | Monta índices reversos de uso de certificado/chain por profile, diferenciando Client SSL, Server SSL e uso como cadeia. |
| `12_build_virtual_profile_index.yml` | Coleta Virtual Servers e monta índice `profile -> virtual/pool/target`. |
| `13_build_virtual_cache_for_site.yml` | Cache de virtuals por site. |
| `14_build_clientssl_cache_for_site.yml` | Cache de Client SSL Profiles por site. |
| `14_build_serverssl_cache_for_site.yml` | Cache de Server SSL Profiles por site. |
| `15_build_cert_cache_for_site.yml` | Cache de certificados instalados por site, usado no `apply` para detectar colisão de nomes. |
| `20_process_findings.yml` | Classifica inventário em `expired`, `critical`, `warning`, `ok` e detecta duplicidade. |
| `30_source_collect_from_cifs.yml` | Monta CIFS, busca pastas de certificados e prepara o inventário de fonte. |
| `31_source_process_cert_dir.yml` | Processa cada pasta do CIFS, valida cert/key, extrai SANs, validade e processa cadeia. |
| `40_apply_rotation.yml` | Prepara caches, gera sufixo de importação e executa a rotação por item. |
| `41_apply_one_rotation.yml` | Resolve a pasta do CIFS e o certificado novo a aplicar. |
| `41_apply_one_rotation__per_site.yml` | Descobre o certificado atual no site, os profiles impactados conforme `f5_ssl_profile_scope` e os targets de validação. |
| `41_apply_one_rotation__per_site_profile.yml` | Importa cert/key/chain e atualiza o profile no F5. Para Client SSL, atualiza `certKeyChain`; para Server SSL, atualiza `cert`, `key` e `chain`. |
| `42_validate_handshake.yml` | Valida TLS + HTTP ao final do grupo para Client SSL. |
| `50_cleanup_duplicates.yml` | Prepara a limpeza de duplicados candidatos. |
| `51_cleanup_one_duplicate.yml` | Remove/reaponta um duplicado específico conforme política. |
| `52_cleanup_expired_unused.yml` | Seleciona certificados expirados sem uso elegíveis para remoção. |
| `53_cleanup_one_expired_unused.yml` | Remove certificado expirado sem uso e, se configurado, sua key. |
| `55_compare_sites.yml` | Executa auditoria entre sites no modo `compare`. |
| `60_build_report.yml` | Monta o relatório HTML final compatível com Outlook. |
| `70_configsync_site.yml` | Executa Config Sync HA por site. |
| `90_collect_one_site.yml` | Coleta inventário por site, executa cleanups, aciona Config Sync e persiste estado final para o report. |

---

## 5. Execução (CLI)

```bash
# Inventário / Check
ansible-playbook -i localhost, f5_certs_playbook.yml \
  -e "f5_certs_mode=check" \
  -e "f5_target_scope=prd,dr" \
  -e "f5_ssl_profile_scope=all" \
  -e "certificate_prefix=agorascan.lab" \
  -e "single_validate_path=/"

# Apply Client SSL
ansible-playbook -i localhost, f5_certs_playbook.yml \
  -e "f5_certs_mode=apply" \
  -e "f5_target_scope=prd" \
  -e "f5_ssl_profile_scope=client" \
  -e "certificate_prefix=portal-cert.lab" \
  -e "single_validate_path=/health"

# Apply Server SSL
ansible-playbook -i localhost, f5_certs_playbook.yml \
  -e "f5_certs_mode=apply" \
  -e "f5_target_scope=prd" \
  -e "f5_ssl_profile_scope=server" \
  -e "certificate_prefix=lab-serverssl-apply" \
  -e "single_validate_path=/"

# Compare PRD x DR
ansible-playbook -i localhost, f5_certs_playbook.yml \
  -e "f5_certs_mode=compare" \
  -e "f5_target_scope=prd,dr" \
  -e "f5_compare_baseline_site=prd" \
  -e "f5_ssl_profile_scope=all"

# Apply de múltiplos certificados
ansible-playbook -i localhost, f5_certs_playbook.yml \
  -e "f5_certs_mode=apply" \
  -e "f5_target_scope=prd,dr" \
  -e "f5_ssl_profile_scope=client" \
  -e "certificate_prefix=agorascan.lab,portal-cert.lab,api-cert.lab" \
  -e "single_validate_path=/"
```

---

## 6. Funcionamento do `apply`

### 6.1 Resolução do certificado novo

Para cada prefixo informado em `certificate_prefix`:

1. a automação procura uma pasta no CIFS que comece com esse prefixo;
2. falha se não encontrar nenhuma pasta;
3. falha se encontrar mais de uma pasta e o prefixo estiver ambíguo;
4. processa o certificado encontrado no `source_cert_inventory`.

### 6.2 Pré-check do certificado novo

Antes de aplicar a troca, a automação valida:

- o certificado tem pelo menos `f5_min_valid_days_after_install` dias de validade;
- a key existe na pasta;
- o cert e a key conferem;
- o certificado possui SANs válidas para descoberta/validação.

### 6.3 Cadeia de certificados

A automação suporta:

- `CADEIA.TXT` pronto na pasta;
- `CADEIA*.zip`, que é extraído e concatenado em um `CADEIA.TXT` temporário;
- ausência de chain, desde que `f5_source_chain_required=false`.

A key nunca entra na cadeia. A cadeia deve conter apenas certificados intermediários/CA.

### 6.4 Nome dos objetos importados no F5

No `apply`, a automação pode adicionar sufixo de mês/ano nos objetos importados no F5.

Exemplo:

```text
Pasta CIFS:
troca-modelo-webapp

Objetos no F5:
troca-modelo-webapp-05-2026.crt
troca-modelo-webapp-05-2026.key
troca-modelo-webapp-05-2026-chain.crt
```

Se o nome já existir e `f5_import_name_collision_strategy=increment`, a automação tenta `-2`, `-3`, etc.

### 6.5 Descoberta do certificado atual no F5

No site, a automação:

1. monta a lista de certificados atualmente em uso conforme `f5_ssl_profile_scope`;
2. compara o certificado novo com os certificados instalados no F5 usando as SANs;
3. tenta descobrir o certificado atual nesta ordem:
   - match exato do conjunto de SANs;
   - match por `primary_san`;
   - match por interseção de SANs.

Se mais de um candidato aparecer na mesma etapa, a automação falha por ambiguidade.

### 6.6 Expansão dos profiles impactados

Uma vez identificado o certificado atual compartilhado, a automação procura todos os profiles do escopo selecionado que usam esse certificado e inclui todos no grupo de troca daquele site.

Exemplos:

```yaml
f5_ssl_profile_scope: client
```

Atualiza apenas Client SSL Profiles.

```yaml
f5_ssl_profile_scope: server
```

Atualiza apenas Server SSL Profiles.

```yaml
f5_ssl_profile_scope: all
```

Considera Client SSL e Server SSL. No modo `apply`, esse comportamento fica bloqueado por padrão, salvo se `f5_apply_allow_all_profile_types=true`.

### 6.7 Execução da troca em Client SSL

Para cada Client SSL Profile alvo:

- lê o estado atual do `certKeyChain`;
- falha se o profile tiver mais de uma entrada em `certKeyChain` (proteção contra cenário SNI múltiplo);
- importa o certificado novo no F5;
- importa a key nova;
- importa a chain, se habilitado;
- atualiza o Client SSL Profile;
- salva a running-config.

### 6.8 Execução da troca em Server SSL

Para cada Server SSL Profile alvo:

- lê o estado atual de `cert`, `key` e `chain`;
- importa o certificado novo no F5;
- importa a key nova;
- importa a chain, se habilitado;
- atualiza o Server SSL Profile via API REST;
- relê o profile para validar a configuração aplicada;
- salva a running-config.

### 6.9 Validação TLS + HTTP para Client SSL

Ao final do grupo, a automação valida:

- **TLS**: compara o `enddate` visto no handshake com a validade esperada do certificado novo;
- **HTTP**: valida o status code retornado pelo path informado.

A validação usa:

- `target` descoberto automaticamente;
- SNI baseada nas SANs do certificado novo;
- `single_validate_path` como path;
- `[200]` como código esperado padrão.

> A validação não depende de DNS externo. Quando há `curl`, a automação usa `--resolve`, forçando o hostname a apontar para o IP do target descoberto.

### 6.10 Validação config_only para Server SSL

Para Server SSL, a validação padrão é `config_only`.

Depois da troca, a automação relê o Server SSL Profile pela API e compara:

- `cert` esperado x `cert` atual;
- `key` esperada x `key` atual;
- `chain` esperada x `chain` atual.

Essa validação confirma que a configuração foi aplicada corretamente no F5. Ela não valida diretamente se o backend aceitou o certificado, pois o Server SSL é usado no fluxo F5 -> backend.

### 6.11 Config Sync após apply

Se `f5_enable_configsync=true`, a automação executa Config Sync após alterações no site:

1. salva a configuração;
2. executa `sync device-to-group`;
3. valida o status;
4. registra o resultado no relatório.

---

## 7. Funcionamento do `check`

No modo `check`, a automação:

- inventaria certificados instalados por site;
- cruza uso por profile e chain;
- diferencia uso por Client SSL, Server SSL, Client SSL / CADEIA e Server SSL / CADEIA;
- classifica certificados em `expired`, `critical`, `warning` e `ok`;
- detecta duplicidade por SAN / Subject;
- opcionalmente executa limpeza automática de duplicados expirados;
- opcionalmente executa limpeza automática de certificados expirados sem uso;
- recalcula o relatório para refletir o estado pós-cleanup da mesma execução;
- executa Config Sync se algum cleanup fez alteração e o sync estiver habilitado.

### 7.1 Regras de duplicidade

- certificados são agrupados por `SAN` e, se necessário, por `Subject`;
- o item mais antigo do grupo é usado como referência para o status da duplicidade;
- se o mais antigo estiver expirado há pelo menos `f5_duplicate_delete_grace_days`, ele vira **candidato**;
- se `f5_duplicate_cleanup_only_if_not_in_use=true`, a automação não remove certificados ainda em uso;
- se `f5_duplicate_cleanup_only_if_not_in_use=false`, a automação pode reapontar Client SSL Profile para outro certificado válido antes de remover o antigo.

> O reapontamento agressivo automático para Server SSL foi mantido como evolução futura. Atualmente, certificados em uso por Server SSL são protegidos contra deleção indevida.

### 7.2 Cleanup de expirados sem uso

Quando `f5_enable_expired_unused_cleanup=true`, a automação pode remover certificados que atendam aos critérios:

- estão expirados;
- expiraram há pelo menos `f5_expired_unused_delete_grace_days`;
- não estão em uso por Client SSL;
- não estão em uso por Server SSL;
- não estão em uso como chain de Client SSL;
- não estão em uso como chain de Server SSL;
- não pertencem a grupo duplicado, se `f5_expired_unused_only_non_duplicated=true`;
- não batem nos padrões protegidos em `f5_expired_unused_protected_patterns`.

---

## 8. Funcionamento do `compare`

No modo `compare`, a automação realiza uma auditoria entre sites F5.

Exemplo:

```yaml
f5_certs_mode: compare
f5_target_scope: prd,dr
f5_compare_baseline_site: prd
f5_ssl_profile_scope: all
```

A variável `f5_compare_baseline_site` define o site base. Os demais sites do `f5_target_scope` são comparados contra ele.

O compare respeita `f5_ssl_profile_scope`:

- `client`: compara somente certificados em uso por Client SSL;
- `server`: compara somente certificados em uso por Server SSL;
- `all`: compara Client SSL e Server SSL.

O compare pode identificar:

- certificado existente no site base e ausente no site comparado;
- certificado existente no site comparado e ausente no site base;
- mesmo SAN/Subject com certificado diferente;
- diferença de vencimento;
- cadeia/intermediária diferente;
- key referenciada diferente;
- provável lado desatualizado.

Esse modo não altera nada no F5. Ele apenas gera relatório de auditoria.

---

## 9. Saída / Relatório

### APPLY

O relatório HTML contém uma seção por grupo de rotação com:

- site / F5 alvo;
- origem da descoberta;
- certificado atual compartilhado;
- profiles alterados;
- tipo do profile alterado: Client SSL ou Server SSL;
- pasta do CIFS usada;
- before / after do cert/key/chain;
- virtuals / pools / targets, quando aplicável;
- validação TLS + HTTP para Client SSL;
- validação config_only para Server SSL;
- Config Sync HA, quando executado.

### CHECK / LIST

O relatório contém por site:

- cards com contagem de `expired`, `critical`, `warning`, `ok` e `duplicates`;
- tabela de expirados;
- tabela de críticos;
- tabela de warning;
- tabela de OK no modo `list`;
- indicação de uso por `CLIENT SSL`, `SERVER SSL`, `CLIENT SSL / CADEIA` e `SERVER SSL / CADEIA`;
- tabela de duplicidade;
- bloco de limpeza de duplicados executada;
- bloco de limpeza de expirados sem uso executada;
- Config Sync HA, quando executado.

### COMPARE

O relatório contém:

- site base;
- sites comparados;
- total de itens analisados;
- divergências encontradas;
- certificados ausentes;
- versões diferentes;
- chain diferente;
- key referenciada diferente;
- provável lado desatualizado.

### FALHA

Quando ocorre falha operacional, a automação publica um e-mail de falha com:

- task que falhou;
- módulo/ação;
- mensagem resumida;
- diagnóstico provável;
- orientação de correção;
- parâmetros principais;
- detalhes técnicos da falha.

### Artefatos publicados

- `send_mail_subject`
- `send_mail_body`

---

## 10. Observações importantes

### Client SSL x Server SSL

Client SSL é usado no fluxo:

```text
Usuário/Navegador -> HTTPS -> F5
```

Nesse caso, o F5 apresenta o certificado para o usuário/navegador.

Server SSL é usado no fluxo:

```text
F5 -> HTTPS -> Backend
```

Quando o Server SSL Profile possui `cert`, `key` e `chain`, o F5 pode apresentar um certificado ao backend, normalmente em cenários de mTLS.

Nem todo Server SSL Profile possui certificado próprio. Em muitos casos, ele pode aparecer com `Certificate=None`, `Key=None` e `Chain=none`. Nesse cenário, não há certificado Server SSL para a automação rotacionar no F5.

### O certificado é global no F5

O certificado não é Client SSL ou Server SSL por natureza. Ele é um objeto global instalado no F5. Quem define o uso é o profile que referencia esse certificado.

Por isso, no modo `list`, a automação mostra todos os certificados instalados no F5. O escopo `client/server/all` afeta principalmente as ações de `compare`, `apply` e a proteção de cleanup.

### Cleanup agressivo de Server SSL

O cleanup agressivo de duplicados com reapontamento automático de Server SSL foi mantido como evolução futura. Atualmente, quando um certificado está em uso por Server SSL, a automação protege o item e evita deleção indevida.