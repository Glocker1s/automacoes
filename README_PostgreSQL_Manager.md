# PostgreSQL Manager

Automação Ansible para **backup, restore e sincronização controlada de bancos PostgreSQL**, com resolução por banco/ambiente, uso de dumps armazenados em CIFS, restauração em base temporária, promoção segura da base restaurada, preservação de grants do destino, suporte a DBLink/Foreign Server/User Mapping, refresh de Materialized Views, execução opcional de scripts de mascaramento e geração de relatório HTML com anexos operacionais.

A solução foi desenhada para cenários onde é necessário:

- gerar backup de bancos PostgreSQL por ambiente;
- restaurar backups existentes em ambientes de homologação/teste;
- executar sync com backup novo da origem e restore nos destinos;
- preservar permissões específicas do ambiente destino;
- reconfigurar integrações DBLink/FDW após o restore;
- atualizar materialized views no destino;
- executar scripts de mascaramento após o restore;
- anexar logs técnicos ao e-mail operacional.

---

## 1. Workflow operacional

Exemplo de workflow:

```text
WF_PostgreSQL_Manager
  ├── MCA_PostgreSQL_Manager
  └── Test_Send_Email
```

O template `MCA_PostgreSQL_Manager` executa o playbook:

```text
postgres_manager.yml
```

A role principal é:

```text
roles/postgres_manager
```

O job de e-mail consome as variáveis publicadas pela automação principal:

```yaml
send_mail_subject: "Assunto do e-mail"
send_mail_body: "HTML do relatório"
send_mail_attachments:
  - "arquivos publicados no CIFS"
```

---

## 2. Ações disponíveis

A automação trabalha com três ações principais.

| Ação | Descrição |
| --- | --- |
| `backup` | Gera um novo dump da origem selecionada e publica no CIFS. |
| `restore` | Restaura um dump existente, como `latest` ou um dump específico, nos destinos informados. |
| `sync` | Executa backup novo da origem e restaura esse backup nos destinos no mesmo workflow. |

Resumo:

```text
backup
  gera dump novo

restore
  usa dump já existente

sync
  gera dump novo + restaura nos destinos
```

Quando o objetivo for restaurar um backup já existente, usar `restore`.

Quando o objetivo for gerar um backup novo e restaurar imediatamente, usar `sync`.

---

## 3. Survey do AAP

O survey operacional possui somente os campos abaixo.

| Campo no Survey | Variável | Tipo sugerido | Exemplo | Descrição |
| --- | --- | --- | --- | --- |
| Qual a ação? | `pgm_action` | Multiple Choice | `backup`, `restore`, `sync` | Define o comportamento principal da automação. |
| Qual o banco? | `pgm_database_key` | Multiple Choice | `dbcvm_lab`, `dbcvm`, `valemobi` | Seleciona o profile do banco em `config/postgres_manager/databases`. |
| Qual o ambiente de origem? | `pgm_source_env` | Multiple Choice | `prd`, `tu`, `th`, `fix` | Define o ambiente usado como origem do backup ou do `latest`. |
| Qual o ambiente de destino? | `pgm_target_envs` | Multi Select | `tu`, `th`, `fix` | Define um ou mais ambientes destino para restore/sync. |
| Host de destino específico | `pgm_target_hosts` | Text | `tu-dbcvm-01` | Filtro opcional para executar restore em host específico dentro do destino. |
| Qual o dump para restore? | `pgm_restore_dump_name` | Text | `latest` | Nome do dump que será restaurado. Use `latest` para pegar o último backup do ambiente origem. |
| Confirmar restore ou sync? | `pgm_confirm_restore` | Multiple Choice | `sim` ou `nao` | Confirmação obrigatória para ações destrutivas como restore/sync. |
| Motivo | `pgm_execution_reason` | Text | `Refresh TU com dados PRD` | Justificativa exibida no relatório. |

Exemplo de survey para backup:

