# Oracle Manager

Automação Ansible para **backup, restore e sincronização controlada de schemas e tabelas Oracle**, utilizando Oracle Data Pump (`expdp`/`impdp`), CIFS, inventário dinâmico por ambiente, descoberta automática de `ORACLE_SID`/`ORACLE_HOME`/CDB/PDB, preservação de grants no restore de schema, controle de sessões, senha em runtime, validações pós-restore e relatório HTML.

---

## 1. Ações

| Ação | Descrição |
| --- | --- |
| `backup` | Gera um novo dump da origem e disponibiliza no CIFS conforme o `storage_mode`. |
| `restore` | Restaura um dump existente (`latest` ou nome específico). |
| `sync` | Gera um novo backup e, se concluído com sucesso, restaura o mesmo dump nos destinos. |

```text
backup  = dump novo
restore = usa dump existente
sync    = backup novo + restore
```

O escopo da execução pode ser `schema` ou `tables`.

---

## 2. Survey do AAP

| Campo | Variável | Descrição |
| --- | --- | --- |
| Ação | `orm_action` | `backup`, `restore` ou `sync`. |
| Profile/schema | `orm_profile_key` | Profile em `config/oracle_manager/databases`. |
| Escopo | `orm_scope` | `schema` para schema completo ou `tables` para tabelas específicas. |
| Origem | `orm_source_env` | Ambiente de origem do backup/sync ou referência do `latest`. |
| Host de origem | `orm_source_host` | Filtro opcional do host de origem. |
| Destinos | `orm_target_envs` | Um ou mais ambientes para restore/sync. |
| Hosts específicos | `orm_target_hosts` | Filtro opcional de hosts do destino. |
| Dump | `orm_restore_dump_name` | `latest` ou nome exato do `.dmp`. |
| Schemas | `orm_schemas` | Schemas específicos; vazio utiliza o profile. |
| Tabelas | `orm_tables` | Lista `OWNER.TABELA`. Obrigatória quando `orm_scope=tables`. |
| Ação para tabela existente | `orm_table_exists_action` | `truncate`, `replace` ou `skip` em restore/sync de `tables`. |
| Confirmação | `orm_confirm_restore` | Restore/sync exigem `sim`. |
| Confirmação multi-target | `orm_confirm_multi_target_restore` | Confirmação extra para restore puro com múltiplos destinos. |
| Senha | `orm_password` | Senha runtime do schema destino no escopo `schema`. |
| Motivo | `orm_execution_reason` | Justificativa operacional exibida no relatório. |

Quando `orm_restore_dump_name=latest`, a automação resolve o manifesto correspondente ao profile e ao ambiente de origem.

No `sync`, um novo backup é sempre criado antes do restore.

---

## 3. Escopos

O Oracle Manager suporta dois escopos:

```text
schema
tables
```

### 3.1 `schema`

Executa o fluxo completo do schema.

```text
expdp SCHEMAS
  ↓
dump
  ↓
prechecks de restore
  ↓
grants / sessões
  ↓
DROP USER ... CASCADE
  ↓
impdp SCHEMAS
  ↓
senha / unlock
  ↓
grants
  ↓
validações
```

No restore de `schema`, a automação controla senha, grants, sessões, DROP do usuário, import, desbloqueio e validações pós-restore.

### 3.2 `tables`

Executa somente as tabelas informadas em `orm_tables`.

Exemplo:

```text
PRA_RISKMANAGER.ORM_TAB_A
PRA_RISKMANAGER.ORM_TAB_B
```

As tabelas devem ser informadas no formato `OWNER.TABELA` e seus owners devem pertencer aos schemas permitidos pelo profile.

No backup, a automação valida a existência das tabelas antes do `expdp`.

No restore/sync, o schema não é removido. O `impdp` trabalha somente com as tabelas selecionadas e utiliza `TABLE_EXISTS_ACTION`.

---

## 4. Fluxo da automação

