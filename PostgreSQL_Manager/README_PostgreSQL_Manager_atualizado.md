# PostgreSQL Manager

Automação Ansible para **backup, restore e sincronização controlada de bancos PostgreSQL**, com uso de CIFS, inventário dinâmico por ambiente, modos de restore `promote` e `drop_in_place`, preservação de dados do destino, DBLink/Foreign Server/User Mapping, masking, manutenção pós-restore, controle de conexões e relatório HTML.

---

## 1. Ações

| Ação | Descrição |
| --- | --- |
| `backup` | Gera um novo dump da origem e publica no CIFS. |
| `restore` | Restaura um dump existente (`latest` ou nome específico). |
| `sync` | Gera um novo backup e, se concluído com sucesso, restaura nos destinos. |

```text
backup  = dump novo
restore = usa dump existente
sync    = backup novo + restore
```

---

## 2. Survey do AAP

| Campo | Variável | Descrição |
| --- | --- | --- |
| Ação | `pgm_action` | `backup`, `restore` ou `sync`. |
| Banco | `pgm_database_key` | Profile em `config/postgres_manager/databases`. |
| Origem | `pgm_source_env` | Ambiente de origem do backup ou referência do `latest`. |
| Destinos | `pgm_target_envs` | Um ou mais ambientes para restore/sync. |
| Hosts específicos | `pgm_target_hosts` | Filtro opcional de hosts do destino. |
| Dump | `pgm_restore_dump_name` | `latest` ou nome exato do `.dump.dir`. |
| Confirmação | `pgm_confirm_restore` | Restore/sync exigem `sim`. |
| Motivo | `pgm_execution_reason` | Justificativa operacional exibida no relatório. |

O manifesto `latest` é separado por banco e ambiente de origem, por exemplo:

```text
latest_dbcvm_prd.txt
latest_dbcvm_tu.txt
```

No `sync`, um novo backup é sempre criado antes do restore.

---

## 3. Fluxo da automação

```text
controller
  ├── normaliza survey
  ├── carrega profile
  ├── consolida pgm_db_cfg
  ├── resolve origem/destinos
  └── cria hosts dinâmicos

backup
  ├── pg_dump
  ├── validação
  └── publicação no CIFS

sync barrier
  └── impede restore se o backup falhar

restore
  ├── captura grants
  ├── resolve promote ou drop_in_place
  ├── prepara a base conforme o modo
  ├── pg_restore
  ├── reaplica grants
  ├── preserve_data
  ├── post_restore
  ├── dblink / foreign servers / user mappings
  ├── masking
  ├── refresh materialized views
  ├── maintenance
  ├── connection_control
  └── validações

report
  ├── coleta logs
  ├── publica anexos no CIFS
  └── gera HTML + set_stats
```

---

## 4. Backup

```yaml
backup:
  root_dir: "/backup/postgres_manager"
  jobs: 4
  format: "directory"
  extra_args: ""
  validate_dump: true
```

O formato atualmente homologado é `directory`. Quando `validate_dump=true`, o dump é validado com `pg_restore -l` antes da publicação.

---

## 5. Modos de Restore

O PostgreSQL Manager suporta os modos:

```text
promote
drop_in_place
```

O modo padrão é definido no profile:

```yaml
restore:
  mode: "promote"
```

Opcionalmente, cada host pode sobrescrever o modo através de `restore_mode`.

| Modo | Funcionamento | Espaço adicional | Indisponibilidade | Base anterior |
| --- | --- | --- | --- | --- |
| `promote` | Restaura em `<db>_restoring` e realiza o cutover ao final. | Maior | Principalmente no cutover. | Mantida como `<db>_old`. |
| `drop_in_place` | Remove a base atual e restaura diretamente no nome definitivo. | Menor | Durante o restore. | Não é mantida. |

### 5.1 `promote`

```yaml
restore:
  mode: "promote"
  target_temp_suffix: "_restoring"
  old_suffix: "_old"
  no_owner: true
  no_privileges: true
  jobs: 4
  extra_args: ""
```

Exemplo:

