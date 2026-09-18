whenever sqlerror exit sql.sqlcode rollback

set echo on
set feedback on
set verify on
set serveroutput on

declare
  v_schema varchar2(128) := upper('&1');
  v_count  number := 0;
begin
  select count(*)
    into v_count
    from dba_tables
   where owner = v_schema
     and table_name = 'ORM_MASKING_LAB_TEST';

  if v_count = 0 then
    execute immediate
      'create table "' || v_schema || '"."ORM_MASKING_LAB_TEST" (' ||
      'id number primary key, ' ||
      'nm_dado varchar2(100), ' ||
      'dt_atualizacao timestamp' ||
      ')';
  end if;

  execute immediate
    'delete from "' || v_schema || '"."ORM_MASKING_LAB_TEST" where id = 1';

  execute immediate
    'insert into "' || v_schema || '"."ORM_MASKING_LAB_TEST" ' ||
    '(id, nm_dado, dt_atualizacao) values (1, ''DADO_ORIGINAL'', systimestamp)';

  execute immediate
    'update "' || v_schema || '"."ORM_MASKING_LAB_TEST" ' ||
    'set nm_dado = ''DADO_MASCARADO'', dt_atualizacao = systimestamp ' ||
    'where id = 1';

  commit;

  dbms_output.put_line(
    'Masking LAB concluido no schema ' || v_schema ||
    ' - ORM_MASKING_LAB_TEST.ID=1 -> DADO_MASCARADO'
  );
end;
/

exit