```text
controller
  ├── normaliza survey
  ├── carrega profile
  ├── resolve scope / schemas / tables
  ├── resolve origem/destinos
  └── cria hosts dinâmicos

backup
  ├── descobre ambiente Oracle
  ├── monta Oracle DIRECTORY
  ├── valida tabelas quando scope=tables
  ├── gera parfile SCHEMAS ou TABLES
  ├── expdp
  ├── valida dump/log
  └── disponibiliza dump/latest no CIFS

sync barrier
  └── impede restore se o backup falhar

restore
  ├── descobre ambiente Oracle
  ├── resolve latest ou dump exato
  ├── valida dump
  ├── gera parfile SCHEMAS ou TABLES
  │
  ├── scope=schema
  │   ├── valida senha
  │   ├── captura grants
  │   ├── controla sessões
  │   ├── DROP USER ... CASCADE
  │   ├── impdp
  │   ├── aplica senha / unlock
  │   ├── reaplica grants
  │   └── validações
  │
  └── scope=tables
      ├── aplica TABLE_EXISTS_ACTION
      ├── impdp das tabelas selecionadas
      └── valida resultado do Data Pump

report
  ├── coleta logs
  ├── publica anexos no CIFS
  ├── executa cleanup configurado
  └── gera HTML + set_stats
```

---

## 5. Backup

Exemplo de configuração:

```yaml
backup:
  root_dir: "/backup/oracle_manager"
  storage_mode: "local"
  compression: "none"
  parallel: 1
  exclude:
    - "STATISTICS"
  extra_args: ""
  validate_dump: true
```

O `expdp` é executado com autenticação local `/ as sysdba`.

O parfile utiliza:

```text
SCHEMAS=...
```

ou:

```text
TABLES=...
```

conforme `orm_scope`.

O modelo homologado trabalha com arquivo único `.dmp` e `parallel=1`.

Quando `validate_dump=true`, a automação valida o dump e o log do Data Pump antes de concluir o backup.

---

## 6. Storage do dump

O backup e o restore suportam:

```text
local
cifs
```

### `local`

No backup:

```text
expdp
  ↓
backup.root_dir
  ↓
CIFS
```

No restore:

```text
CIFS
  ↓
restore.root_dir
  ↓
impdp
```

### `cifs`

O CIFS é montado no host Oracle e o Data Pump trabalha diretamente no compartilhamento.

```text
backup:  expdp -> CIFS
restore: CIFS -> impdp
```

Os logs do Data Pump permanecem em diretório local separado.

---

## 7. TABLE_EXISTS_ACTION

`orm_table_exists_action` é utilizado somente em restore/sync com:

```text
orm_scope=tables
```

Valores suportados:

| Valor | Comportamento | Uso |
| --- | --- | --- |
| `truncate` | Executa `TRUNCATE` na tabela existente e carrega os dados do dump, preservando a estrutura atual. | Quando a estrutura do destino deve ser mantida e os dados devem ser substituídos. |
| `replace` | Remove e recria a tabela a partir do dump antes de carregar os dados. | Quando a definição da origem também deve substituir a existente no destino. |
| `skip` | Não importa a tabela quando ela já existe. Se não existir, pode ser criada a partir do dump. | Quando tabelas existentes no destino devem ser preservadas. |

Exemplo:

```bash
-e "orm_scope=tables" \
-e "orm_tables=PRA_RISKMANAGER.ORM_TAB_A,PRA_RISKMANAGER.ORM_TAB_B" \
-e "orm_table_exists_action=truncate"
```

`TABLE_EXISTS_ACTION` não interfere no backup. No `expdp`, apenas as tabelas selecionadas são exportadas.

---

## 8. Restore de Schema

O restore de `schema` executa prechecks antes da fase destrutiva.

```text
ambiente Oracle
  ↓
dump
  ↓
senha
  ↓
grants
  ↓
sessões
  ↓
DROP USER ... CASCADE
  ↓
impdp
  ↓
senha / unlock
  ↓
grants
  ↓
validações
```

A automação mantém flags de estado para distinguir falha antes e depois do DROP.