```yaml
pgm_action: backup
pgm_database_key: dbcvm_lab
pgm_source_env: prd
pgm_target_envs: []
pgm_target_hosts: ""
pgm_restore_dump_name: latest
pgm_confirm_restore: nao
pgm_execution_reason: "Backup PRD para disponibilizar restore"
```

Exemplo de survey para restore usando latest:

```yaml
pgm_action: restore
pgm_database_key: dbcvm_lab
pgm_source_env: prd
pgm_target_envs:
  - tu
pgm_target_hosts: ""
pgm_restore_dump_name: latest
pgm_confirm_restore: sim
pgm_execution_reason: "Restore do último backup PRD em TU"
```

Exemplo de survey para sync:

```yaml
pgm_action: sync
pgm_database_key: dbcvm_lab
pgm_source_env: prd
pgm_target_envs:
  - tu
  - th
pgm_target_hosts: ""
pgm_restore_dump_name: latest
pgm_confirm_restore: sim
pgm_execution_reason: "Sync PRD para TU e TH"
```

---

## 4. Comportamento do `latest`

O `latest` é controlado por banco e ambiente de origem.

Exemplo:

```text
latest_dbcvm_prd.txt
latest_dbcvm_tu.txt
latest_dbcvm_th.txt
latest_dbcvm_fix.txt
```

Se for feito backup de `th`, o manifesto atualizado será o `latest` de `th`.

Se logo depois for feito backup de `prd`, o manifesto atualizado será o `latest` de `prd`.

Portanto:

```text
backup TH
  atualiza latest_dbcvm_th.txt

backup PRD
  atualiza latest_dbcvm_prd.txt
```

Um restore com:

```yaml
pgm_source_env: th
pgm_restore_dump_name: latest
```

usa o último backup de `th`.

Um restore com:

```yaml
pgm_source_env: prd
pgm_restore_dump_name: latest
```

usa o último backup de `prd`.

---

## 5. Fluxo lógico da automação

```text
postgres_manager.yml
  |
  |-- Play controller no localhost
  |     |-- 00_normalize_inputs.yml
  |     |-- 10_load_database_config.yml
  |     |-- 20_resolve_plan.yml
  |     |-- 25_create_dynamic_hosts.yml
  |
  |-- Play backup em pgm_source_targets
  |     |-- backup.yml
  |
  |-- Play barreira pós-backup no sync
  |     |-- valida se o backup do sync terminou com sucesso
  |     |-- bloqueia restore se o backup falhar
  |
  |-- Play restore em pgm_restore_targets
  |     |-- restore.yml
  |
  |-- Play report no localhost
        |-- report.yml
        |-- 80_collect_logs.yml
        |-- 85_publish_cifs.yml
        |-- 90_build_report.yml
        |-- email_report.html.j2
        |-- set_stats send_mail_subject/send_mail_body/send_mail_attachments
```

---

## 6. Fluxo de backup

O backup executa o `pg_dump` no host origem e publica o dump no CIFS.

Fluxo resumido:

```text
1. resolve ambiente e host origem
2. cria diretório local de backup
3. executa pg_dump
4. valida o dump com pg_restore -l
5. gera log técnico do backup
6. envia dump e manifesto latest para CIFS
7. registra artefatos para relatório
```

Configuração principal:

```yaml
backup:
  root_dir: "/backup/postgres_manager"
  jobs: 4
  format: "directory"
  extra_args: ""
  validate_dump: true
```

Campos:

| Campo | Descrição |
| --- | --- |
| `root_dir` | Diretório local no host origem onde o dump será criado antes do envio ao CIFS. |
| `jobs` | Quantidade de jobs paralelos do `pg_dump`. |
| `format` | Formato do dump. O formato validado é `directory`. |
| `extra_args` | Argumentos extras opcionais para o `pg_dump`. |
| `validate_dump` | Quando `true`, valida o dump com `pg_restore -l`. |

