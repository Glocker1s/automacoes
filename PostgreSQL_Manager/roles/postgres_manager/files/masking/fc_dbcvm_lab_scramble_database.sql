CREATE OR REPLACE FUNCTION public.fc_dbcvm_lab_scramble_database()
RETURNS void
LANGUAGE plpgsql
AS $body$
DECLARE
  v_environment text;
  v_runtime_sessions bigint;
  v_rows_masked bigint;
BEGIN
  SELECT config_value
    INTO v_environment
    FROM app.environment_config
   WHERE config_key = 'environment_name';

  SELECT count(*)
    INTO v_runtime_sessions
    FROM app.runtime_sessions;

  UPDATE app.customer_sensitive
     SET full_name = 'CLIENTE_MASCARADO_' || customer_id::text,
         email = 'masked_' || customer_id::text || '@example.invalid',
         document = '***MASKED***',
         updated_at = now();

  GET DIAGNOSTICS v_rows_masked = ROW_COUNT;

  INSERT INTO audit.masking_audit(
    observed_environment,
    observed_runtime_sessions,
    rows_masked
  )
  VALUES (
    v_environment,
    v_runtime_sessions,
    v_rows_masked
  );
END;
$body$;