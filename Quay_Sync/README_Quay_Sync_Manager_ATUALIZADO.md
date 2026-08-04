# Quay Sync Manager

Automação Ansible para validar e sincronizar repositories entre Red Hat Quay PRD e DR.

A role realiza discovery por namespace, cria mirrors ausentes quando habilitado, compara tags e digests, executa `sync-cancel`/`sync-now` em divergências e publica relatório HTML para o workflow de e-mail.

## 1. Modos de execução

| Modo | Comportamento |
| --- | --- |
| `check` | Apenas consulta PRD e DR, identifica mirrors ausentes/conflitos, compara tags e gera relatório. |
| `sync` | Pode criar mirrors ausentes, executar sync nos repositories divergentes e validar o estado final. |

```yaml
quay_mode: "check" # check | sync
```

## 2. Fluxo principal

```text
00_validate_inputs.yml
10_check_api_access.yml
20_collect_repositories.yml
  ├── 21_collect_repository_namespace.yml
  └── 22_collect_repository_page.yml
25_detect_missing_mirrors.yml
26_create_missing_mirrors.yml       # somente sync + auto-create
20_collect_repositories.yml          # redescoberta após criação
25_detect_missing_mirrors.yml        # revalidação
30_collect_mirror_config.yml
40_collect_tags.yml
  └── 41_collect_tags_page.yml
50_compare_tags.yml
60_sync_repositories.yml             # somente sync
70_finalize_result.yml
80_build_report.yml
90_apply_failure_policy.yml
```

Em caso de erro operacional, o `main.yml` executa o `95_build_failure_report.yml` e publica um relatório de falha.

## 3. Configuração básica

```yaml
quay_mode: "check"
motivo: "Validação Quay PRD x DR"

quay_source:
  name: "PRD"
  url: "https://quay-prd.exemplo.com"
  token: "{{ vault_quay_prd_token }}"
  validate_certs: true

quay_target:
  name: "DR"
  url: "https://quay-dr.exemplo.com"
  token: "{{ vault_quay_dr_token }}"
  validate_certs: true

quay_discovery_namespaces:
  - apps
  - middleware
```

## 4. Criação automática de mirrors

A automação compara todos os repositories do PRD com o DR.

| Situação | Ação |
| --- | --- |
| Repository existe no PRD e como `MIRROR` no DR | Segue para comparação de tags. |
| Repository existe no PRD e não existe no DR | Pode ser criado automaticamente no modo `sync`. |
| Repository existe no DR como `NORMAL` | É reportado como conflito e não é convertido automaticamente. |

Habilitação:

```yaml
quay_auto_create_missing_mirrors: true
```

Configuração padrão dos novos mirrors:

```yaml
quay_auto_mirror_repository_visibility: "private"
quay_auto_mirror_repository_description: "Mirror criado automaticamente pelo Quay Sync Manager"

quay_auto_mirror_enabled: true
quay_auto_mirror_sync_interval: 86400
quay_auto_mirror_skopeo_timeout_interval: 600

quay_auto_mirror_root_rule:
  rule_kind: "tag_glob_csv"
  rule_value:
    - "*"
```

O `external_reference` é montado com o endereço do PRD e o nome completo do repository:

```text
<registry-prd>/<namespace>/<repository>
```

## 5. Robots e credencial de origem

Existem duas credenciais diferentes.

### Robot do DR

Utilizado para gravar as imagens no repository de destino.

```yaml
quay_auto_mirror_robot_short_name: "mirror"
quay_auto_mirror_robot_auto_create: true
quay_auto_mirror_robot_repository_role: "write"
```

O nome final é:

```text
<namespace>+<quay_auto_mirror_robot_short_name>
```

Com `quay_auto_mirror_robot_auto_create: true`:

- reutiliza o robot quando ele já existe;
- cria o robot quando ele não existe.

Com `false`:

- reutiliza robots existentes;
- falha se algum robot necessário estiver ausente.

### Credencial do PRD

Utilizada pelo Quay DR para fazer pull das imagens no PRD.

```yaml
quay_auto_mirror_source_username: "{{ quay_prd_pull_username }}"
quay_auto_mirror_source_password: "{{ quay_prd_pull_password }}"
quay_auto_mirror_source_credentials_required: true
```

Essas credenciais devem ter leitura nos repositories do PRD e não devem ficar abertas no survey ou no Git.

## 6. Comparação e sync

A automação compara tag e digest entre PRD e DR, respeitando o filtro configurado no mirror.

Principais status:

| Status | Significado | Candidato a sync |
| --- | --- | --- |
| `OK` | Tag e digest iguais. | Não |
| `MISSING_TAG` | Tag esperada não existe no DR. | Sim |
| `DIGEST_MISMATCH` | Mesma tag com digest diferente. | Sim |
| `DIGEST_UNAVAILABLE` | Não foi possível comparar o digest. | Sim |
| `SKIPPED_BY_FILTER` | Tag fora do filtro do mirror. | Não |
| `EXTRA_TAG_ON_TARGET` | Tag existe somente no DR. | Não |
| `MIRROR_DISABLED` | Mirror desabilitado. | Não, mas é crítico |
| `TAG_COLLECTION_ERROR` | Erro na coleta de tags. | Sim |

