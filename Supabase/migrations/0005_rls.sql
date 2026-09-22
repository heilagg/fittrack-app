-- 0005: RLS (§3.2 SPEC.md).
--
-- Правило по умолчанию: "own rows" на каждой таблице с user_id —
-- `user_id = auth.uid()`. Для profiles — `id = auth.uid()` (это и есть её
-- user_id: первичный ключ ссылается на auth.users). Для дочерних таблиц без
-- собственного user_id (planned_days, workout_exercises, sets) — политика по
-- владельцу родителя через join; §3.2 явно называет только workout_exercises
-- и sets, но правило — «дочерние таблицы через join по владельцу родителя»,
-- и planned_days (без user_id, владелец — week_plans.user_id) подпадает под
-- него ровно так же.

-- profiles: id — тот же uuid, что и auth.users.id (§3.1)
alter table profiles enable row level security;
create policy "own rows" on profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- Таблицы с собственной колонкой user_id
alter table body_weight_entries enable row level security;
create policy "own rows" on body_weight_entries
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table equipment_profiles enable row level security;
create policy "own rows" on equipment_profiles
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table user_restrictions enable row level security;
create policy "own rows" on user_restrictions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table parq_responses enable row level security;
create policy "own rows" on parq_responses
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table cycle_events enable row level security;
create policy "own rows" on cycle_events
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table cycle_profiles enable row level security;
create policy "own rows" on cycle_profiles
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table phase_response_profile enable row level security;
create policy "own rows" on phase_response_profile
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table daily_checkins enable row level security;
create policy "own rows" on daily_checkins
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table week_plans enable row level security;
create policy "own rows" on week_plans
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table workouts enable row level security;
create policy "own rows" on workouts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table exercise_states enable row level security;
create policy "own rows" on exercise_states
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table stretch_sessions enable row level security;
create policy "own rows" on stretch_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table muscle_fatigue enable row level security;
create policy "own rows" on muscle_fatigue
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Дочерние таблицы без user_id: владелец — через join к родителю

alter table planned_days enable row level security;
create policy "own rows" on planned_days
  for all using (
    exists (
      select 1 from week_plans wp
      where wp.id = planned_days.week_plan_id
        and wp.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from week_plans wp
      where wp.id = planned_days.week_plan_id
        and wp.user_id = auth.uid()
    )
  );

alter table workout_exercises enable row level security;
create policy "own rows" on workout_exercises
  for all using (
    exists (
      select 1 from workouts w
      where w.id = workout_exercises.workout_id
        and w.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from workouts w
      where w.id = workout_exercises.workout_id
        and w.user_id = auth.uid()
    )
  );

alter table sets enable row level security;
create policy "own rows" on sets
  for all using (
    exists (
      select 1 from workout_exercises we
      join workouts w on w.id = we.workout_id
      where we.id = sets.workout_exercise_id
        and w.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from workout_exercises we
      join workouts w on w.id = we.workout_id
      where we.id = sets.workout_exercise_id
        and w.user_id = auth.uid()
    )
  );