```text
dbcvm
  ↓ restore preparado em
dbcvm_restoring

cutover:
dbcvm           -> dbcvm_old
dbcvm_restoring -> dbcvm
```

Quase todo o processamento ocorre na `_restoring`; o cutover acontece somente no final.

### 5.2 `drop_in_place`

O modo `drop_in_place` é destinado principalmente a servidores que não possuem espaço suficiente para manter simultaneamente a base atual e uma segunda base `_restoring`.

Fluxo simplificado:

```text
captura grants
captura propriedades e preserve_data
bloqueia conexões
DROP da base atual
CREATE da base definitiva
pg_restore
grants
preserve_data
post_restore
dblink
masking
materialized views
maintenance
validações
liberação da base
```

Nesse modo:

- não são mantidas as bases `_restoring` e `_old`;
- `preserve_data` é capturado antes da remoção da base;
- a base é recriada preservando as propriedades configuradas por `database_create`;
- durante o restore é utilizado `CONNECTION LIMIT 0` temporariamente;
- ao final, o connection limit original é restaurado e a base é liberada.

> **Atenção:** o `drop_in_place` remove a base anterior antes do `pg_restore`. Não existe rollback local através de `<db>_old`. Se ocorrer falha após a remoção da base, a automação não libera automaticamente uma base incompleta para uso; a recuperação deve ser realizada a partir de um backup válido.

O usuário PostgreSQL utilizado pelo `drop_in_place` deve possuir privilégio de superuser para permitir a execução administrativa durante o período em que o connection limit temporário está em `0`. A automação valida esse requisito antes da etapa destrutiva e não altera automaticamente os privilégios do usuário.

### Criação da base de restore

```yaml
database_create:
  inherit_from_current: true
  validate_inheritance: true
```

- `inherit_from_current`: herda owner, encoding, locale, tablespace e connection limit da base atual do destino.
- `validate_inheritance`: compara as propriedades após a criação e falha antes do `pg_restore` se houver divergência.

A criação utiliza `template0` para gerar uma database vazia. No `promote`, as propriedades são aplicadas à `_restoring`; no `drop_in_place`, são utilizadas para recriar a própria base definitiva.

---

## 6. Grants

```yaml
grants:
  capture_before_restore: true
  apply_after_restore: true
  fail_on_apply_error: false
```

Os grants atuais do destino podem ser capturados antes do restore e reaplicados na base restaurada.

---

## 7. Preserve Data

Mantém dados específicos do ambiente destino.

```yaml
preserve_data:
  enabled: true
  fail_on_error: true
  run_on_envs: ["tu", "th", "fix"]
  groups:
    - name: "environment_configuration"
      backup_tables:
        - "app.environment_config"
        - "app.feature_flags"
      truncate_tables:
        - "app.environment_config"
        - "app.feature_flags"
      restore_data_only: true
      disable_triggers: true
      cascade: false
      jobs: 4
```

- `backup_tables`: dados atuais do destino que serão preservados.
- `truncate_tables`: tabelas esvaziadas na base restaurada antes da reinserção.
- `restore_data_only`: restaura somente os dados preservados.
- `disable_triggers`: evita triggers durante a reinserção.
- `cascade`: controla `TRUNCATE ... CASCADE`.
- `fail_on_error=true`: erro interrompe o fluxo de restore.

A captura usa `--strict-names` para não ignorar silenciosamente tabelas configuradas que não existem.

No `promote`, os dados podem ser capturados da base ativa enquanto a `_restoring` é preparada. No `drop_in_place`, a captura ocorre obrigatoriamente antes da remoção da base atual.

---

## 8. Post Restore

Usado para remover dados restaurados da origem que não devem permanecer no destino.

```yaml
post_restore:
  truncate_enabled: true
  fail_on_error: true
  run_on_envs: ["tu", "th", "fix"]
  truncate_groups:
    - name: "clear_runtime_sessions"
      tables:
        - "app.runtime_sessions"
      cascade: false
```

---

## 9. DBLink / Foreign Servers / User Mappings

A automação suporta múltiplos Foreign Servers e User Mappings.

