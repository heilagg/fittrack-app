# Миграции Supabase

Применяются через Supabase CLI (`supabase db push`), локальная база для тестов —
`supabase start`.

Схема ещё не записана. Порядок первых миграций зафиксирован в плане:

1. `0001_core_schema.sql` — профиль, инвентарь, ограничения, PAR-Q
2. `0002_cycle.sql` — `cycle_events`, `cycle_settings`, `phase_response_profile`
3. `0003_training.sql` — планы, тренировки, упражнения, подходы, состояния
4. `0004_derived_and_meta.sql` — `muscle_fatigue`, `plan_revisions`,
   `exercise_exclusions`, `analytics_events`
5. `0005_rls.sql` — RLS на всех таблицах одной политикой `user_id = auth.uid()`

Конвенции для каждой таблицы: клиентский UUID в `id`, денормализованный
`user_id`, `updated_at`, `deleted_at`, индекс `(user_id, updated_at)`.
