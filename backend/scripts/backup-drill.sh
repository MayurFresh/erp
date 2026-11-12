#!/usr/bin/env bash
# Backup and restore drill: dump a database, restore it into a scratch database, compare row counts per table,
# drop the scratch database. Exit code 1 on any mismatch.
#
#   scripts/backup-drill.sh [source_db]
#
# Reads DATABASE_ADMIN_URL (and DATABASE_URL for the default source name) from the environment or backend/.env.
# Needs pg_dump, pg_restore and psql on PATH. Nothing is printed from the URLs except database names.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$here/.env" ]; then
  # Only the two variables this script needs; the rest of .env is not exported.
  : "${DATABASE_ADMIN_URL:=$(grep -E '^DATABASE_ADMIN_URL=' "$here/.env" | head -1 | cut -d= -f2-)}"
  : "${DATABASE_URL:=$(grep -E '^DATABASE_URL=' "$here/.env" | head -1 | cut -d= -f2-)}"
fi
: "${DATABASE_ADMIN_URL:?Set DATABASE_ADMIN_URL (an owner/superuser URL)}"

with_db() { # url dbname -> url pointing at dbname, query string kept
  local base="${1%%\?*}" query=""; [[ "$1" == *\?* ]] && query="?${1#*\?}"
  echo "${base%/*}/$2$query"
}
src="${1:-}"
if [ -z "$src" ]; then
  [ -n "${DATABASE_URL:-}" ] || { echo "Pass the source database name or set DATABASE_URL" >&2; exit 2; }
  src="$(basename "${DATABASE_URL%%\?*}")"
fi
scratch="${src}_drill_$(date +%Y%m%d%H%M%S)"
work="$(mktemp -d)"
trap 'psql "$(with_db "$DATABASE_ADMIN_URL" postgres)" -qAt -c "drop database if exists \"'"$scratch"'\"" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

src_url="$(with_db "$DATABASE_ADMIN_URL" "$src")"
admin_url="$(with_db "$DATABASE_ADMIN_URL" postgres)"
scratch_url="$(with_db "$DATABASE_ADMIN_URL" "$scratch")"

echo "1. Backup of $src"
t0=$(date +%s)
pg_dump --format=custom --no-owner --file="$work/backup.dump" "$src_url"
t1=$(date +%s)
echo "   $(du -h "$work/backup.dump" | cut -f1) in $((t1 - t0)) s"

echo "2. Restore into $scratch"
psql "$admin_url" -qAt -c "create database \"$scratch\"" >/dev/null
pg_restore --no-owner --dbname="$scratch_url" "$work/backup.dump"
t2=$(date +%s)
echo "   restored in $((t2 - t1)) s"

echo "3. Row counts (source vs restored)"
counts() { # url -> "table count" lines
  local url="$1" t
  psql "$url" -qAt -c "select tablename from pg_tables where schemaname='public' order by 1" | while read -r t; do
    echo "$t $(psql "$url" -qAt -c "select count(*) from public.\"$t\"")"
  done
}
counts "$src_url" > "$work/src.txt"
counts "$scratch_url" > "$work/dst.txt"
tables=$(wc -l < "$work/src.txt" | tr -d ' ')
rows=$(awk '{s+=$2} END {print s+0}' "$work/src.txt")
if diff -u "$work/src.txt" "$work/dst.txt" > "$work/diff.txt"; then
  echo "   PASS: $tables tables, $rows rows identical"
  echo "   backup $((t1 - t0)) s, restore $((t2 - t1)) s"
else
  echo "   FAIL: counts differ"; cat "$work/diff.txt"; exit 1
fi
