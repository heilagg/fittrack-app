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

Конвенции для каждой таблицы: клиентский UUID в `id`, денормализованный
`user_id`, `updated_at`, `deleted_at`, индекс `(user_id, updated_at)`.