```yaml
quay_sync_candidate_statuses:
  - MISSING_TAG
  - DIGEST_MISMATCH
  - DIGEST_UNAVAILABLE
```

No modo `sync`, para cada repository candidato:

```text
sync-cancel
sync-now
aguarda status do mirror
recoleta configurações e tags
executa comparação final
```

Variáveis principais:

```yaml
quay_sync_cancel_before_now: true
quay_sync_wait_after_trigger_seconds: 20
quay_sync_retries: 10
quay_sync_delay: 30
```

Falhas parciais de sync, timeout, status terminal e erro HTTP são registradas no relatório sem impedir a coleta final dos demais repositories.

## 7. Paginação

A automação utiliza paginação para repositories e tags.

```yaml
quay_repository_page_limit: 100
quay_tag_page_limit: 100
quay_max_pages: 10
quay_tag_pagination_stop_when_page_not_full: true
```

Quando uma página retorna menos itens que o limite, a próxima página não é consultada.

## 8. Segurança e permissões

```yaml
quay_hide_sensitive_logs: true
quay_debug_enabled: false
```

Armazene tokens e senhas em Credential, Vault ou variáveis protegidas do AAP.

Escopos esperados:

| Uso | Quay | Escopos |
| --- | --- | --- |
| Check | PRD | `repo:read` |
| Check | DR | `repo:read` |
| Sync sem criação automática | DR | `repo:read`, `repo:admin` |
| Sync com criação automática | DR | `repo:read`, `repo:create`, `repo:admin`, `org:admin` |
| Script de massa/lab | PRD/DR | `user:admin`, `org:admin`, `repo:create`, `repo:read`, `repo:write`, `repo:admin` |

Use `validate_certs: false` somente em ambientes de laboratório com certificado não confiável.

## 9. Relatório

A role publica via `set_stats`:

```yaml
send_mail_subject: "..."
send_mail_body: "..."
send_mail_attachments: []
```

O relatório apresenta:

- origem, destino, modo e namespaces;
- mirrors encontrados, ausentes, criados e conflitos;
- status de comparação de tags/digests;
- ações `sync-cancel` e `sync-now`;
- timeout, falhas de sync e erros HTTP;
- comparação inicial e final.

Principais opções:

```yaml
quay_report_show_mirror_config: false
quay_report_show_ok_rows: false
quay_report_max_rows: 200
quay_report_attach_artifacts: false
quay_fail_job_on_divergence: false
```

Artefatos locais:

```text
/tmp/quay-sync-manager-<job_id>/quay_result.json
/tmp/quay-sync-manager-<job_id>/quay_compare_initial.json
/tmp/quay-sync-manager-<job_id>/quay_compare_initial.csv
/tmp/quay-sync-manager-<job_id>/quay_compare_final.json
/tmp/quay-sync-manager-<job_id>/quay_compare_final.csv
/tmp/quay-sync-manager-<job_id>/quay_sync_actions.json
```

## 10. Estrutura de arquivos

| Arquivo | Função |
| --- | --- |
| `00_validate_inputs.yml` | Valida e normaliza a execução. |
| `10_check_api_access.yml` | Valida APIs e tokens. |
| `20_collect_repositories.yml` | Descobre repositories no PRD e DR. |
| `21_collect_repository_namespace.yml` | Controla a coleta por namespace. |
| `22_collect_repository_page.yml` | Consulta páginas de repositories. |
| `25_detect_missing_mirrors.yml` | Identifica mirrors ausentes e conflitos. |
| `26_create_missing_mirrors.yml` | Cria robot, repository, permissão e configuração de mirror. |
| `30_collect_mirror_config.yml` | Coleta configurações dos mirrors. |
| `40_collect_tags.yml` | Inicializa e consolida tags. |
| `41_collect_tags_page.yml` | Consulta páginas de tags. |
| `50_compare_tags.yml` | Compara tags/digests e define candidatos. |
| `60_sync_repositories.yml` | Executa e acompanha o sync. |
| `70_finalize_result.yml` | Consolida o resultado. |
| `80_build_report.yml` | Monta o relatório e publica `set_stats`. |
| `90_apply_failure_policy.yml` | Aplica política opcional de falha. |
| `95_build_failure_report.yml` | Monta relatório de erro operacional. |

## 11. Testes de laboratório

O script `generate_quay_lab_auto_mirror.sh` prepara os seguintes cenários:

```text
mirror já existente no DR
repository existente somente no PRD
robot existente no DR
robot ausente no DR
repository NORMAL no DR para teste de conflito
```

Testes principais:

1. executar `check` e validar mirrors ausentes sem alterações;
2. executar `sync` com criação automática;
3. executar novamente para validar idempotência;
4. gerar nova tag ou digest no PRD e validar o fluxo do `60_sync_repositories.yml`;
5. testar robot ausente com `quay_auto_mirror_robot_auto_create: false`.

Exemplo para criação automática:

```yaml
quay_mode: "sync"
quay_auto_create_missing_mirrors: true
quay_auto_mirror_robot_short_name: "mirror"
quay_auto_mirror_source_username: "{{ quay_prd_pull_username }}"
quay_auto_mirror_source_password: "{{ quay_prd_pull_password }}"
```
