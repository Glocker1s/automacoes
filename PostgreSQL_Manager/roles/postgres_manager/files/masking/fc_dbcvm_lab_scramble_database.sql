CREATE OR REPLACE FUNCTION public.fc_dbcvm_lab_scramble_fail()
RETURNS void
LANGUAGE plpgsql
AS $body$
BEGIN
  UPDATE tabela_que_nao_existe
     SET campo = 'teste';
END;
$body$;