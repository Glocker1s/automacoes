set serveroutput on

declare
  v_total number;
begin
  select count(*)
    into v_total
    from PRA_RISKMANAGER.T1;

  if v_total <= 0 then
    raise_application_error(
      -20001,
      'Validacao falhou: PRA_RISKMANAGER.T1 nao possui registros.'
    );
  end if;

  dbms_output.put_line(
    'OK - PRA_RISKMANAGER.T1 possui ' || v_total || ' registro(s).'
  );
end;
/