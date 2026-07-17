# Quay Sync Manager

Automação Ansible para **validação e sincronização controlada de repository mirrors entre Red Hat Quay PRD e DR**, com execução em modo `check` ou `sync`, descoberta de repositories mirror, comparação de tags e digests, respeito aos filtros de mirror, paginação inteligente de tags e geração de relatório operacional em HTML para envio por e-mail.

A solução é composta por dois fluxos principais:

- **Quay Sync Manager**: executa validação de API, discovery de namespaces/repositories, coleta de mirror config, comparação PRD x DR, execução opcional de `sync-cancel` + `sync-now` e validação final.
- **Send Email**: job ou template externo que consome as variáveis publicadas por `set_stats`, como `send_mail_subject`, `send_mail_body` e `send_mail_attachments`, para envio do e-mail operacional.

---

## 1. Workflow operacional do Quay Sync

Exemplo de workflow:

```text
WF_Devops_Quay_Sync_Manager
  ├── MCA_Quay_Sync_Manager
  └── Test_Send_Email
```

O template `MCA_Quay_Sync_Manager` executa o playbook `quay_sync_manager.yml` e a role `quay_sync_manager`.

Principais capacidades:

- execução em modo `check`, sem alteração no Quay;
- execução em modo `sync`, acionando sincronização apenas para repositories divergentes;
- validação de API e tokens usando endpoint de repository por namespace;
- discovery de repositories visíveis no PRD e no DR;
- identificação automática de repositories com `state: MIRROR` no DR;
- coleta da configuração de mirror no DR;
- leitura dos filtros de mirror, como `*`, `release-*`, `v*` e `stable-*`;
- coleta de tags no PRD e no DR com paginação inteligente;
- comparação de tag + digest entre PRD e DR;
- classificação de divergências como tag ausente, digest diferente, tag extra ou tag ignorada por filtro;
- execução de `sync-cancel` antes do `sync-now`, quando configurado;
- espera e validação do status do mirror após o sync;
- nova comparação final depois do sync;
- geração de relatório HTML operacional;
- geração opcional de CSV/JSON com o resultado detalhado;
- relatório de falha controlado em caso de erro.

---

## 2. Variáveis principais da execução

| Variável | Exemplo | Descrição |
| -------- | ------- | --------- |
| `motivo` | `Validação Quay PRD x DR` | Justificativa exibida no relatório. |
| `quay_mode` | `check` ou `sync` | Define se a automação apenas valida ou também aciona sync. |
| `quay_discovery_namespaces` | `apps,qsync-lab-01` | Lista de namespaces/organizations avaliados. |
| `quay_source.url` | `https://quay-prd.exemplo.com` | URL do Quay de origem, normalmente PRD. |
| `quay_target.url` | `https://quay-dr.exemplo.com` | URL do Quay de destino, normalmente DR. |
| `quay_source.token` | via credential/Vault | Token OAuth usado para consultar o Quay PRD. |
| `quay_target.token` | via credential/Vault | Token OAuth usado para consultar e acionar mirror no Quay DR. |
| `quay_source.validate_certs` | `true` | Validação TLS do Quay PRD. |
| `quay_target.validate_certs` | `true` | Validação TLS do Quay DR. |

Exemplo mínimo para `check`:

```yaml
quay_mode: check
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

---

## 3. Modos de execução

| Modo | Comportamento | Quando usar |
| ---- | ------------- | ----------- |
| `check` | Consulta PRD e DR, compara tags/digests e gera relatório. Não altera o Quay. | Validação operacional, rotina diária, auditoria ou pré-check antes de sync. |
| `sync` | Faz a comparação inicial, identifica divergências, executa `sync-cancel` + `sync-now`, aguarda processamento e compara novamente. | Correção controlada de divergências entre PRD e DR. |

No modo `sync`, a automação só aciona repositories que tenham status candidato a sincronização.

Por padrão:

```yaml
quay_sync_candidate_statuses:
  - MISSING_TAG
  - DIGEST_MISMATCH
  - DIGEST_UNAVAILABLE
