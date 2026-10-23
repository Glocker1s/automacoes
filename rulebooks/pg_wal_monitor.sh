#!/usr/bin/env bash
# PostgreSQL WAL Archive Monitor - execução periódica via cron
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/pg-archive2/valemobi/archive_log/archive_error.log}"
EDA_WEBHOOK_URL="${EDA_WEBHOOK_URL:?Configure EDA_WEBHOOK_URL com a URL do webhook}"
STATE_FILE="${STATE_FILE:-${HOME}/.pg_wal_monitor.state}"

[[ -r "$LOG_FILE" ]] || { echo "Log não encontrado ou sem leitura: $LOG_FILE" >&2; exit 1; }

exec 9>"${STATE_FILE}.lock"
flock -n 9 || exit 0

inode=$(stat -c '%i' -- "$LOG_FILE")
lines=$(wc -l < "$LOG_FILE")

if [[ ! -f "$STATE_FILE" ]]; then
  printf '%s %s\n' "$inode" "$lines" > "$STATE_FILE"
  exit 0
fi

read -r previous_inode previous_lines < "$STATE_FILE"
if [[ ! "$previous_lines" =~ ^[0-9]+$ ]]; then
  echo "Arquivo de estado inválido: $STATE_FILE" >&2
  exit 1
fi

if [[ "$inode" != "$previous_inode" ]] || (( lines < previous_lines )); then
  previous_lines=0
fi

(( lines > previous_lines )) || exit 0

summary=$(awk -v start="$previous_lines" -v finish="$lines" '
  NR > start && NR <= finish && /ERRO ao arquivar/ {
    count++
    wal=$NF
    if (wal ~ /^[0-9A-F]+$/ && length(wal) == 24 && shown < 10) {
      samples = samples (shown ? ", " : "") wal
      shown++
    }
  }
  END { printf "%d|%s", count, samples }
' "$LOG_FILE")
IFS='|' read -r error_count wal_sample <<< "$summary"

if (( error_count == 0 )); then
  printf '%s %s\n' "$inode" "$lines" > "$STATE_FILE"
  exit 0
fi

host_name=$(hostname -s | tr -cd '[:alnum:]._-' )
timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
printf -v payload '{"type":"postgres_wal_archive","status":"failed","hostname":"%s","timestamp":"%s","error_count":%d,"wal_sample":"%s"}' \
  "$host_name" "$timestamp" "$error_count" "$wal_sample"

curl -fsS --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 \
  -H 'Content-Type: application/json' \
  --data-binary "$payload" "$EDA_WEBHOOK_URL" > /dev/null

printf '%s %s\n' "$inode" "$lines" > "$STATE_FILE"
echo "Enviado ao EDA: host=$host_name erros=$error_count"