> **Atenção:** após o início da fase destrutiva não existe rollback automático do schema. Em caso de falha, a recuperação deve utilizar um dump válido e os logs da execução.

---

## 9. Grants

Exemplo de configuração:

```yaml
restore:
  capture_grants: true
  apply_grants: true
  fail_on_grant_error: false
```

No escopo `schema`:

- os grants atuais do destino podem ser capturados antes do `DROP USER`;
- o arquivo é gerado como `grants_before_<profile>_<env>_job_<id>.sql`;
- após o `impdp`, os grants podem ser reaplicados;
- `fail_on_grant_error` define se uma falha de reaplicação é crítica ou apenas aviso.

O arquivo de grants é incluído nos anexos do relatório quando disponível.

---

## 10. Senha do schema

A senha não é armazenada no profile.

O padrão é receber a senha no Survey através de:

```text
orm_password
```

Defaults principais:

```yaml
orm_restore_password_default_var: "orm_password"
orm_restore_password_env_vars: {}
orm_restore_password_min_length: 12
orm_restore_password_require_upper: true
orm_restore_password_require_lower: true
orm_restore_password_require_digit: true
orm_restore_password_allow_multi_schema: false
```

Também é possível mapear uma variável diferente por ambiente:

```yaml
restore:
  password:
    default_var: "orm_password"
    env_vars:
      dev: "orm_password_dev"
      qas: "orm_password_qas"
```

A senha é utilizada no restore/sync de `schema`. As tasks que manipulam o valor utilizam `no_log=true`.

---

## 11. Controle de sessões

No escopo `schema`:

```yaml
restore:
  kill_sessions: true
  lock_users: true
  drop_users: true
  unlock_users: true
```

Com `kill_sessions=false`, sessões abertas bloqueiam o restore antes da fase destrutiva.

Com `kill_sessions=true`, a automação:

```text
lista sessões
  ↓
bloqueia usuário
  ↓
encerra sessões
  ↓
aguarda zero sessões
  ↓
DROP USER ... CASCADE
```

Se houver falha antes do DROP após o lock, a automação tenta desbloquear novamente os usuários.

No escopo `tables`, não existe `DROP USER ... CASCADE`.

---

## 12. Descoberta do ambiente Oracle

Os dados Oracle podem ser configurados no profile/host ou descobertos automaticamente.

| Componente | Origem |
| --- | --- |
| `ORACLE_SID` | PMON (`ora_pmon_*` / `db_pmon_*`). |
| `ORACLE_HOME` | `/etc/oratab` ou `/var/opt/oracle/oratab`. |
| CDB | `v$database`. |
| PDB por service | `v$services` + `v$containers`. |
| PDB por schema | `cdb_users` + `v$containers`. |
| Disponibilidade da PDB | `v$pdbs`. |
| Schema | `dba_users` no container efetivo. |

A detecção CDB é fail-safe: se o retorno não puder ser interpretado com segurança, a automação interrompe o fluxo em vez de assumir um banco non-CDB.

---

## 13. Oracle DIRECTORY

O Oracle Manager utiliza um DIRECTORY para o dump e outro para os logs.

Exemplo:

```text
DB_MANAGER
DB_MANAGER_LOG
```

Conceitualmente:

```sql
CREATE OR REPLACE DIRECTORY DB_MANAGER AS '<caminho_efetivo_do_dump>';
CREATE OR REPLACE DIRECTORY DB_MANAGER_LOG AS '<root_dir_local>';
```

Em `storage_mode=local`, `DB_MANAGER` aponta para o `root_dir` local.

Em `storage_mode=cifs`, `DB_MANAGER` aponta para o caminho CIFS montado.

O DIRECTORY de logs permanece local.

---

## 14. Data Pump

O `expdp` e o `impdp` são executados com autenticação local:

```text
/ as sysdba
```

Quando há PDB, a automação utiliza `ORACLE_PDB_SID` para direcionar a operação ao container correto.

Parfile de schema:

```text
SCHEMAS=...
DIRECTORY=...
DUMPFILE=...
LOGFILE=...
```

