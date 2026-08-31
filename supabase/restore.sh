#!/usr/bin/env bash
# Заливает бэкап из backups/*.json обратно в базу Supabase.
#
# Нужен service_role-ключ: он обходит RLS, поэтому его НЕЛЬЗЯ класть в репозиторий
# и нельзя вставлять в приложение. Берётся разово из Project Settings → API.
#
#   SUPABASE_URL=https://xxx.supabase.co SUPABASE_SERVICE_KEY=eyJ... ./supabase/restore.sh
set -euo pipefail

: "${SUPABASE_URL:?нужна переменная SUPABASE_URL}"
: "${SUPABASE_SERVICE_KEY:?нужна переменная SUPABASE_SERVICE_KEY}"

cd "$(dirname "$0")/.."

for table in baristas shifts prefs logs; do
  file="backups/${table}.json"
  [ -f "$file" ] || { echo "нет $file — пропускаю"; continue; }
  count=$(jq 'length' "$file")
  [ "$count" -gt 0 ] || { echo "$table: пусто — пропускаю"; continue; }

  echo "$table: заливаю $count записей"
  curl -sSf "${SUPABASE_URL}/rest/v1/${table}" \
    -X POST \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates" \
    --data-binary "@${file}" > /dev/null
done

echo "Готово."