```

---

## 4. Segurança e credenciais

As credenciais do Quay não devem ficar abertas no survey.

Recomendação:

```yaml
quay_hide_sensitive_logs: true
```

Boas práticas:

- armazenar tokens em Credential, Vault ou variável protegida do AAP;
- não imprimir token no log;
- não colocar token diretamente no survey;
- usar token com escopo mínimo necessário para a automação;
- regenerar token caso ele seja exposto em job output ou print de erro;
- manter `validate_certs: true` em produção;
- usar `validate_certs: false` apenas em lab com certificado self-signed.

### 4.1 Escopos recomendados de token

| Uso | Quay | Escopos recomendados |
| --- | ---- | -------------------- |
| `check` origem | PRD | `repo:read` |
| `check` destino | DR | `repo:read` |
| `sync` origem | PRD | `repo:read` |
| `sync` destino | DR | `repo:read`, `repo:admin` |
| Script de massa/lab | PRD/DR | `user:admin`, `org:admin`, `repo:create`, `repo:read`, `repo:write`, `repo:admin` |

Erros comuns:

| Erro | Causa provável | Ação recomendada |
| ---- | -------------- | ---------------- |
| `invalid_token` | Token inválido, expirado ou usado em endpoint incompatível com o escopo. | Gerar novo token e validar endpoint usado. |
| `insufficient_scope` | Token válido, mas sem permissão para a ação. | Adicionar escopo necessário ou usar token adequado. |
| `401 Requires authentication` | Header ausente, token errado ou token sem acesso. | Validar variável, Credential e header Authorization. |
| `403 Unauthorized` | Token autenticou, mas não tem permissão no namespace/repository. | Validar permissões no Quay e escopos do token. |

---

## 5. Criação do token OAuth no Quay

O token deve ser criado na UI do Quay, normalmente dentro de uma organization usada para automações.

Fluxo recomendado:

1. Acesse o Quay com usuário administrador ou usuário com permissão para criar aplicações.
2. Entre na organization usada para automações.
3. Acesse **Applications**.
4. Crie uma nova aplicação ou selecione uma aplicação existente.
5. Acesse **Generate Token**.
6. Selecione os escopos necessários.
7. Autorize a aplicação.
8. Copie o token gerado.
9. Armazene o token em Credential/Vault do AAP.
10. Não cole o token diretamente no survey.

Validação rápida do token:

```bash
curl -k -H "Authorization: Bearer TOKEN" \
  "https://quay-prd.exemplo.com/api/v1/repository?namespace=apps&last_modified=true"
```

Validação de mirror config no DR:

```bash
curl -k -H "Authorization: Bearer TOKEN" \
  "https://quay-dr.exemplo.com/api/v1/repository/apps/backend/mirror"
```

Em caso de `insufficient_scope`, o token é válido, mas não possui escopo suficiente para a operação solicitada.

---

## 6. Comparação PRD x DR

A automação compara as tags do PRD e do DR respeitando o filtro configurado no mirror.

Exemplos de filtros:

| Filtro | Comportamento |
| ------ | ------------- |
| `*` | Todas as tags do repository devem existir no DR. |
| `release-*` | Apenas tags iniciadas com `release-` devem sincronizar. |
| `v*` | Apenas tags iniciadas com `v` devem sincronizar. |
| `stable-*` | Apenas tags iniciadas com `stable-` devem sincronizar. |

Principais status:

| Status técnico | Nome no relatório | Significado |
| -------------- | ----------------- | ----------- |
| `OK` | Sincronizado | Tag existe nos dois lados com digest igual. |
| `DIGEST_MISMATCH` | Diferença de digest | Tag existe nos dois lados, mas aponta para digest diferente. |
| `MISSING_TAG` | Tag ausente no DR | Tag existe no PRD, casa com o filtro, mas não existe no DR. |
| `SKIPPED_BY_FILTER` | Ignorado pelo filtro | Tag não casa com o filtro do mirror; ausência no DR é esperada. |
| `EXTRA_TAG_ON_TARGET` | Tag extra no DR | Tag existe no DR, mas não foi encontrada no PRD. |
| `DIGEST_UNAVAILABLE` | Digest indisponível | Tag existe, mas não foi possível comparar digest. |
| `MIRROR_DISABLED` | Mirror desabilitado | Repository mirror existe, mas está desabilitado. |
| `TAG_COLLECTION_ERROR` | Erro ao coletar tags | Falha de API ao consultar tags no PRD ou DR. |

---

## 7. Paginação e performance

A coleta de tags usa paginação inteligente.

| Variável | Exemplo | Descrição |
| -------- | ------- | --------- |
| `quay_tag_page_limit` | `100` | Quantidade de tags por página consultada na API. |
| `quay_max_pages` | `10` | Limite máximo de páginas por repository. |
| `quay_tag_pagination_stop_when_page_not_full` | `true` | Para de consultar novas páginas quando a página anterior vem incompleta. |
| `quay_debug_enabled` | `false` | Controla logs detalhados no AAP. |

Comportamento:

```text
page 1 retornou 5 tags com limit=100
  -> não consulta page 2