Parfile de tabelas:

```text
TABLES=...
DIRECTORY=...
DUMPFILE=...
LOGFILE=...
TABLE_EXISTS_ACTION=...
```

`TABLE_EXISTS_ACTION` aparece somente no `impdp` de `tables`.

O `impdp` utiliza execução assíncrona para suportar restores longos.

---

## 15. Validações

No fluxo de restore completo podem ser habilitadas validações como:

```yaml
restore:
  validate_schemas: true
  validate_invalid_objects: true
  fail_on_invalid_objects: false
```

Também podem ser declaradas queries SQL customizadas:

```yaml
validations:
  enabled: true
  queries:
    - "queries/riskmanager_lab.sql"
```

As queries são executadas após as validações padrão.

Uma query pode somente registrar informações ou utilizar `raise_application_error` para transformar uma condição em falha obrigatória.

---

## 16. Sync

O `sync` sempre produz um dump novo.

```text
origem
  ↓
backup novo
  ↓
validação
  ↓
sync barrier
  ↓
destino 1
destino 2
...
```

A barreira pós-backup impede qualquer restore quando o backup da origem não termina com `SUCESSO`.

O mesmo dump criado no job é utilizado em todos os destinos selecionados.

O escopo também é preservado:

```text
sync + schema -> backup schema + restore schema
sync + tables -> backup tables + restore tables
```

---

## 17. Hosts por ambiente

Exemplo:

```yaml
hosts_env_sync:
  prd:
    - name: "prd-riskmanager-01"
      ansible_host: "192.168.122.252"
      source: true
      enabled: true
      sid: ""
      pdb: ""
      service_name: ""
      oracle_home: ""
      os_user: "oracle"
      os_group: "oinstall"
      directory_name: "DB_MANAGER"
      backup_root_dir: "/backup/oracle_manager"
      restore_root_dir: "/backup/oracle_manager_restore"

  tu:
    - name: "tu-riskmanager-01"
      ansible_host: "192.168.122.67"
      source: true
      enabled: true
      sid: ""
      pdb: ""
      service_name: ""
      oracle_home: ""
      os_user: "oracle"
      os_group: "oinstall"
      directory_name: "DB_MANAGER"
      backup_root_dir: "/backup/oracle_manager"
      restore_root_dir: "/backup/oracle_manager_restore"
```

`sid`, `pdb`, `service_name` e `oracle_home` podem permanecer vazios quando a descoberta automática for adequada e não houver ambiguidade.

Credenciais SSH devem preferencialmente vir das Credentials do AAP.

---

## 18. Configuração efetiva

A automação utiliza níveis diferentes de configuração:

```text
Survey / extra vars
  -> define o que executar

defaults/main.yml
  -> define comportamento técnico padrão

profile Oracle
  -> define como aquele sistema/schema deve ser tratado

host em hosts_env_sync
  -> aplica overrides específicos do host
```

Exemplos de valores definidos no Survey:

```text
orm_action
orm_profile_key
orm_scope
orm_source_env
orm_target_envs
orm_tables
orm_table_exists_action
```

Exemplos de valores técnicos vindos do profile/defaults:

```text
root_dir
storage_mode
parallel
compression
grants
sessions
password policy
cleanup
CIFS
report
```

---

## 19. Estrutura principal