---

## 7. Fluxo de restore

O modo suportado atualmente é:

```yaml
restore:
  mode: "promote"
```

O modo `promote` restaura primeiro em uma base temporária e só promove no final.

Exemplo para o banco `dbcvm`:

```text
1. cria dbcvm_restoring
2. restaura o dump dentro de dbcvm_restoring
3. reaplica grants capturados do destino
4. executa masking, se habilitado
5. configura dblink/foreign server/user mapping, se habilitado
6. executa refresh das materialized views, se habilitado
7. executa VACUUM ANALYZE, se habilitado
8. bloqueia usuários configurados
9. renomeia:
     dbcvm -> dbcvm_old
     dbcvm_restoring -> dbcvm
10. desbloqueia usuários configurados
11. executa queries de validação
12. registra log e status final
```

Configuração principal:

```yaml
restore:
  mode: "promote"
  target_temp_suffix: "_restoring"
  old_suffix: "_old"
  no_owner: true
  no_privileges: true
  jobs: 4
  extra_args: ""
  vacuum_analyze: true
  exclude_toc_patterns:
    - "USER MAPPING"
    - "MATERIALIZED VIEW DATA public mv_search_companys"
    - "MATERIALIZED VIEW DATA public mv_company_balance_guide"
```

Campos:

| Campo | Descrição |
| --- | --- |
| `mode` | Modo de restore. Atualmente o modo homologado é `promote`. |
| `target_temp_suffix` | Sufixo da base temporária usada no restore. |
| `old_suffix` | Sufixo usado na base antiga após o promote. |
| `no_owner` | Usa `--no-owner` no `pg_restore`. |
| `no_privileges` | Usa `--no-privileges` no `pg_restore`. |
| `jobs` | Quantidade de jobs paralelos do `pg_restore`. |
| `extra_args` | Argumentos extras opcionais para o `pg_restore`. |
| `vacuum_analyze` | Executa `VACUUM ANALYZE` após o restore. |
| `exclude_toc_patterns` | Remove entradas específicas do TOC antes do restore. |

---

## 8. TOC Patterns

A automação pode remover itens do TOC antes do `pg_restore`.

Isso é usado principalmente para evitar restaurar objetos ou dados que devem ser recriados no destino.

Exemplo:

```yaml
exclude_toc_patterns:
  - "USER MAPPING"
  - "MATERIALIZED VIEW DATA public mv_search_companys"
  - "MATERIALIZED VIEW DATA public mv_company_balance_guide"
```

Uso comum:

| Pattern | Objetivo |
| --- | --- |
| `USER MAPPING` | Evita restaurar user mapping da origem. A automação recria o user mapping correto para o destino. |
| `MATERIALIZED VIEW DATA ...` | Evita restaurar dados antigos de MV. A automação executa `REFRESH MATERIALIZED VIEW` no destino. |

---

## 9. Grants

O restore pode capturar grants do banco destino antes da restauração e reaplicá-los na base restaurada.

Configuração:

```yaml
grants:
  capture_before_restore: true
  apply_after_restore: true
  fail_on_apply_error: false
```

Campos:

| Campo | Descrição |
| --- | --- |
| `capture_before_restore` | Captura grants do banco destino antes do restore. |
| `apply_after_restore` | Reaplica os grants capturados na base restaurada. |
| `fail_on_apply_error` | Quando `true`, falha o restore se algum grant falhar. Quando `false`, registra aviso e segue. |

Esse comportamento é importante porque o dump pode vir de produção, mas os acessos de homologação podem ser diferentes.

---

## 10. Masking / Scramble de dados

O mascaramento é opcional por banco.

Ele é executado após o `pg_restore` e reaplicação de grants, mas antes de materialized views, vacuum e promote.

Fluxo:

