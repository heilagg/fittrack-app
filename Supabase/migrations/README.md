# Миграции Supabase

Применяются через Supabase CLI (`supabase db push`), локальная база для тестов —
`supabase start`.

Этот план актуален по составу файлов (какая таблица в какой миграции), но не по
составу таблиц: таблицы и их колонки берутся из §3.1 SPEC.md как единственного
источника истины. README — только разбиение на файлы миграций.

1. `0001_core_schema.sql` — профиль, инвентарь, ограничения, PAR-Q
2. `0002_cycle.sql` — `cycle_events`, `cycle_profiles`, `phase_response_profile`
3. `0003_training.sql` — планы, тренировки, упражнения, подходы, состояния
4. `0004_derived_and_meta.sql` — `muscle_fatigue`
5. `0005_rls.sql` — RLS на всех таблицах (§3.2): `id = auth.uid()` для
   `profiles`, `user_id = auth.uid()` для таблиц с этой колонкой, join по
   владельцу родителя для дочерних таблиц без `user_id`
   (`planned_days`, `workout_exercises`, `sets`)
6. `0006_week_plan_snapshot.sql` — `week_plans.last_shown_plan` (§20.6): вход
   для `Planner.rebuildNotice`. Отдельной миграцией, а не правкой `0003`,
   потому что 0001–0005 уже прогнаны, а схемозначимость этого пункта выяснилась
   после них
7. `0007_workout_exercise_calibration.sql` — `workout_exercises.is_calibration`
   (§9.8, §20.6): снимок `exercise_states.in_calibration` на момент старта, по
   которому калибровочные подходы исключаются из утомления и из `неделя[m]`.
   Флаг на `workouts` остаётся баннеру и аналитике
8. `0008_server_role.sql` — роль подключения веб-сервера `fitserver` (§20.4,
   §3.2): `login noinherit`, без собственных прав, умеет только стать
   `authenticated` подстановкой claims. Единственная миграция уровня КЛАСТЕРА,
   а не базы, и потому единственная идемпотентная
9. `0009_equipment_platforms.sql` — `equipment_profiles.step_platform` и
   `plyo_box` (§6.6): значения словаря инвентаря приходят вместе со своими
   колонками. Написана до разметки библиотеки (content-domain §2 п.6)
10. `0010_profile_stepwise.sql` — четыре колонки `profiles` становятся nullable
    (§3.1, §5, §20.6): онбординг на вебе пишется на сервер пошагово, и строка
    существует НЕПОЛНОЙ. Снимает инвариант «строка `profiles` есть →
    планировщику есть с чем работать», взамен заводит парный constraint на
    `days_per_week`/`training_weekdays` и правило полноты в §20.6
11. `0011_one_workout_per_planned_day.sql` — частичный unique-индекс
    `workouts (planned_day_id) where planned_day_id is not null and deleted_at
    is null` (§20.3): ключ идемпотентности повторного `POST /v1/workouts`.
    В схеме, а не в приложении, потому что `repeatable read` §20.4 фантомную
    вставку не запрещает и два параллельных старта проходят проверку чтением оба
12. `0012_set_exercise_snapshot.sql` — `sets.exercise_slug`, `is_calibration`
    и `weight_readiness`, снимок упражнения на момент подхода (§3.1, §13.4,
    §20.6): после замены упражнения строка `workout_exercises` описывает
    новое, а подходы до замены остаются фактом о прежнем. Заполняется из
    `workout_exercises`, без значений по умолчанию

Конвенции для каждой таблицы: клиентский UUID в `id`, денормализованный
`user_id`, `updated_at`, `deleted_at`, индекс `(user_id, updated_at)`.