```yaml
dblink:
  enabled: true

  servers:
    - name: "remote_valemobi"
      environments:
        prd: {host: "127.0.0.1", port: "5432", dbname: "valemobi"}
        tu:  {host: "127.0.0.1", port: "5432", dbname: "valemobi"}

  user_mappings:
    - server_name: "remote_valemobi"
      local_user: "postgres"
      user_var: "dblink_user"
      password_var: "dblink_password"

  connections:
    - name: "myconn"
      server_name: "remote_valemobi"
      connect_before_refresh: true
```

- `servers`: define endpoints por ambiente.
- `user_mappings`: recria os mappings usando variáveis de Credential do AAP.
- `connections`: define conexões dblink nomeadas, quando necessárias.

`USER MAPPING` normalmente deve ser excluído do TOC para evitar trazer mappings da origem.

---

## 10. Masking

```yaml
masking:
  enabled: true
  fail_on_error: true
  run_on_envs: ["tu", "th", "fix"]
  protected_envs: ["prd"]
  scripts:
    - name: "dbcvm_lab_scramble"
      file: "masking/fc_dbcvm_lab_scramble_database.sql"
      function: "public.fc_dbcvm_lab_scramble_database"
      execute_function: true
```

O masking executa depois de `preserve_data`, `post_restore` e `dblink`, e antes do refresh das Materialized Views.

Se `fail_on_error=true`, falha de masking interrompe o fluxo antes da conclusão/liberação da base.

---

## 11. Materialized Views

```yaml
materialized_views:
  refresh_enabled: true
  refresh_all: false
  items:
    - schema: "public"
      name: "mv_search_companys"
      concurrently: false
```

- `refresh_all=true`: atualiza todas as MVs encontradas.
- `refresh_all=false`: atualiza apenas `items`.
- `concurrently=true`: usa `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

Para MVs que usam `dblink('myconn', ...)`, configure uma entrada em `dblink.connections`.

---

## 12. Maintenance

```yaml
maintenance:
  enabled: true
  mode: "analyze"
```

Modos:

```text
none
analyze
vacuum_analyze
```

Esse bloco substitui o antigo `restore.vacuum_analyze`.

---

## 13. Connection Control

Substitui o antigo bloqueio de usuário com `NOLOGIN`.

```yaml
connection_control:
  enabled: true
  block_new_connections: true
  terminate_sessions: true
  keep_old_blocked: true
```

No `promote`:

- `block_new_connections`: impede novas conexões na base atual antes do cutover.
- `terminate_sessions`: encerra sessões já abertas.
- `keep_old_blocked`: mantém a `_old` bloqueada depois do promote.

Estado esperado:

```text
dbcvm     -> conexões liberadas
dbcvm_old -> conexões bloqueadas
```

No `drop_in_place`, as conexões são bloqueadas antes da remoção da base. A nova base utiliza `CONNECTION LIMIT 0` durante o restore e somente é liberada após a conclusão das etapas e validações.

O usuário PostgreSQL continua com `LOGIN` habilitado no cluster.

---

## 14. TOC Patterns

```yaml
restore:
  exclude_toc_patterns:
    - "USER MAPPING"
    - "MATERIALIZED VIEW DATA public mv_search_companys"
```

| Pattern | Objetivo |
| --- | --- |
| `USER MAPPING` | Evita trazer mappings da origem; são recriados no destino. |
| `MATERIALIZED VIEW DATA ...` | Evita restaurar dados antigos da MV; o conteúdo é recalculado no destino. |

---

## 15. Validações

```yaml
validations:
  enabled: true
  queries:
    - "queries/total.sql"
    - "queries/total-by-table.sql"