```text
1. copia o script SQL para o host destino
2. executa o script para criar/atualizar a função de mascaramento
3. executa SELECT public.funcao_scramble()
4. registra o resultado no log TXT do restore
5. remove os scripts temporários do host, quando cleanup estiver habilitado
```

Configuração:

```yaml
masking:
  enabled: true
  fail_on_error: true
  run_on_envs:
    - "tu"
    - "ti"
    - "th"
    - "fix"
    - "hml"
  protected_envs:
    - "prd"
    - "prod"
    - "producao"
  scripts:
    - name: "dbcvm_lab_scramble"
      file: "masking/fc_dbcvm_lab_scramble_database.sql"
      function: "public.fc_dbcvm_lab_scramble_database"
      execute_function: true
```

Campos:

| Campo | Descrição |
| --- | --- |
| `enabled` | Habilita ou desabilita mascaramento para o banco. |
| `fail_on_error` | Quando `true`, falha o restore e impede promote se o masking falhar. |
| `run_on_envs` | Lista de ambientes onde o masking pode rodar. Se vazio, roda em qualquer ambiente não protegido. |
| `protected_envs` | Lista de ambientes onde o masking nunca deve rodar. |
| `scripts` | Lista de scripts SQL e funções que serão executados. |
| `file` | Caminho do script dentro de `roles/postgres_manager/files`. |
| `function` | Função criada pelo script e executada pela automação. |
| `execute_function` | Quando `true`, executa `SELECT function();` depois de aplicar o script. |

Recomendação:

```yaml
fail_on_error: true
```

Assim, se o mascaramento falhar, a base restaurada não é promovida.

---

## 11. DBLink, Foreign Server e User Mapping

A configuração de `dblink` permite recriar no destino o `FOREIGN SERVER` e o `USER MAPPING` corretos.

Configuração:

```yaml
dblink:
  enabled: true
  server_name: "remote_valemobi"
  dbname_var: "dblink_dbname"
  host_var: "dblink_host"
  port_var: "dblink_port"
  user_var: "dblink_user"
  password_var: "dblink_password"
  connect_before_refresh: true
  connection_name: "myconn"
```

Campos:

| Campo | Descrição |
| --- | --- |
| `enabled` | Habilita a configuração de foreign server/user mapping. |
| `server_name` | Nome do foreign server no PostgreSQL. |
| `dbname_var` | Nome da variável/credential com o database remoto. |
| `host_var` | Nome da variável/credential com o host remoto. |
| `port_var` | Nome da variável/credential com a porta remota. |
| `user_var` | Nome da variável/credential com o usuário remoto. |
| `password_var` | Nome da variável/credential com a senha remota. |
| `connect_before_refresh` | Quando `true`, abre conexão dblink temporária antes do refresh das MVs. |
| `connection_name` | Nome da conexão temporária, como `myconn`. |

Resumo:

```text
dblink.enabled=true
  configura foreign server + user mapping

connect_before_refresh=true
  além disso, abre myconn antes do refresh das materialized views
```

---

## 12. Materialized Views

O refresh de materialized views é opcional por banco.

Configuração:

```yaml
materialized_views:
  refresh_enabled: true
  refresh_all: false
  items:
    - schema: "public"
      name: "mv_search_companys"
      concurrently: false
    - schema: "public"
      name: "mv_company_balance_guide"
      concurrently: false
```

Campos:

| Campo | Descrição |
| --- | --- |
| `refresh_enabled` | Habilita ou desabilita refresh de MVs. |
| `refresh_all` | Quando `true`, tenta atualizar todas as MVs encontradas em `pg_matviews`. |
| `items` | Lista explícita de MVs para refresh. |
| `schema` | Schema da MV. |
| `name` | Nome da MV. |
| `concurrently` | Usa `REFRESH MATERIALIZED VIEW CONCURRENTLY`, quando suportado. |

Quando alguma MV usa `dblink('myconn', ...)`, habilitar:

```yaml
connect_before_refresh: true
connection_name: "myconn"
```

