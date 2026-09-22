-- 0001: профиль, инвентарь, ограничения, PAR-Q.
-- Таблицы и их колонки — из §3.1 SPEC.md; см. README этой папки.

-- Курсор pull-синхронизации (§4.3): серверная монотонная отметка записи.
-- Одна последовательность на все синхронизируемые таблицы — курсор всё равно
-- ведётся по таблице, а общий счётчик снимает вопрос, как сравнивать отметки
-- разных таблиц, если понадобится один курсор на всё.
create sequence sync_seq_all;

-- Канонический вид training_weekdays (§3.1, profiles): отсортированный набор
-- без повторов. Вынесено в функцию, потому что подзапрос в check-ограничении
-- Postgres не принимает; порядок фиксируется, чтобы один и тот же набор дней
-- не давал разных представлений в снимке input_digest.
create function weekdays_canonical(a smallint[]) returns boolean
language sql immutable as $$
  select a = (select array_agg(distinct x order by x) from unnest(a) as x)
$$;

-- Профиль
create table profiles (
  id                uuid primary key references auth.users on delete cascade,
  display_name      text,
  birth_year        int,                        -- не дата рождения: меньше PII
  sex_at_birth      text,                       -- 'female' | 'male' | 'undisclosed'
  height_cm         numeric(5,1),
  experience_level  text not null,              -- 'novice' | 'intermediate' | 'advanced'
  goal              text not null,              -- 'strength' | 'hypertrophy' | 'toning' | 'endurance' | 'general'
  days_per_week     int not null check (days_per_week between 1 and 7),
  -- Конкретные дни недели, ISO 1..7 (1 = понедельник), отсортированы (§5 шаг 6,
  -- §7.2). Планировщик берёт именно даты, а не количество: набор дней задаёт и
  -- типы дней, потому что сетка раздаёт их в календарном порядке. Уникальность
  -- проверяется отдельно от длины: Planner.weekGrid схлопывает дубликаты, и
  -- набор {2,2,4} при days_per_week = 3 дал бы молча два дня вместо трёх.
  training_weekdays smallint[] not null
    check (cardinality(training_weekdays) = days_per_week)
    check (training_weekdays <@ array[1,2,3,4,5,6,7]::smallint[])
    check (weekdays_canonical(training_weekdays)),
  session_minutes   int not null default 45,
  -- ИСТОЧНИК данных о цикле, не режим фаз: режим живёт в cycle_profiles.phase_mode
  cycle_tracking    text not null default 'off',-- 'off' | 'manual' | 'healthkit'
  units             text not null default 'kg',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- Серверная отметка для курсора pull (§4.3). НЕ заменяет updated_at: та
  -- клиентская и служит только LWW. Курсор по клиентской метке теряет
  -- строки устройства с отстающими часами навсегда (§18, сценарий 34a).
  sync_seq          bigint not null default nextval('sync_seq_all')
);

-- Отметку курсора двигает сервер на КАЖДОЙ записи строки: default
-- срабатывает только на insert, а pull обязан видеть и правку.
create function bump_sync_seq() returns trigger language plpgsql as $$
begin
  new.sync_seq := nextval('sync_seq_all');
  return new;
end $$;

create trigger sync_seq_bump before insert or update on profiles
  for each row execute function bump_sync_seq();

-- Вес тела: отдельная таблица, это временной ряд
create table body_weight_entries (
  id          uuid primary key,
  user_id     uuid not null references profiles on delete cascade,
  weight_kg   numeric(5,2) not null,
  measured_on date not null,
  source      text not null default 'manual',   -- 'manual' | 'healthkit'
  unique (user_id, measured_on)
);

-- Инвентарь: критично для округления весов
create table equipment_profiles (
  id          uuid primary key,
  user_id     uuid not null references profiles on delete cascade,
  name        text not null,                    -- 'Дом', 'Зал у работы'
  is_default  boolean not null default false,
  -- список доступных весов гантелей в кг, отсортированный
  dumbbells_kg      numeric(5,2)[] not null default '{}',
  -- блины на штангу (по одному, вес пары считается ×2)
  plates_kg         numeric(5,2)[] not null default '{}',
  barbell_kg        numeric(5,2),               -- null = штанги нет
  -- шаг стека тренажёров
  machine_step_kg   numeric(5,2),
  -- флаг главнее своей весовой колонки: при has_kettlebells = false набор
  -- гирь не читается, как бы он ни был заполнен (§7.5, контракт согласованности)
  has_kettlebells   boolean not null default false,
  kettlebells_kg    numeric(5,2)[] not null default '{}',
  bands             boolean not null default false,
  pullup_bar        boolean not null default false,
  bench             text,                       -- null | 'flat' | 'adjustable'
  cable_machine     boolean not null default false,
  machines          text[] not null default '{}' -- слаги тренажёров
);

-- Ограничения и травмы
create table user_restrictions (
  id          uuid primary key,
  user_id     uuid not null references profiles on delete cascade,
  joint       text not null,   -- 'knee' | 'lower_back' | 'shoulder' | 'wrist' | 'neck' | 'hip' | 'ankle'
  severity    text not null,   -- 'avoid' | 'careful'
  note        text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

-- PAR-Q
create table parq_responses (
  user_id       uuid primary key references profiles on delete cascade,
  answers       jsonb not null,       -- {q1: bool, ..., q7: bool}
  has_red_flag  boolean not null,
  acknowledged  boolean not null,     -- пользователь прочитал рекомендацию к врачу
  completed_at  timestamptz not null
);