page 1 retornou 100 tags com limit=100
  -> consulta page 2, até no máximo quay_max_pages
```

Recomendação para produção:

```yaml
quay_tag_page_limit: 100
quay_max_pages: 10
quay_tag_pagination_stop_when_page_not_full: true
quay_debug_enabled: false
```

---

## 8. Funcionamento do sync

No modo `sync`, a automação executa o seguinte fluxo:

1. descobre repositories mirror no DR;
2. coleta mirror config;
3. coleta tags no PRD e DR;
4. compara estado inicial;
5. identifica repositories candidatos;
6. executa `sync-cancel`, quando habilitado;
7. executa `sync-now`;
8. aguarda início/processamento do mirror;
9. consulta status do mirror até `SUCCESS` ou limite de retries;
10. recoleta mirror config;
11. recoleta tags no PRD e DR;
12. compara estado final;
13. gera relatório HTML.

Variáveis principais:

| Variável | Exemplo | Descrição |
| -------- | ------- | --------- |
| `quay_sync_cancel_before_now` | `true` | Executa `sync-cancel` antes de `sync-now`. |
| `quay_sync_wait_after_trigger_seconds` | `20` | Espera inicial após acionar `sync-now`. |
| `quay_sync_retries` | `10` | Quantidade de tentativas para aguardar status do mirror. |
| `quay_sync_delay` | `30` | Intervalo em segundos entre tentativas. |

Observação:

```text
HTTP 404 no sync-cancel normalmente significa que não havia sync ativo para cancelar.
```

O resultado efetivo não é o HTTP do `sync-now`, mas sim a comparação final de tag + digest.

---

## 9. Relatório operacional e artefatos

Em cada execução, a automação publica:

```yaml
send_mail_subject: "Assunto do e-mail"
send_mail_body: "HTML do relatório"
send_mail_attachments: []
```

O relatório HTML mostra:

- modo de execução;
- job id;
- origem e destino;
- namespaces avaliados;
- quantidade de repositories mirror;
- quantidade de tags avaliadas;
- divergências críticas;
- candidatos a sync;
- resumo de status;
- resumo dos mirrors;
- resultado da comparação;
- resultado do sync, quando aplicável.

Variáveis de relatório:

| Variável | Exemplo | Descrição |
| -------- | ------- | --------- |
| `quay_report_namespace_preview_limit` | `5` | Quantidade de namespaces exibidos como amostra no e-mail. |
| `quay_report_max_rows` | `200` | Limite de linhas exibidas na tabela de comparação. |
| `quay_report_show_mirror_config` | `false` | Exibe ou oculta a tabela detalhada de mirror config. |
| `quay_report_mirror_config_max_rows` | `30` | Limite de linhas da tabela de mirror config. |
| `quay_report_show_ok_rows` | `false` | Exibe ou oculta linhas OK no e-mail. |
| `quay_report_attach_artifacts` | `false` | Define se CSV/JSON serão anexados. |

Arquivos locais gerados:

| Artefato | Descrição |
| -------- | --------- |
| `quay_result.json` | Resultado consolidado da execução. |
| `quay_compare_initial.json` | Comparação inicial em JSON. |
| `quay_compare_initial.csv` | Comparação inicial em CSV. |
| `quay_compare_final.json` | Comparação final em JSON. |
| `quay_compare_final.csv` | Comparação final em CSV. |
| `quay_sync_actions.json` | Ações de sync executadas. |

Diretório padrão:

```text
/tmp/quay-sync-manager-<job_id>
```

---

## 10. Publicação opcional de anexos em CIFS

Quando habilitado, os arquivos CSV/JSON podem ser publicados no CIFS para envio como anexo.

Variáveis principais:

| Variável | Exemplo | Descrição |
| -------- | ------- | --------- |
| `quay_report_attach_artifacts` | `true` | Habilita anexos locais no e-mail. |
| `quay_report_cifs_upload_enabled` | `true` | Habilita upload dos anexos para CIFS. |
| `send_mail_cifs` | `producao` | Alias do CIFS usado para upload. |
| `send_mail_cifs_path` | `/Ansible/mail_attachments` | Caminho remoto usado pelo job de e-mail. |
| `quay_report_cifs_delegate` | `localhost` | Host que executa o `smbclient`. |

Recomendação inicial:

```yaml
quay_report_attach_artifacts: false
quay_report_cifs_upload_enabled: false
```

Habilite anexos somente se o cliente precisar do CSV/JSON completo fora do AAP.

---

## 11. Estrutura de arquivos

| Arquivo | Descrição |
| ------- | --------- |
| `quay_sync_manager.yml` | Playbook principal da automação. |
| `roles/quay_sync_manager/defaults/main.yml` | Variáveis padrão da role. |
| `roles/quay_sync_manager/tasks/main.yml` | Orquestra as etapas principais e trata falhas. |
| `roles/quay_sync_manager/tasks/00_validate_inputs.yml` | Valida variáveis obrigatórias e normaliza URLs/flags. |
| `roles/quay_sync_manager/tasks/10_check_api_access.yml` | Valida conectividade e tokens usando endpoint de repository. |
| `roles/quay_sync_manager/tasks/20_collect_repositories.yml` | Lista repositories no PRD e DR por namespace. |
| `roles/quay_sync_manager/tasks/30_collect_mirror_config.yml` | Consulta e normaliza a configuração de mirror dos repositories no DR. |
| `roles/quay_sync_manager/tasks/40_collect_tags.yml` | Inicializa coleta de tags e normaliza resultados. |
| `roles/quay_sync_manager/tasks/41_collect_tags_page.yml` | Coleta páginas de tags com paginação inteligente/recursiva. |
| `roles/quay_sync_manager/tasks/50_compare_tags.yml` | Compara tags e digests entre PRD e DR. |
| `roles/quay_sync_manager/tasks/60_sync_repositories.yml` | Executa `sync-cancel`, `sync-now`, espera mirror e recoleta estado final. |
| `roles/quay_sync_manager/tasks/70_finalize_result.yml` | Consolida o resultado final da execução. |
| `roles/quay_sync_manager/tasks/80_build_report.yml` | Monta e publica variáveis de e-mail. |
| `roles/quay_sync_manager/tasks/90_apply_failure_policy.yml` | Aplica política opcional de falha quando há divergência. |
| `roles/quay_sync_manager/tasks/95_build_failure_report.yml` | Monta relatório de falha operacional. |
| `roles/quay_sync_manager/templates/quay_report.html.j2` | Template HTML do relatório operacional. |
| `roles/quay_sync_manager/templates/quay_report_failure.html.j2` | Template HTML de falha. |
| `roles/quay_sync_manager/templates/quay_compare.csv.j2` | Template CSV do resultado detalhado da comparação. |

---

## 12. Execução via CLI

Check:

```bash
ansible-playbook quay_sync_manager.yml \
  -e "quay_mode=check" \
  -e "motivo=Validação Quay PRD x DR" \
  -e '{"quay_discovery_namespaces":["apps"]}' \
  -e '{"quay_source":{"name":"PRD","url":"https://quay-prd.exemplo.com","token":"TOKEN_PRD","validate_certs":true}}' \
  -e '{"quay_target":{"name":"DR","url":"https://quay-dr.exemplo.com","token":"TOKEN_DR","validate_certs":true}}'
