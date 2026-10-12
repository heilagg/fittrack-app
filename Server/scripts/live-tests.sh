#!/usr/bin/env bash
# Живые тесты Server одной командой: поднимает локальный Supabase, готовит
# окружение и гоняет `swift test` в обязательном режиме
# (FITTRACK_REQUIRE_LIVE=1): пропущенный живой тест — ошибка, а не зелёный
# прогон. Аргументы уходят в `swift test` как есть (`--filter 20e`).
#
# Что делает, по порядку (как в шапке Tests/FitServerTests/LiveHarness.swift):
#   1. `supabase start`, если не запущен, и `supabase migration up --local`;
#   2. пароль роли `fitserver` — заново каждый раз: `supabase db reset`
#      пересоздаёт роль без пароля;
#   3. ключи publishable и service_role из `supabase status -o env` — заново
#      каждый раз: они меняются при каждом `supabase start`;
#   4. пробный анонимный signup. Если Postgres упёрся в 100 соединений
#      (`Database error creating anonymous user`), Supabase перезапускается
#      один раз и шаги 2–4 повторяются; токен этого signup — FITTRACK_LIVE_TOKEN;
#   5. пустой JWKS на свободном порту для `LiveJWKSChecks` (останавливается
#      на выходе);
#   6. `swift test` из Server/.
#
# Ключи и токен в вывод не печатаются.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
server="$root/Server"
db_url="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
issuer="http://127.0.0.1:54321/auth/v1"

say() { printf '[live-tests] %s\n' "$*" >&2; }

supabase_env() {
  (cd "$root" && supabase status -o env 2>/dev/null) | sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p"
}

prepare() {
  (cd "$root" && supabase migration up --local >/dev/null)
  psql "$db_url" -q -c "alter role fitserver with password 'fitserver'" >/dev/null
  anon_key="$(supabase_env PUBLISHABLE_KEY)"
  [ -n "$anon_key" ] || anon_key="$(supabase_env ANON_KEY)"
  service_key="$(supabase_env SERVICE_ROLE_KEY)"
  if [ -z "$anon_key" ] || [ -z "$service_key" ]; then
    say "supabase status не отдал ключи"; exit 1
  fi
}

# Пишет access_token в stdout; при отказе — тело ответа в stderr и код 1.
sign_up() {
  local response status body
  response="$(curl -s -w '\n%{http_code}' -X POST "$issuer/signup" \
    -H "apikey: $anon_key" -H 'Content-Type: application/json' -d '{}')"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" != 200 ]; then
    printf 'signup %s: %s\n' "$status" "$body" >&2
    return 1
  fi
  printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

cd "$root"
if ! supabase status >/dev/null 2>&1; then
  say "supabase start"
  supabase start >/dev/null
fi
prepare

if ! live_token="$(sign_up 2>"${TMPDIR:-/tmp}/live-tests-signup.$$")"; then
  if grep -q 'Database error creating anonymous user' "${TMPDIR:-/tmp}/live-tests-signup.$$"; then
    say "Postgres упёрся в соединения — перезапуск Supabase"
    supabase stop >/dev/null
    supabase start >/dev/null
    prepare
    live_token="$(sign_up)"
  else
    cat "${TMPDIR:-/tmp}/live-tests-signup.$$" >&2
    rm -f "${TMPDIR:-/tmp}/live-tests-signup.$$"
    exit 1
  fi
fi
rm -f "${TMPDIR:-/tmp}/live-tests-signup.$$"

jwks_dir="$(mktemp -d)"
mkdir -p "$jwks_dir/.well-known"
printf '{"keys":[]}' > "$jwks_dir/.well-known/jwks.json"
jwks_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$jwks_port" --bind 127.0.0.1 --directory "$jwks_dir" >/dev/null 2>&1 &
jwks_pid=$!
trap 'kill "$jwks_pid" 2>/dev/null; rm -rf "$jwks_dir"' EXIT
for _ in $(seq 50); do
  curl -sf "http://127.0.0.1:$jwks_port/.well-known/jwks.json" >/dev/null && break
  sleep 0.1
done

say "swift test $*"
cd "$server"
FITTRACK_REQUIRE_LIVE=1 \
FITTRACK_LIVE_ISSUER="$issuer" \
FITTRACK_ANON_KEY="$anon_key" \
FITTRACK_DB_PASSWORD=fitserver \
FITTRACK_SERVICE_ROLE_KEY="$service_key" \
FITTRACK_LIVE_TOKEN="$live_token" \
FITTRACK_EMPTY_JWKS_ISSUER="http://127.0.0.1:$jwks_port" \
swift test "$@"