Quando a MV usa FDW/foreign table, normalmente basta o foreign server e user mapping.

---

## 13. Usuários bloqueados durante promote

A automação pode bloquear usuários antes do promote e desbloquear depois.

Configuração:

```yaml
users:
  lock_before_promote:
    - "svc_dbcvm"
  unlock_after_promote:
    - "svc_dbcvm"
```

Objetivo:

```text
evitar conexões da aplicação durante a troca:
  dbcvm -> dbcvm_old
  dbcvm_restoring -> dbcvm
```

---

## 14. Validações pós-restore

As queries de validação executam depois do promote.

Configuração:

```yaml
validations:
  enabled: true
  queries:
    - "queries/total.sql"
    - "queries/total-by-table.sql"
```

O resultado das queries é gravado no log TXT do restore, que é publicado como anexo no e-mail.

Exemplo de anexo:

```text
pg_restore_dbcvm_tu_tu-dbcvm-01_job_7502.log
```

---

## 15. Hosts por ambiente

Os hosts ficam no profile do banco em `hosts_env_sync`.

Exemplo:

```yaml
hosts_env_sync:
  prd:
    - name: "prd-dbcvm-01"
      ansible_host: "192.168.122.165"
      ansible_port: 22
      database_name: "dbcvm"
      port: 5432
      db_host: "127.0.0.1"
      os_user: "postgres"
      db_user: "postgres"
      db_password: ""
      source: true
      enabled: true

  tu:
    - name: "tu-dbcvm-01"
      ansible_host: "192.168.122.34"
      ansible_port: 22
      database_name: "dbcvm"
      port: 5432
      db_host: "127.0.0.1"
      os_user: "postgres"
      db_user: "postgres"
      db_password: ""
      source: true
      enabled: true
```

Campos:

| Campo | Descrição |
| --- | --- |
| `name` | Nome lógico do host criado no inventário dinâmico. |
| `ansible_host` | IP ou DNS usado pelo Ansible para conectar no host. |
| `ansible_port` | Porta SSH, normalmente `22`. |
| `database_name` | Nome da base PostgreSQL neste host. |
| `port` | Porta PostgreSQL. |
| `db_host` | Host usado pelo `psql`, `pg_dump` e `pg_restore` a partir do servidor. Normalmente `127.0.0.1`. |
| `os_user` | Usuário Linux usado com `become`, normalmente `postgres`. |
| `db_user` | Usuário PostgreSQL usado no `psql`, `pg_dump` e `pg_restore`. |
| `db_password` | Senha PostgreSQL. Recomendado usar credential do AAP em vez de arquivo. |
| `source` | Define se o host pode ser origem de backup/sync. |
| `enabled` | Habilita ou desabilita o host no planejamento. |

---

## 16. Estrutura de arquivos

| Arquivo | Descrição |
| --- | --- |
| `postgres_manager.yml` | Playbook principal. Orquestra controller, backup, restore e report. |
| `config/postgres_manager/databases/*.yml` | Profiles dos bancos. Define backup, restore, masking, dblink, MVs, validações e hosts por ambiente. |
| `queries/*.sql` | Queries de validação pós-restore. |
| `roles/postgres_manager/defaults/main.yml` | Variáveis padrão da role. |
| `roles/postgres_manager/tasks/main.yml` | Roteador da role por fase. |
| `roles/postgres_manager/tasks/controller.yml` | Fase de planejamento. |
| `roles/postgres_manager/tasks/00_normalize_inputs.yml` | Normaliza entradas do survey. |
| `roles/postgres_manager/tasks/10_load_database_config.yml` | Carrega o profile do banco. |
| `roles/postgres_manager/tasks/20_resolve_plan.yml` | Resolve origem, destinos e hosts. |
| `roles/postgres_manager/tasks/25_create_dynamic_hosts.yml` | Cria inventário dinâmico para backup e restore. |
| `roles/postgres_manager/tasks/backup.yml` | Executa backup e publica dump no CIFS. |
| `roles/postgres_manager/tasks/restore.yml` | Executa restore, grants, masking, dblink, MVs, vacuum, promote e validações. |
| `roles/postgres_manager/tasks/report.yml` | Consolida resultado geral. |
| `roles/postgres_manager/tasks/80_collect_logs.yml` | Coleta logs dos hosts para o controller. |
| `roles/postgres_manager/tasks/85_publish_cifs.yml` | Publica anexos no CIFS. |
| `roles/postgres_manager/tasks/90_build_report.yml` | Monta HTML e variáveis para envio de e-mail. |
| `roles/postgres_manager/templates/email_report.html.j2` | Template HTML do relatório operacional. |
| `roles/postgres_manager/templates/grant_capture.sql.j2` | Template SQL para captura de grants. |
| `roles/postgres_manager/files/masking/*.sql` | Scripts SQL de mascaramento. |

