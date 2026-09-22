-- 0003: планы, тренировки, упражнения, подходы, состояния, плюс daily_checkins
-- и stretch_sessions — организационно ближе к тренировочному циклу, чем к
-- профилю (0001) или к производным/метаданным (0004). Таблицы и их колонки —
-- из §3.1 SPEC.md; см. README этой папки.

-- Ежедневный чек-ин
create table daily_checkins (
  id             uuid primary key,
  user_id        uuid not null references profiles on delete cascade,
  checkin_date   date not null,
  energy         int check (energy between 1 and 5),
  soreness       int check (soreness between 1 and 5),
  sleep_quality  int check (sleep_quality between 1 and 5),
  stress         int check (stress between 1 and 5),
  -- ручной оверрайд поверх фазовой рекомендации
  override       text,                -- null | 'push' | 'ease' | 'rest'
  unique (user_id, checkin_date)
);

-- Недельный план
create table week_plans (
  id            uuid primary key,
  user_id       uuid not null references profiles on delete cascade,
  week_start    date not null,        -- понедельник
  generated_at  timestamptz not null,
  -- Разгрузочная ли это неделя (§11.5). Значение фиксируется в момент
  -- генерации и пересборкой не пересчитывается: пересборка обязана давать тот
  -- же план на неизменившемся входе (§7.1), а вычисляемый признак менял бы его
  -- от одного течения времени. Правило счёта открыто (§19.2 п.4), до его
  -- закрытия сервер всегда пишет false.
  is_deload     boolean not null default false,
  -- Полный снимок входа генерации с номером версии: {"v": 1, ...}.
  -- Назначение — отладка, поддержка и воспроизводимость («какой именно вход дал
  -- этот план»), НЕ определение причины пересборки: причину §7.1 даёт
  -- Planner.rebuildNotice, а она сравнивает два ВЫХОДА планировщика и дайджест
  -- не читает. Версия обязательна с первой записи: колонка not null, и без
  -- номера любое изменение формы потребовало бы миграции данных.
  input_digest  jsonb not null,
  unique (user_id, week_start)
);

create table planned_days (
  id            uuid primary key,
  week_plan_id  uuid not null references week_plans on delete cascade,
  planned_date  date not null,
  session_kind  text not null,        -- 'full_body' | 'upper' | 'lower' | 'push' | 'pull' | 'rest' | 'stretch'
  accent_muscle text,                 -- слаг мышцы или null; ставит пользователь, сетка — null (§7.2)
  status        text not null default 'planned', -- 'planned' | 'done' | 'skipped' | 'replaced'
  unique (week_plan_id, planned_date)
);

-- Тренировка
create table workouts (
  id              uuid primary key,
  user_id         uuid not null references profiles on delete cascade,
  planned_day_id  uuid references planned_days on delete set null,
  started_at      timestamptz not null,
  finished_at     timestamptz,
  session_kind    text not null,
  accent_muscle   text,
  equipment_profile_id uuid references equipment_profiles,
  -- контекст на момент генерации, нужен для разбора «почему мне это дали»
  -- null если режим без фаз либо опорной даты нет (§11.3)
  cycle_phase     text,               -- 'menstrual' | 'follicular' | 'ovulatory'
                                      -- | 'early_luteal' | 'late_luteal'
  cycle_confidence numeric(3,2),
  -- дневная готовность (§10); к весу упражнения применяется
  -- workout_exercises.weight_readiness (§7.6)
  readiness       numeric(4,3) not null,
  is_calibration  boolean not null default false,
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  sync_seq        bigint not null default nextval('sync_seq_all')
);

create trigger sync_seq_bump before insert or update on workouts
  for each row execute function bump_sync_seq();

create table workout_exercises (
  id             uuid primary key,
  workout_id     uuid not null references workouts on delete cascade,
  exercise_slug  text not null,
  order_index    int not null,
  target_sets    int not null,
  target_rep_min int not null,
  target_rep_max int not null,
  target_rir     int not null,
  -- рекомендованный вес на первый подход, кг; null для упражнений без веса
  prescribed_kg  numeric(6,2),
  -- готовность, применённая к весу этого упражнения (§9.6, §10): prescribed_kg
  -- считается от неё, пересчёт прогрессии (§4.3) читает её, а не
  -- workouts.readiness (§7.6). Заполняется и для упражнений без веса
  weight_readiness numeric(4,3) not null,
  substituted_from text,              -- слаг заменённого упражнения
  substitution_reason text            -- 'equipment' | 'pain' | 'user_choice' | 'occupied'
);

