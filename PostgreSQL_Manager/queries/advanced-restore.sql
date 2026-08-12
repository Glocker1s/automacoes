\echo
\echo ============================================================
\echo VALIDACAO AVANCADA POSTGRESQL MANAGER
\echo ============================================================

\echo
\echo --- CONFIGURACOES PRESERVADAS ---
SELECT config_key, config_value, env_name
FROM app.environment_config
ORDER BY config_key;

\echo
\echo --- FEATURE FLAGS PRESERVADAS ---
SELECT feature_name, enabled, env_name
FROM app.feature_flags
ORDER BY feature_name;

\echo
\echo --- RUNTIME SESSIONS - DEVE SER ZERO ---
SELECT count(*) AS runtime_sessions
FROM app.runtime_sessions;

\echo
\echo --- AUDITORIA DO DISABLE TRIGGERS - DEVE SER ZERO ---
SELECT count(*) AS trigger_events
FROM audit.preserve_trigger_audit;

\echo
\echo --- DADOS SENSIVEIS DEPOIS DO MASKING ---
SELECT customer_id, full_name, email, document, env_name
FROM app.customer_sensitive
ORDER BY customer_id;

\echo
\echo --- AUDITORIA DO MASKING ---
SELECT
  audit_id,
  observed_environment,
  observed_runtime_sessions,
  rows_masked,
  executed_at
FROM audit.masking_audit
ORDER BY audit_id DESC
LIMIT 5;

\echo
\echo --- MATERIALIZED VIEW DEPOIS DO MASKING ---
SELECT customer_id, full_name, email, document, env_name
FROM public.mv_masking_demo
ORDER BY customer_id;

\echo
\echo --- ANALYZE ---
SELECT
  schemaname,
  relname,
  last_analyze
FROM pg_stat_all_tables
WHERE schemaname IN ('app','audit')
  AND relname IN (
    'environment_config',
    'feature_flags',
    'runtime_sessions',
    'customer_sensitive'
  )
ORDER BY schemaname, relname;