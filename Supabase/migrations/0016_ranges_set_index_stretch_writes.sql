-- 0016: диапазоны полей, номер подхода и запись stretch_sessions только сервером
-- (SPEC §3.1, §3.2, §20.3, §20.6).
--
-- 1. Диапазоны. Сервер отвечает на выход за них 422 до записи, клиент
--    проверяет до отправки, а check'и ниже — последняя линия, в том числе для
--    таблиц, которые фронтенд пишет напрямую (equipment_profiles,
--    body_weight_entries, §20.6): там сервера на пути нет вовсе.
--
--    Все check'и — `not valid`: они действуют на каждую новую и изменённую
--    строку, а уже записанные не перепроверяются. Записанное до этого правила
--    (подход с нулевым номером из старых тестов, рост 10 см из ручной проверки
--    аудита) — история, и миграция её не переписывает: подход неизменяем
--    (§4.3), а профиль правит только его владелица. `validate constraint`
--    можно выполнить позже, когда таких строк не останется.
--
-- 2. Номер подхода уникален в паре (упражнение тренировки, слаг). Индекс
--    частичный по той же причине: подходы-дубли, записанные до правила (второй
--    подход с тем же номером и новым id — ровно та ошибка, которую правило
--    закрывает), не удаляются и не перенумеровываются. Из индекса исключаются
--    все дубли, кроме первого по `id` в каждой группе, — список вычисляется на
--    базе, к которой миграция применяется, и на базе без дублей пуст. Новые
--    подходы под исключение не попадают никогда: их `id` в списке нет.
--
-- 3. stretch_sessions владелице — только на чтение (§3.2). Пишет сервер:
--    `session_user` у него — роль входа `fitserver` (§20.4), у PostgREST —
--    `authenticator`. Удаления нет вовсе: строки удаляются мягко.

alter table profiles
  add constraint profiles_birth_year_range
    check (birth_year between 1936 and extract(year from current_date)::int - 14) not valid,
  add constraint profiles_sex_at_birth_values
    check (sex_at_birth in ('female', 'male', 'undisclosed')) not valid,
  add constraint profiles_height_cm_range
    check (height_cm between 100 and 250) not valid,
  add constraint profiles_session_minutes_range
    check (session_minutes between 10 and 180) not valid;

alter table body_weight_entries
  add constraint body_weight_entries_weight_range
    check (weight_kg between 20 and 300) not valid;

alter table equipment_profiles
  add constraint equipment_weights_range check (
    0 < all(dumbbells_kg) and 500 >= all(dumbbells_kg)
    and 0 < all(plates_kg) and 500 >= all(plates_kg)
    and 0 < all(kettlebells_kg) and 500 >= all(kettlebells_kg)
    and barbell_kg > 0 and barbell_kg <= 500
    and machine_step_kg > 0 and machine_step_kg <= 500) not valid;

alter table sets
  add constraint sets_set_index_positive check (set_index >= 1) not valid,
  add constraint sets_prescribed_kg_range check (prescribed_kg between 0 and 500) not valid,
  add constraint sets_prescribed_reps_range check (prescribed_reps between 0 and 100) not valid,
  add constraint sets_actual_kg_range check (actual_kg between 0 and 500) not valid,
  add constraint sets_actual_reps_range check (actual_reps between 0 and 100) not valid;

do $$
declare
  legacy uuid[];
begin
  select coalesce(array_agg(id order by id), '{}') into legacy
    from (select id,
                 row_number() over (partition by workout_exercise_id, exercise_slug, set_index
                                    order by id) as n
            from sets) ranked
   where n > 1;
  execute format(
    'create unique index sets_index_per_exercise
       on sets (workout_exercise_id, exercise_slug, set_index)
       where id <> all (%L::uuid[])', legacy);
end
$$;

drop policy "own rows" on stretch_sessions;

create policy "own rows read" on stretch_sessions
  for select using (user_id = auth.uid());
create policy "server writes" on stretch_sessions
  for insert with check (user_id = auth.uid() and session_user = 'fitserver');
create policy "server updates" on stretch_sessions
  for update using (user_id = auth.uid() and session_user = 'fitserver')
  with check (user_id = auth.uid() and session_user = 'fitserver');
