#!/usr/bin/env bash
# Führt alle Browser-Tests gegen den lokalen Supabase-Stack aus.
# Voraussetzungen: `supabase start`, App unter http://127.0.0.1:8081 (z. B. python3 -m http.server 8081),
# Node mit Playwright (npm i playwright && npx playwright install chromium).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${HUSORA_E2E_OUT:-$DIR/output}"
mkdir -p "$OUT/open" "$OUT/audit"
export HUSORA_E2E_OUT="$OUT"
TESTS="${*:-auth cloud plans partner hub hub2 msg custom dispatch withdraw compl pp2 bulk back team access launch issues followup archive usage portfolio batch crawl}"
failed=0
for t in $TESTS; do
  log="$OUT/$t.log"
  ( cd "$OUT" && timeout 600 node "$DIR/$t.js" ) > "$log" 2>&1
  code=$?
  ok=$(grep -c '^OK' "$log" || true); bad=$(grep -c '^FEHL' "$log" || true)
  if [ $code -ne 0 ] || [ "$bad" -gt 0 ] || grep -q '^JS-Fehler:' "$log"; then
    echo "✗ $t  (OK $ok, FEHL $bad, Exit $code)"; grep -E '^FEHL|^JS-Fehler' -A2 "$log" | head -8 | sed 's/^/    /'; failed=1
  else
    echo "✓ $t  (OK $ok)"
  fi
done
exit $failed
