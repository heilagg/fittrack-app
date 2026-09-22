-- 0004: производные данные. Таблицы и их колонки — из §3.1 SPEC.md.
--
-- Из исходного плана README здесь остаётся только muscle_fatigue:
-- plan_revisions, exercise_exclusions и analytics_events в §3.1 не
-- существуют — README ссылался на них с первого скелетного коммита, ещё до
-- того как схема была записана, и план был обновлён отдельным коммитом
-- (см. README этой папки).

-- Остаточное утомление по мышцам
create table muscle_fatigue (
  user_id     uuid not null references profiles on delete cascade,
  muscle      text not null,
  value       numeric(6,3) not null,    -- условные единицы
  -- БЕЗ зоны, и это не упущение: колонка хранит не отметку записи, а момент, на
  -- который посчитано утомление (§4.3), то есть значение шкалы FitCore, которая
  -- идёт по местному времени (§20.7). Распад §8.1 считается от разности этой
  -- метки и момента оценки дня; в timestamptz разность поехала бы на смещение
  -- зоны — 7 часов дают 21% по мышце с полураспадом 20 ч.
  updated_at  timestamp not null,
  primary key (user_id, muscle)
);
