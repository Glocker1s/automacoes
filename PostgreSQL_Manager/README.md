# PostgreSQL Manager

Automação Ansible/AAP para **backup**, **restore** e **sync** de bases PostgreSQL.

## Ideia principal

- `defaults/main.yml`: comportamento operacional da role, CIFS, paths, timeouts, defaults PostgreSQL e relatório.
- `config/postgres_manager/databases/<banco>.yml`: tudo que é específico do banco: hosts por ambiente, regras de restore, grants, materialized views, dblink e validações.
- Inventário dinâmico: a automação cria os hosts automaticamente com `add_host`, sem depender do inventário do AAP apontar para o banco.

## Ações

```yaml
pgm_action: backup   # backup | restore | sync
pgm_database_key: dbcvm
```

### Backup

```yaml
pgm_action: backup
pgm_database_key: dbcvm
pgm_source_env: prd
```

### Restore em um ambiente

```yaml
pgm_action: restore
pgm_database_key: dbcvm
pgm_target_envs: ti
pgm_confirm_restore: sim
```

### Sync PRD para destinos padrão do banco

```yaml
pgm_action: sync
pgm_database_key: dbcvm
pgm_source_env: prd
pgm_confirm_restore: sim
```

### Sync somente para um host do TH

```yaml
pgm_action: sync
pgm_database_key: dbcvm
pgm_source_env: prd
pgm_target_envs: th
pgm_target_hosts: th-dbcvm-02
pgm_confirm_restore: sim
```

## Restore seguro

Por padrão o restore usa:

- `pg_restore -x -O`, para não trazer ACLs/owners da origem.
- Captura grants atuais do destino antes do restore.
- Reaplica grants do destino após o restore.
- Modo `promote`: restaura em `<db>_restoring` e depois renomeia.

## Sync

O sync executa:

1. Backup no host de origem.
2. Publicação do dump no CIFS (`pgm_cifs_dump_path`).
3. Restore nos destinos resolvidos.
4. Publicação dos logs/anexos no CIFS (`pgm_cifs_attachment_path`).
5. Relatório consolidado com logs anexados.

## Observação

Os IPs dos arquivos de exemplo são placeholders. Ajuste `config/postgres_manager/databases/*.yml` antes de usar em cliente.
