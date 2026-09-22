#!/bin/bash
# Обязательный тест изоляции RLS (§3.2 SPEC.md): два анонимных пользователя,
# один сеет по строке в каждую синхронизируемую таблицу, второй не должен
# увидеть ни одной. Проверяется на прямом SQL-уровне через тот же механизм,
# которым §20.4 описывает доступ сервера — `set local role authenticated;
# set local request.jwt.claims = '...'` — а не через PostgREST. Это НЕ
# заменяет будущий HTTP-тест 20a (§20.15): тот пойдёт через реальные
# эндпоинты сервера, когда появится сам Server.
#
# Требует запущенного `supabase start` (см. Supabase/migrations/README.md) с
# enable_anonymous_sign_ins = true в Supabase/config.toml.
set -euo pipefail

API_URL="${SUPABASE_API_URL:-http://127.0.0.1:54321}"
DB_URL="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ANON_KEY="${SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== Signing up two anonymous users =="
signup() {
  curl -sf -X POST "$API_URL/auth/v1/signup" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d '{}'
}
USER_A_JSON=$(signup)
USER_B_JSON=$(signup)
USER_A=$(echo "$USER_A_JSON" | node -e "console.log(JSON.parse(require('fs').readFileSync(0)).user.id)")
USER_B=$(echo "$USER_B_JSON" | node -e "console.log(JSON.parse(require('fs').readFileSync(0)).user.id)")
[ -n "$USER_A" ] && [ -n "$USER_B" ] || fail "could not sign up anonymous users"
echo "USER_A=$USER_A"
echo "USER_B=$USER_B"

CLAIMS_A="{\"sub\":\"$USER_A\",\"role\":\"authenticated\"}"
CLAIMS_B="{\"sub\":\"$USER_B\",\"role\":\"authenticated\"}"

cleanup() {
  psql "$DB_URL" -q -c "delete from profiles where id in ('$USER_A', '$USER_B');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== Seeding one row per synced table for USER_A (as postgres, bypasses RLS) =="
psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<SQL
begin;

insert into profiles (id, experience_level, goal, days_per_week, training_weekdays, display_name)
values ('$USER_A', 'novice', 'strength', 3, array[1,3,5]::smallint[], 'A-profile');

insert into body_weight_entries (id, user_id, weight_kg, measured_on)
values (gen_random_uuid(), '$USER_A', 60.0, '2026-09-20');

insert into equipment_profiles (id, user_id, name)
values (gen_random_uuid(), '$USER_A', 'A-gym');

insert into user_restrictions (id, user_id, joint, severity)
values (gen_random_uuid(), '$USER_A', 'knee', 'avoid');

insert into parq_responses (user_id, answers, has_red_flag, acknowledged, completed_at)
values ('$USER_A', '{}'::jsonb, false, true, now());

insert into cycle_events (id, user_id, kind, occurred_on)
values (gen_random_uuid(), '$USER_A', 'period_start', '2026-09-01');

insert into cycle_profiles (user_id) values ('$USER_A');

insert into phase_response_profile (user_id, phase) values ('$USER_A', 'follicular');

insert into daily_checkins (id, user_id, checkin_date)
values (gen_random_uuid(), '$USER_A', '2026-09-20');

insert into week_plans (id, user_id, week_start, generated_at, input_digest)
values ('aaaaaaa1-0000-0000-0000-000000000001', '$USER_A', '2026-09-21', now(), '{"v":1}'::jsonb);

insert into planned_days (id, week_plan_id, planned_date, session_kind)
values ('aaaaaaa2-0000-0000-0000-000000000001', 'aaaaaaa1-0000-0000-0000-000000000001', '2026-09-21', 'full_body');

insert into workouts (id, user_id, planned_day_id, started_at, session_kind, readiness)
values ('aaaaaaa3-0000-0000-0000-000000000001', '$USER_A', 'aaaaaaa2-0000-0000-0000-000000000001', now(), 'full_body', 1.0);

insert into workout_exercises (id, workout_id, exercise_slug, order_index, target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
values ('aaaaaaa4-0000-0000-0000-000000000001', 'aaaaaaa3-0000-0000-0000-000000000001', 'squat', 0, 3, 8, 12, 2, 1.0);

insert into sets (id, workout_exercise_id, set_index, prescribed_reps)
values ('aaaaaaa5-0000-0000-0000-000000000001', 'aaaaaaa4-0000-0000-0000-000000000001', 0, 10);

insert into exercise_states (user_id, exercise_slug, current_rep_min, current_rep_max)
values ('$USER_A', 'squat', 8, 12);

insert into muscle_fatigue (user_id, muscle, value, updated_at)
values ('$USER_A', 'quads', 10.0, now());

insert into stretch_sessions (id, user_id, template_slug, started_at, kind)
values (gen_random_uuid(), '$USER_A', 'morning', now(), 'mobility_warmup');

commit;
SQL

TABLES="profiles body_weight_entries equipment_profiles user_restrictions parq_responses cycle_events cycle_profiles phase_response_profile daily_checkins week_plans planned_days workouts workout_exercises sets exercise_states muscle_fatigue stretch_sessions"

count_as() {
  local claims="$1"
  psql "$DB_URL" -t -A -q <<SQL
begin;
set local role authenticated;
set local request.jwt.claims = '$claims';
select
  (select count(*) from profiles) + (select count(*) from body_weight_entries) +
  (select count(*) from equipment_profiles) + (select count(*) from user_restrictions) +
  (select count(*) from parq_responses) + (select count(*) from cycle_events) +
  (select count(*) from cycle_profiles) + (select count(*) from phase_response_profile) +
  (select count(*) from daily_checkins) + (select count(*) from week_plans) +
  (select count(*) from planned_days) + (select count(*) from workouts) +
  (select count(*) from workout_exercises) + (select count(*) from sets) +
  (select count(*) from exercise_states) + (select count(*) from muscle_fatigue) +
  (select count(*) from stretch_sessions);
rollback;
SQL
}

echo "== USER_B reading all tables: expect 0 total rows =="
TOTAL_B=$(count_as "$CLAIMS_B" | tr -d '[:space:]')
echo "total visible to B: $TOTAL_B"
[ "$TOTAL_B" = "0" ] || fail "USER_B saw $TOTAL_B row(s) belonging to USER_A — RLS isolation broken"

echo "== USER_A reading all tables: expect 17 total rows (own data, one per table) =="
TOTAL_A=$(count_as "$CLAIMS_A" | tr -d '[:space:]')
echo "total visible to A: $TOTAL_A"
[ "$TOTAL_A" = "17" ] || fail "USER_A saw $TOTAL_A row(s), expected 17 — RLS over-restrictive or seed incomplete"

echo "== anon role, no JWT claims: expect 0 =="
TOTAL_ANON=$(psql "$DB_URL" -t -A -q <<SQL
begin;
set local role anon;
select (select count(*) from profiles) + (select count(*) from workouts) + (select count(*) from sets);
rollback;
SQL
)
[ "$TOTAL_ANON" = "0" ] || fail "anon role saw $TOTAL_ANON row(s) with no claims at all"

echo "PASS: RLS isolation holds across all $(echo $TABLES | wc -w | tr -d ' ') tables (§3.2)"