```

As queries executam após as etapas principais do restore e o resultado é gravado no log. No `promote`, executam após o cutover; no `drop_in_place`, executam antes da liberação final da base.

---

## 16. Hosts por ambiente

```yaml
hosts_env_sync:
  prd:
    - name: "prd-dbcvm-01"
      ansible_host: "192.168.122.165"
      database_name: "dbcvm"
      port: 5432
      db_host: "127.0.0.1"
      source: true
      enabled: true

  tu:
    - name: "tu-dbcvm-01"
      ansible_host: "192.168.122.34"
      database_name: "dbcvm"
      port: 5432
      db_host: "127.0.0.1"
      restore_mode: "promote"
      source: true
      enabled: true

  fix:
    - name: "fix-dbcvm-01"
      ansible_host: "192.168.122.33"
      database_name: "dbcvm"
      port: 5432
      db_host: "127.0.0.1"
      restore_mode: "drop_in_place"
      source: true
      enabled: true
```

`restore_mode` é um override opcional por host e aceita `promote` ou `drop_in_place`.

Precedência:

```text
restore_mode do host
  -> restore.mode do profile
  -> pgm_restore_mode dos defaults
```

Hosts sem `restore_mode` utilizam o modo definido no profile.

Credenciais SSH/PostgreSQL devem preferencialmente vir das Credentials do AAP.

---

## 17. Configuração efetiva

A automação usa três níveis principais:

```text
Survey / extra vars
  -> define o que executar

defaults/main.yml
  -> define comportamento padrão da role

profile do banco
  -> define como aquele banco deve ser tratado
```

Durante o planejamento, `pgm_database_defaults` é combinado com o profile selecionado e gera `pgm_db_cfg`, utilizado pelos hosts dinâmicos.

O `restore_mode` definido diretamente no host possui precedência sobre `restore.mode` do profile.

---

## 18. Estrutura principal

| Arquivo | Descrição |
| --- | --- |
| `postgres_manager.yml` | Playbook principal. |
| `config/postgres_manager/databases/*.yml` | Profiles por banco. |
| `roles/postgres_manager/defaults/main.yml` | Defaults técnicos e globais da role. |
| `roles/postgres_manager/tasks/controller.yml` | Planejamento. |
| `roles/postgres_manager/tasks/backup.yml` | Backup e publicação no CIFS. |
| `roles/postgres_manager/tasks/restore.yml` | Orquestra os modos `promote` e `drop_in_place`. |
| `roles/postgres_manager/tasks/35_prepare_restore_database.yml` | Criação da `_restoring` no `promote` ou recriação da base no `drop_in_place`. |
| `roles/postgres_manager/tasks/40_preserve_data.yml` | Preservação de dados do destino. |
| `roles/postgres_manager/tasks/41_preserve_data_group.yml` | Processamento de cada grupo de preserve. |
| `roles/postgres_manager/tasks/42_post_restore.yml` | Truncates pós-restore. |
| `roles/postgres_manager/tasks/43_dblink.yml` | Foreign Servers, User Mappings e conexões dblink. |
| `roles/postgres_manager/tasks/45_maintenance.yml` | `ANALYZE` / `VACUUM ANALYZE`. |
| `roles/postgres_manager/tasks/46_connection_control.yml` | Controle de conexões antes do cutover ou `drop_in_place`. |
| `roles/postgres_manager/tasks/47_connection_control_finalize.yml` | Finalização das conexões conforme o modo de restore. |
| `roles/postgres_manager/tasks/report.yml` | Consolidação do relatório. |
| `roles/postgres_manager/templates/email_report.html.j2` | Relatório HTML. |
| `roles/postgres_manager/files/masking/*.sql` | Scripts de masking. |
| `queries/*.sql` | Queries de validação. |

---

## 19. Artefatos e relatório

A automação pode gerar:

- dump directory;
- manifesto `latest`;
- log de backup;
- log de restore;
- arquivo SQL de grants;
- relatório HTML.

O relatório informa também o modo efetivo utilizado por cada host (`promote` ou `drop_in_place`).

O relatório publica via `set_stats`:

```yaml
send_mail_subject: "..."
send_mail_body: "..."
send_mail_attachments:
  - "..."
```

---

## 20. Execução via CLI

Backup:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=backup" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd"
```

Restore:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=restore" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_target_envs=tu" \
  -e "pgm_restore_dump_name=latest" \
  -e "pgm_confirm_restore=sim"
```

Sync:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=sync" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_target_envs=tu,th" \
  -e "pgm_confirm_restore=sim"
```