---

## 17. Exemplo de profile completo

Exemplo simplificado em:

```text
config/postgres_manager/databases/dbcvm_lab.yml
```

```yaml
---
cm:
  postgres_manager:
    databases:
      dbcvm_lab:
        description: "Lab DBCVM PostgreSQL Manager"
        database_name: "dbcvm"

        default_source_env: "prd"
        default_sync_targets:
          - "tu"
          - "th"
          - "fix"
        default_restore_targets: []

        backup:
          root_dir: "/backup/postgres_manager"
          jobs: 4
          format: "directory"
          extra_args: ""
          validate_dump: true

        restore:
          mode: "promote"
          target_temp_suffix: "_restoring"
          old_suffix: "_old"
          no_owner: true
          no_privileges: true
          jobs: 4
          extra_args: ""
          vacuum_analyze: true
          exclude_toc_patterns:
            - "USER MAPPING"
            - "MATERIALIZED VIEW DATA public mv_search_companys"
            - "MATERIALIZED VIEW DATA public mv_company_balance_guide"

        grants:
          capture_before_restore: true
          apply_after_restore: true
          fail_on_apply_error: false

        masking:
          enabled: true
          fail_on_error: true
          run_on_envs:
            - "tu"
            - "th"
            - "fix"
          protected_envs:
            - "prd"
            - "prod"
            - "producao"
          scripts:
            - name: "dbcvm_lab_scramble"
              file: "masking/fc_dbcvm_lab_scramble_database.sql"
              function: "public.fc_dbcvm_lab_scramble_database"
              execute_function: true

        dblink:
          enabled: true
          server_name: "remote_valemobi"
          dbname_var: "dblink_dbname"
          host_var: "dblink_host"
          port_var: "dblink_port"
          user_var: "dblink_user"
          password_var: "dblink_password"
          connect_before_refresh: true
          connection_name: "myconn"

        materialized_views:
          refresh_enabled: true
          refresh_all: false
          items:
            - schema: "public"
              name: "mv_search_companys"
              concurrently: false
            - schema: "public"
              name: "mv_company_balance_guide"
              concurrently: false

        users:
          lock_before_promote:
            - "svc_dbcvm"
          unlock_after_promote:
            - "svc_dbcvm"

        validations:
          enabled: true
          queries:
            - "queries/total.sql"
            - "queries/total-by-table.sql"

        hosts_env_sync:
          prd:
            - name: "prd-dbcvm-01"
              ansible_host: "192.168.122.165"
              ansible_port: 22
              database_name: "dbcvm"
              port: 5432
              db_host: "127.0.0.1"
              os_user: "postgres"
              db_user: "postgres"
              db_password: ""
              source: true
              enabled: true

          tu:
            - name: "tu-dbcvm-01"
              ansible_host: "192.168.122.34"
              ansible_port: 22
              database_name: "dbcvm"
              port: 5432
              db_host: "127.0.0.1"
              os_user: "postgres"
              db_user: "postgres"
              db_password: ""
              source: true
              enabled: true
```