| Arquivo | Descrição |
| --- | --- |
| `oracle_manager.yml` | Playbook principal. Orquestra controller, backup, barreira do sync, restore e report. |
| `config/oracle_manager/databases/*.yml` | Profiles por sistema/schema Oracle. |
| `roles/oracle_manager/defaults/main.yml` | Defaults técnicos e globais da role. |
| `roles/oracle_manager/tasks/controller.yml` | Planejamento. |
| `roles/oracle_manager/tasks/00_normalize_inputs.yml` | Normaliza action, profile, scope, listas e confirmações do Survey. |
| `roles/oracle_manager/tasks/10_load_profile_config.yml` | Carrega e consolida o profile. |
| `roles/oracle_manager/tasks/20_resolve_plan.yml` | Resolve origem, destinos, schemas, tabelas e dump compartilhado. |
| `roles/oracle_manager/tasks/25_create_dynamic_hosts.yml` | Cria `orm_source_targets` e `orm_restore_targets`. |
| `roles/oracle_manager/tasks/35_oracle_environment.yml` | Resolve SID/HOME/CDB/PDB e valida o ambiente Oracle. |
| `roles/oracle_manager/tasks/36_mount_cifs_storage.yml` | Monta o CIFS quando `storage_mode=cifs`. |
| `roles/oracle_manager/tasks/37_unmount_cifs_storage.yml` | Desmonta o CIFS e remove o arquivo temporário de senha. |
| `roles/oracle_manager/tasks/40_create_directory.yml` | Cria/atualiza os Oracle DIRECTORYs da operação. |
| `roles/oracle_manager/tasks/45_build_expdp_parfile.yml` | Gera o parfile do `expdp` com `SCHEMAS` ou `TABLES`. |
| `roles/oracle_manager/tasks/50_validate_dump.yml` | Valida dump/log do backup. |
| `roles/oracle_manager/tasks/55_resolve_restore_dump.yml` | Resolve `latest` ou dump exato. |
| `roles/oracle_manager/tasks/59_validate_restore_credentials.yml` | Resolve e valida a senha runtime do restore de schema. |
| `roles/oracle_manager/tasks/60_capture_grants.yml` | Captura grants antes da fase destrutiva do restore de schema. |
| `roles/oracle_manager/tasks/61_connection_control.yml` | Controla sessões e bloqueio de usuários no restore de schema. |
| `roles/oracle_manager/tasks/62_prepare_schema.yml` | No escopo `schema`, executa a preparação destrutiva e `DROP USER ... CASCADE`. |
| `roles/oracle_manager/tasks/63_build_impdp_parfile.yml` | Gera o parfile do `impdp` com `SCHEMAS` ou `TABLES` e `TABLE_EXISTS_ACTION` quando aplicável. |
| `roles/oracle_manager/tasks/64_execute_impdp.yml` | Executa o `impdp`. |
| `roles/oracle_manager/tasks/65_restore_password.yml` | Aplica senha runtime e desbloqueia usuário no restore de schema. |
| `roles/oracle_manager/tasks/66_apply_grants.yml` | Reaplica grants capturados. |
| `roles/oracle_manager/tasks/67_validate_restore.yml` | Valida o resultado do restore. |
| `roles/oracle_manager/tasks/68_custom_validations.yml` | Executa queries SQL declaradas no profile. |
| `roles/oracle_manager/tasks/80_collect_logs.yml` | Coleta artefatos dos hosts para o controller. |
| `roles/oracle_manager/tasks/85_publish_cifs.yml` | Publica anexos no CIFS do fluxo de e-mail. |
| `roles/oracle_manager/tasks/87_cleanup_restore_artifacts.yml` | Cleanup dos artefatos locais do destino. |
| `roles/oracle_manager/tasks/88_cleanup_cifs_dump.yml` | Cleanup do dump/latest consumidos no CIFS. |
| `roles/oracle_manager/tasks/89_cleanup_local_sync_backup.yml` | Cleanup dos artefatos locais do backup após coleta/publicação. |
| `roles/oracle_manager/tasks/90_build_report.yml` | Monta status geral e dados do relatório. |
| `roles/oracle_manager/tasks/backup.yml` | Orquestra backup de schema ou tabelas. |
| `roles/oracle_manager/tasks/restore.yml` | Orquestra restore conforme `schema` ou `tables`. |
| `roles/oracle_manager/tasks/report.yml` | Orquestra coleta, publicação, cleanup, relatório e `set_stats`. |
| `roles/oracle_manager/templates/expdp.par.j2` | Template do parfile de export. |
| `roles/oracle_manager/templates/impdp.par.j2` | Template do parfile de import. |
| `roles/oracle_manager/templates/grant_capture.sql.j2` | SQL de captura de grants. |
| `roles/oracle_manager/templates/email_report.html.j2` | Relatório HTML operacional. |
| `queries/*.sql` | Queries SQL de validação personalizadas. |