create table sets (
  id                  uuid primary key,
  workout_exercise_id uuid not null references workout_exercises on delete cascade,
  set_index           int not null,
  prescribed_kg       numeric(6,2),
  prescribed_reps     int not null,
  actual_kg           numeric(6,2),
  actual_reps         int,
  -- 'easy' | 'ok' | 'hard' | 'failed'
  feedback            text,
  pain_flag           boolean not null default false,
  -- Суставы, которым приписан флаг боли (§8.4 п.5, §19.2 п.8). Массив, а не
  -- один слаг: у упражнения бывает несколько суставов одинаковой степени, и
  -- выбирать между ними произвольно нельзя. Факт фиксируется на момент события:
  -- переразметка joint_stress в контенте уже случившиеся события не меняет.
  -- Пусто, когда pain_flag = false.
  pain_joints         text[] not null default '{}',
  rest_seconds        int,
  completed_at        timestamptz,
  skipped             boolean not null default false
);

-- Состояние прогрессии: одна строка на (пользователь, упражнение)
create table exercise_states (
  user_id          uuid not null references profiles on delete cascade,
  exercise_slug    text not null,
  -- базовый рабочий вес: НЕ изменяется дневным множителем готовности
  baseline_kg      numeric(6,2),
  current_rep_min  int not null,
  current_rep_max  int not null,
  -- расширение диапазона повторов, когда следующий вес недостижим
  rep_extension    int not null default 0,   -- 0..4
  -- добавленные рабочие подходы, когда тяжелее нет вообще (§9.5, п.2);
  -- планировщик прибавляет их к target_sets (§7.3)
  extra_sets_added int not null default 0,   -- 0..2
  stall_count      int not null default 0,
  -- Дата, а не момент: FitCore хранит её как CalendarDay, а §9.7 считает
  -- перерыв целыми днями. В timestamptz одна и та же сессия, прочитанная в
  -- другой зоне, переезжает через полночь и сдвигает ступень на сутки (§20.7).
  last_performed_at date,
  in_calibration   boolean not null default true,
  primary key (user_id, exercise_slug)
);

-- Сессии растяжки
create table stretch_sessions (
  id            uuid primary key,
  user_id       uuid not null references profiles on delete cascade,
  template_slug text not null,
  started_at    timestamptz not null,
  finished_at   timestamptz,
  kind          text not null            -- 'mobility_warmup' | 'static_cooldown' | 'standalone'
);

-- Тренировка синхронизируется целиком (§4.3): у workout_exercises и sets
-- нет ни своей отметки курсора, ни user_id, поэтому запись ребёнка двигает
-- отметку родителя. Двигается именно sync_seq, а не updated_at: последняя
-- принадлежит клиенту и служит LWW, и сервер в неё не пишет.
create function bump_parent_workout() returns trigger language plpgsql as $$
begin
  update workouts set sync_seq = nextval('sync_seq_all')
   where id = coalesce(new.workout_id, old.workout_id);
  return coalesce(new, old);
end $$;

create trigger sync_seq_bump_parent after insert or update or delete
  on workout_exercises for each row execute function bump_parent_workout();

create function bump_grandparent_workout() returns trigger
language plpgsql as $$
begin
  update workouts set sync_seq = nextval('sync_seq_all')
    from workout_exercises we
   where we.id = coalesce(new.workout_exercise_id, old.workout_exercise_id)
     and workouts.id = we.workout_id;
  return coalesce(new, old);
end $$;

-- Два триггера, а не один: WHEN-условие ниже ссылается на OLD, а Postgres
-- запрещает это для INSERT («INSERT trigger's WHEN condition cannot reference
-- OLD values»), поэтому одним объявлением insert or update or delete здесь не
-- обойтись.
create trigger sync_seq_bump_parent_ins after insert or delete
  on sets for each row execute function bump_grandparent_workout();

-- Идемпотентный ретрай (§20.6, тест 20e) приходит с тем же id и теми же
-- значениями. Без условия он двигал бы курсор на каждом повторе, и pull
-- получал бы страницу, в которой ничего не изменилось. Условие сравнивает
-- строку целиком, а расхождение масштаба numeric (40 против 40.0) приводится
-- типом колонки до сравнения и ложным изменением не считается.
create trigger sync_seq_bump_parent_upd after update
  on sets for each row
  when (old.* is distinct from new.*)
  execute function bump_grandparent_workout();