---

## 18. Artefatos gerados

A automação pode gerar e publicar os seguintes artefatos:

| Artefato | Descrição |
| --- | --- |
| Dump directory | Diretório do dump gerado pelo `pg_dump`. |
| Manifesto `latest` | Arquivo que aponta para o último backup por banco/ambiente. |
| Log de backup | TXT com detalhes do backup, validação e upload. |
| Log de restore | TXT com detalhes do restore, grants, masking, dblink, MVs, vacuum, promote e validações. |
| Grants capturados | Arquivo SQL com grants do destino antes do restore. |
| Relatório HTML | Corpo do e-mail operacional. |

---

## 19. Comportamento do e-mail

O relatório HTML apresenta:

- status geral da execução;
- ação executada;
- banco;
- ambiente de origem;
- ambientes de destino;
- resumo por host;
- detalhes de falha, quando existir;
- lista de anexos publicados no CIFS.

Os anexos normalmente incluem:

```text
pg_backup_<banco>_<ambiente>_<host>_job_<id>.log
pg_restore_<banco>_<ambiente>_<host>_job_<id>.log
grants_before_<banco>_<ambiente>_job_<id>.sql
```

---

## 20. Segurança operacional

Pontos importantes:

- `restore` e `sync` exigem confirmação explícita em `pgm_confirm_restore`.
- `sync` só executa restore se o backup novo terminar com sucesso.
- `restore.mode` suportado atualmente é somente `promote`.
- O promote preserva a base anterior como `<database_name>_old`.
- O masking deve usar `fail_on_error: true` para evitar promover dados sem mascaramento.
- Ambientes produtivos devem estar em `masking.protected_envs`.
- Senhas não devem ser mantidas no YAML em produção; usar credentials do AAP.
- Se o restore falhar antes do promote, a base ativa antiga permanece preservada.

---

## 21. Execução via CLI

Backup:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=backup" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_execution_reason=Backup PRD"
```

Restore usando `latest`:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=restore" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_target_envs=tu" \
  -e "pgm_restore_dump_name=latest" \
  -e "pgm_confirm_restore=sim" \
  -e "pgm_execution_reason=Restore PRD para TU"
```

Sync:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=sync" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_target_envs=tu,th" \
  -e "pgm_restore_dump_name=latest" \
  -e "pgm_confirm_restore=sim" \
  -e "pgm_execution_reason=Sync PRD para TU e TH"
```

Restore usando dump específico:

```bash
ansible-playbook postgres_manager.yml \
  -e "pgm_action=restore" \
  -e "pgm_database_key=dbcvm_lab" \
  -e "pgm_source_env=prd" \
  -e "pgm_target_envs=tu" \
  -e "pgm_restore_dump_name=dbcvm_prd_20260625_180000_job_7500.dump.dir" \
  -e "pgm_confirm_restore=sim" \
  -e "pgm_execution_reason=Restore dump específico"
```

---

## 22. Testes recomendados

| Teste | Resultado esperado |
| --- | --- |
| Backup PRD | Dump criado, validado e publicado no CIFS. |
| Restore PRD -> TU com `latest` | Base `dbcvm` restaurada, `dbcvm_old` preservada e validações executadas. |
| Sync PRD -> FIX | Backup novo criado e restaurado em FIX. |
| Restore sem confirmação | Automação bloqueia o restore. |
| Base/profile inexistente | Automação falha no planejamento. |
| Sync com falha no backup | Restore é bloqueado pela barreira pós-backup. |
| Masking habilitado | Script executa antes do promote. |
| Masking com erro e `fail_on_error=true` | Restore falha e não promove a base. |
| Dblink com `connect_before_refresh=true` | Conexão `myconn` é aberta antes do refresh das MVs. |
| Restore usando dump específico | Automação ignora `latest` e usa o dump informado. |