---

## 20. Cleanup

Principais opções:

```yaml
orm_cleanup_restore_artifacts: false
orm_cleanup_cifs_dump_after_restore: false
orm_cleanup_local_backup_after_sync: false
```

- `orm_cleanup_restore_artifacts`: remove artefatos locais do destino após coleta/publicação.
- `orm_cleanup_cifs_dump_after_restore`: remove dump/latest consumidos no CIFS após sucesso dos hosts obrigatórios.
- `orm_cleanup_local_backup_after_sync`: remove artefatos locais do backup após coleta/publicação do relatório.

Os cleanups locais são executados somente depois da coleta/publicação dos anexos.

Falha de cleanup é refletida no relatório sem apagar o resultado operacional já coletado.

---

## 21. Artefatos e relatório

A automação pode gerar:

- dump `.dmp`;
- manifesto `latest`;
- log consolidado de backup;
- log consolidado de restore;
- parfiles do Data Pump;
- arquivo SQL de grants;
- logs técnicos e de validação;
- relatório HTML.

O relatório informa:

```text
status geral
ação
escopo
profile
origem
destinos
motivo
host
SID / PDB
schemas
dump
duração
falhas / avisos
```

Quando `orm_scope=tables`, também mostra:

```text
tabelas selecionadas
TABLE_EXISTS_ACTION
```

O relatório publica via `set_stats`:

```yaml
send_mail_subject: "..."
send_mail_body: "..."
send_mail_attachments:
  - "..."
```

Status possíveis:

```text
SUCESSO
SUCESSO COM AVISO
FALHA
NÃO EXECUTADO
```

---

## 22. Execução via CLI

### Backup de schema

```bash
ansible-playbook oracle_manager.yml \
  -e "orm_action=backup" \
  -e "orm_profile_key=riskmanager" \
  -e "orm_scope=schema" \
  -e "orm_source_env=prd"
```

### Backup de tabelas

```bash
ansible-playbook oracle_manager.yml \
  -e "orm_action=backup" \
  -e "orm_profile_key=riskmanager" \
  -e "orm_scope=tables" \
  -e "orm_source_env=prd" \
  -e "orm_tables=PRA_RISKMANAGER.ORM_TAB_A,PRA_RISKMANAGER.ORM_TAB_B"
```

### Restore de schema

```bash
ansible-playbook oracle_manager.yml \
  -e "orm_action=restore" \
  -e "orm_profile_key=riskmanager" \
  -e "orm_scope=schema" \
  -e "orm_source_env=prd" \
  -e "orm_target_envs=tu" \
  -e "orm_restore_dump_name=latest" \
  -e "orm_confirm_restore=sim" \
  -e "orm_password=<senha>"
```

### Restore de tabelas

```bash
ansible-playbook oracle_manager.yml \
  -e "orm_action=restore" \
  -e "orm_profile_key=riskmanager" \
  -e "orm_scope=tables" \
  -e "orm_source_env=prd" \
  -e "orm_target_envs=tu" \
  -e "orm_restore_dump_name=latest" \
  -e "orm_tables=PRA_RISKMANAGER.ORM_TAB_A,PRA_RISKMANAGER.ORM_TAB_B" \
  -e "orm_table_exists_action=truncate" \
  -e "orm_confirm_restore=sim"
```

### Sync de tabelas

```bash
ansible-playbook oracle_manager.yml \
  -e "orm_action=sync" \
  -e "orm_profile_key=riskmanager" \
  -e "orm_scope=tables" \
  -e "orm_source_env=prd" \
  -e "orm_target_envs=tu,th" \
  -e "orm_tables=PRA_RISKMANAGER.ORM_TAB_A,PRA_RISKMANAGER.ORM_TAB_B" \
  -e "orm_table_exists_action=truncate" \
  -e "orm_confirm_restore=sim"
```