```

Sync:

```bash
ansible-playbook quay_sync_manager.yml \
  -e "quay_mode=sync" \
  -e "motivo=Sincronização controlada Quay PRD x DR" \
  -e '{"quay_discovery_namespaces":["apps"]}' \
  -e '{"quay_source":{"name":"PRD","url":"https://quay-prd.exemplo.com","token":"TOKEN_PRD","validate_certs":true}}' \
  -e '{"quay_target":{"name":"DR","url":"https://quay-dr.exemplo.com","token":"TOKEN_DR","validate_certs":true}}'
```

Lab com certificado self-signed:

```yaml
quay_source:
  validate_certs: false

quay_target:
  validate_certs: false
```

---

## 13. Testes operacionais recomendados

| Teste | Condição | Resultado esperado |
| ----- | -------- | ------------------ |
| Check sem divergência | PRD e DR sincronizados | Relatório OK, sem candidatos a sync. |
| Check com digest diferente | Recriar imagem no PRD sem sincronizar DR | Relatório mostra `Diferença de digest`. |
| Check com tag nova | Criar tag no PRD que casa com o filtro | Relatório mostra `Tag ausente no DR`. |
| Tag fora do filtro | Criar `dev-1` em repo com filtro `release-*` | Relatório mostra `Ignorado pelo filtro`. |
| Sync com divergência | Executar `quay_mode=sync` após drift | Automação aciona sync e finaliza sem candidatos pendentes. |
| Token sem escopo | Usar token sem permissão suficiente | Falha controlada com orientação de token/scope. |
| Mirror desabilitado | Desabilitar mirror no DR | Relatório mostra `Mirror desabilitado`. |
| Certificado inválido | `validate_certs=true` com TLS inválido | Falha controlada de certificado/TLS. |

---

## 14. Scripts de massa para lab

Scripts opcionais usados para criar massa de teste:

| Script | Descrição |
| ------ | --------- |
| `generate_quay_lab_mass.sh` | Cria organizations, repositories, tags no PRD e configura mirrors no DR. |
| `generate_quay_lab_drift_only.sh` | Gera divergência somente no PRD, sem tocar no DR. |

Exemplo de massa:

```text
qsync-lab-01
qsync-lab-02
qsync-lab-03
qsync-lab-04
qsync-lab-05
qsync-lab-06
```

Exemplo de namespaces para survey:

```yaml
quay_discovery_namespaces:
  - qsync-lab-01
  - qsync-lab-02
  - qsync-lab-03
  - qsync-lab-04
  - qsync-lab-05
  - qsync-lab-06
```

Gerar diferença de digest sem acionar sync:

```bash
DRIFT_TYPE=digest ./generate_quay_lab_drift_only.sh
```

Gerar tag ausente no DR:

```bash
DRIFT_TYPE=missing ./generate_quay_lab_drift_only.sh
```

---

## 15. Recomendações para produção

Configuração recomendada:

```yaml
quay_mode: check
quay_hide_sensitive_logs: true
quay_fail_job_on_divergence: false
quay_tag_page_limit: 100
quay_max_pages: 10
quay_tag_pagination_stop_when_page_not_full: true
quay_debug_enabled: false
quay_report_show_mirror_config: false
quay_report_show_ok_rows: false
quay_report_attach_artifacts: false
quay_source:
  validate_certs: true
quay_target:
  validate_certs: true
```

Observações:

- use `check` em schedule recorrente para auditoria;
- use `sync` manualmente ou em janela controlada;
- mantenha tokens em Credential/Vault;
- habilite `quay_debug_enabled: true` apenas para troubleshooting;
- habilite anexos CSV/JSON apenas quando necessário;
- valide o volume de repositories e tags antes de definir schedule agressivo.
