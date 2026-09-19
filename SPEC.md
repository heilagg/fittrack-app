# FitTrack — спецификация продукта

Версия документа: 1.0
Дата: 2026-09-01
Статус: черновик к утверждению, код не начат

---

## 1. Продукт

### 1.1 Суть

Приложение персональных силовых тренировок с адаптивной нагрузкой. Каждый день
пользователь выбирает тип тренировки (full body или сплит с акцентом на
конкретную мышечную группу), приложение собирает конкретную тренировку под его
инвентарь, опыт, восстановление и — для женщин с активным циклом — под фазу
цикла. После каждого подхода пользователь даёт фидбэк, приложение немедленно
корректирует следующие рекомендации.

### 1.2 Позиционирование

**Women-first.** Тон, контент, дефолтные акценты (ягодицы, задняя поверхность
бедра, спина) и цикл-модуль спроектированы под женскую аудиторию. Мужской режим
полностью работоспособен — просто без цикл-блока. Это ниша: приложение не
конкурирует с Strong/Hevy как трекер и не конкурирует с Fitbod как генератор
общего назначения.

### 1.3 Ключевое отличие

Три вещи вместе, чего нет ни у кого:

1. Адаптация **внутри подхода**, а не только между тренировками.
2. Акцент на мышцу **внутри** сплита через граф вклада мышц, а не через готовые
   шаблоны.
3. Фазовая периодизация с **честной деградацией** — когда предсказание цикла
   ненадёжно, влияние фазы плавно уходит в ноль, а не врёт с уверенным лицом.

### 1.4 Что НЕ делаем

- Не медицинское изделие. Не диагностируем, не лечим, не даём медицинских
  рекомендаций.
- Не поддерживаем беременность и послеродовой период (явный out of scope,
  см. §14.3).
- Не считаем питание и калории.
- Нет социальных функций, ленты, соревнований в MVP.

---

## 2. Технические решения

| Решение | Выбор | Обоснование |
|---|---|---|
| Платформа | Веб первый, нативный iOS после (§20) | Веб не зависит от ревью App Store и доходит до живых пользователей раньше; iOS остаётся ради HealthKit, Live Activities и офлайна |
| Минимальная iOS | 17.0 | SwiftData, Observation, современные Live Activities |
| Язык | Swift 6, strict concurrency | Новый проект — незачем накапливать долг |
| Веб-фронтенд | Vite + React, SPA | Вся логика за Swift-сервером, SEO не нужен — серверный рантайм на JS не окупается (§20.1) |
| Сервер логики | Vapor поверх FitCore | FitCore не переписывается и в браузер не компилируется (§20.1) |
| Локальное хранилище | SwiftData (только iOS) | Источник правды на устройстве; у веба локального хранилища нет (§20.10) |
| Бэкенд | Supabase (Postgres + Auth + RLS) | Реляционная модель, контроль над данными, путь на Android/web |
| Авторизация | Supabase anonymous auth с первого запуска, вход — email magic link | Нет барьера на входе, нет миграции данных при регистрации; один способ входа на обеих платформах исключает два `auth.uid()` (§20.5) |
| Локализация | Только русский, кг | Фокус на один рынок |
| Аналитика | Только агрегаты, без персональных health-данных | См. §14.5 |

### 2.1 Структура проекта

```
fittrack-app/
├── App/                         # iOS-клиент (SwiftUI), после веба
│   └── FitTrack/
│       ├── App/                 # точка входа, DI, роутинг
│       ├── Features/            # Onboarding, Today, Workout, Stretching, Progress, Profile
│       ├── DesignSystem/
│       └── Resources/
├── Server/                      # Vapor: тонкая обёртка над FitCore (§20)
├── Web/                         # SPA на Vite + React (§20)
├── Packages/
│   ├── FitCore/                 # чистая логика, ноль зависимостей от UI
│   │   ├── Progression/         # двойная прогрессия, калибровка
│   │   ├── Planner/             # сборка тренировки, граф вклада мышц
│   │   ├── Recovery/            # модель остаточного утомления
│   │   ├── Cycle/               # фазы, предсказание, уверенность
│   │   ├── Readiness/           # сводный множитель готовности
│   │   └── Equipment/           # лестница достижимых весов
│   ├── FitData/                 # SwiftData модели, репозитории, sync (только iOS)
│   ├── FitContent/              # библиотека упражнений (JSON + загрузчик)
│   └── FitTestSupport/
├── Supabase/                    # миграции, RLS, edge functions
├── Tools/                       # валидатор контента
└── Tests/
```

Подробная раскладка `Server/` и `Web/` — в §20.2.

**Принцип:** `FitCore` — чистые функции над значимыми типами, без импорта
SwiftUI, SwiftData и Foundation-даты в бизнес-логике (дата передаётся снаружи).
Это то, что покрывается тестами на 100%. Остальное тестируется по остаточному
принципу.

Из этого же принципа следует, что `FitCore` линкуется обеими платформами без
единой правки: iOS вызывает его локально, веб — через `Server/` (§20.1). Ни
одна его функция не переписывается на другом языке.

---

## 3. Модель данных

### 3.1 Схема Postgres

```sql
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

-- Цикл: только события, фазы вычисляются
create table cycle_events (
  id          uuid primary key,
  user_id     uuid not null references profiles on delete cascade,
  kind        text not null,          -- 'period_start' | 'period_end' | 'spotting'
  occurred_on date not null,
  source      text not null default 'manual', -- 'manual' | 'healthkit'
  unique (user_id, kind, occurred_on)
);

-- Цикл: настройки и заявленные данные. Отдельно от cycle_events, потому что это
-- НЕ временной ряд: одна строка на пользователя, переписывается.
create table cycle_profiles (
  user_id                    uuid primary key references profiles on delete cascade,
  -- Заявлено на онбординге (§5, шаг 9). Приор, пока нет измеренных циклов:
  -- на них прямо ссылается dataFactor в §11.3.
  typical_cycle_length_days  int check (typical_cycle_length_days between 15 and 60),
  typical_period_length_days int check (typical_period_length_days between 1 and 14),
  declared_regularity        text,   -- 'regular' | 'variable' | 'irregular'
  -- Режим фаз (§11.5). Причину храним отдельно: от неё зависит обратимость.
  phase_mode                 text not null default 'phases',  -- 'phases' | 'no_phases'
  no_phase_reason            text,   -- 'contraception' | 'amenorrhea' | 'menopause'
                                     -- | 'pregnancy' | 'user_choice' | 'declined'
                                     -- | 'low_confidence'
  -- Счётчик «уверенность ниже порога три цикла подряд» (§11.5). Инкрементируется
  -- на закрытии цикла, обнуляется на любом цикле с confidence ≥ 0.3.
  low_confidence_streak      int not null default 0,
  -- Докуда уже досчитан low_confidence_streak (§11.5): дата period_start,
  -- закрывшего последний учтённый цикл. null — ещё ничего не учтено. Без неё
  -- счётчик нечем защитить от повторного счёта одного и того же закрытия.
  low_confidence_counted_through date,
  updated_at                 timestamptz not null default now(),
  sync_seq                   bigint not null default nextval('sync_seq_all')
);

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
  last_performed_at timestamptz,
  in_calibration   boolean not null default true,
  primary key (user_id, exercise_slug)
);

-- Остаточное утомление по мышцам
create table muscle_fatigue (
  user_id     uuid not null references profiles on delete cascade,
  muscle      text not null,
  value       numeric(6,3) not null,    -- условные единицы
  updated_at  timestamptz not null,
  primary key (user_id, muscle)
);

-- Персональный профиль фазовой реакции (обучение по оверрайдам)
create table phase_response_profile (
  user_id     uuid not null references profiles on delete cascade,
  phase       text not null,          -- слаги те же, что у workouts.cycle_phase
  -- сдвиг к дефолтной поправке фазы, накопленный из оверрайдов, -0.15..+0.15
  adjustment  numeric(4,3) not null default 0,
  sample_size int not null default 0,
  -- когда пользователю сообщили о подстройке (§11.4). null = ещё не сообщали;
  -- без этого поля обязательное уведомление нечем ограничить одним показом
  notified_at timestamptz,
  primary key (user_id, phase)
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

-- Отметку курсора двигает сервер на КАЖДОЙ записи строки: default
-- срабатывает только на insert, а pull обязан видеть и правку.
create function bump_sync_seq() returns trigger language plpgsql as $$
begin
  new.sync_seq := nextval('sync_seq_all');
  return new;
end $$;

create trigger sync_seq_bump before insert or update on profiles
  for each row execute function bump_sync_seq();
create trigger sync_seq_bump before insert or update on cycle_profiles
  for each row execute function bump_sync_seq();
create trigger sync_seq_bump before insert or update on workouts
  for each row execute function bump_sync_seq();

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

create trigger sync_seq_bump_parent after insert or update or delete
  on sets for each row execute function bump_grandparent_workout();
```

### 3.2 RLS

Для каждой таблицы: `enable row level security` и политика вида

```sql
create policy "own rows" on <table>
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
```

Для `profiles` — `id = auth.uid()`. Для дочерних таблиц через join
(`workout_exercises`, `sets`) — политика по владельцу родителя.

Тест на RLS обязателен: интеграционный тест, который логинится двумя
анонимными пользователями и проверяет, что второй не видит строки первого.

### 3.3 Локальная модель

SwiftData-модели зеркалят схему один в один, плюс служебные поля:

- `syncState: SyncState` — `.synced` | `.pendingUpload` | `.conflicted`
- `updatedAt: Date` — используется для last-write-wins
- `deletedAt: Date?` — soft delete, физическое удаление только после
  подтверждённой синхронизации

Отдельно от моделей живёт локальная сущность синхронизации — **курсор pull, по
одному на таблицу** (§4.3). Это свойство реплики, а не данных: на сервер он не
выгружается и после переустановки начинается заново. Выводить его из самих
данных — например как максимум `updated_at` по локальным строкам — нельзя:
строки в `pendingUpload` несут собственную свежую метку и сдвинули бы курсор за
ещё не полученные чужие строки.

**Источник правды — устройство.** Сервер — реплика для бэкапа и будущего
мультидевайса.

---

## 4. Авторизация и синхронизация

### 4.1 Флоу

1. Первый запуск → `supabase.auth.signInAnonymously()`. Пользователь получает
   настоящий `auth.uid()` и работающий RLS. Никакого экрана логина.
2. Пользователь тренируется. Всё пишется локально и синхронизируется в фоне.
3. После третьей завершённой тренировки — мягкий, закрываемый промпт:
   «Сохранить прогресс, чтобы не потерять при смене телефона».
4. Sign in with Apple линкуется к тому же анонимному аккаунту
   (`supabase.auth.linkIdentity`). `auth.uid()` не меняется — **миграции данных
   нет вообще**.

**На вебе шаги 3 и 4 другие** (§20.5): линковка требуется до первой тренировки,
а не после третьей, и единственный способ завести аккаунт — email magic link.
Apple на iOS добавляется позже и только как `linkIdentity` к существующему
аккаунту: второй самостоятельный способ входа дал бы одному человеку два
`auth.uid()`, а слияния двух заполненных аккаунтов схема §3.1 не предусматривает.

### 4.2 Риск и его закрытие

Потеря устройства до линковки = потеря анонимного JWT = потеря данных на
сервере. Закрываем тремя способами:

- Refresh-токен в Keychain с `kSecAttrAccessibleAfterFirstUnlock` и **включённым
  iCloud Keychain sync** — переживает восстановление из бэкапа.
- Промпт на линковку после 3-й тренировки.
- Экспорт данных в JSON из настроек доступен всегда.

Если Sign in with Apple добавлен, то по правилу App Store 4.8 других провайдеров
входа быть не должно (или Apple должен быть среди них) — у нас Apple
единственный провайдер OAuth, требование выполнено автоматически.

**В браузере не работает ни одна из трёх мер.** Keychain отсутствует как
понятие, refresh-токен лежит в `localStorage`, и его сносит очистка данных
сайта, режим инкогнито и ITP Safari; экспорт из настроек предполагает, что
аккаунт ещё жив. Поэтому веб закрывает тот же риск иначе — обязательной
линковкой до первой тренировки (§20.5).

### 4.3 Синхронизация

Полностью офлайн-first. Приложение обязано работать в подвале без сети —
это не деградация, а нормальный режим.

**Область действия §4.3 — iOS-версия и пакет `FitData`.** Веб офлайна не имеет
и иметь не будет (§20.10): там нет ни локального хранилища, ни очереди
исходящих, ни курсора pull. Требование выше остаётся требованием к iOS, а не
общим требованием продукта.

- Все записи идут в SwiftData синхронно.
- Очередь исходящих изменений (`pendingUpload`) выгружается при появлении сети.
- Разрешение конфликтов: last-write-wins по `updated_at` на уровне строки.
- **Исключение:** `sets` иммутабельны после `completed_at`. Конфликт по
  завершённому подходу невозможен, потому что подход создаётся ровно на одном
  устройстве. Это снимает 90% реальных конфликтов.
- `exercise_states` и `muscle_fatigue` — производные. При конфликте не мержим, а
  **пересчитываем из истории подходов**. Это делает синхронизацию устойчивой:
  даже при расхождении состояние сойдётся.

#### Входящие изменения (pull)

**Область.** Всё, что описано ниже, определено для таблиц, где правило
разрешения конфликта выполнимо буквально, то есть у которых есть `updated_at`:
`profiles`, `cycle_profiles` и тренировка целиком (`workouts` +
`workout_exercises` + `sets`). Для остальных курсор и инкрементальный pull не
определены и не могут быть определены, пока не решено, чем разрешается конфликт
там, где сравнивать нечего (§19.2, п.16). `muscle_fatigue` в область не входит,
хотя колонка у неё есть: её `updated_at` — момент, на который посчитано
утомление (§8.1), а не отметка записи, и запоздавшая тренировка меняет `value`,
не двигая его; вдобавок эта таблица не мержится, а пересчитывается.

**Курсор — серверная отметка `sync_seq`, не `updated_at`.** Pull идёт страницами
фиксированного размера: `where sync_seq > cursor order by sync_seq, <первичный
ключ>`. Ключ сортировки — пара, а не одна отметка: на границе страницы строки с
равной отметкой иначе либо теряются, либо приезжают повторно. Курсор двигается
на последнюю строку применённой страницы.

Вести курсор по `updated_at` нельзя. Её пишет устройство своими часами (§3.3), и
строка устройства, чьи часы отстают, приходит на сервер с отметкой ниже уже
достигнутого курсора — вторая реплика не увидит её никогда и молча (§18,
сценарий 34a). Офлайн-режим не даёт права предполагать согласованность часов,
поэтому курсор и разрешение конфликта разведены по разным колонкам: серверная
отвечает на вопрос «что я ещё не получил», клиентская — «чья версия новее».

**Страница применяется и курсор двигается в одной локальной транзакции.** Иначе
падение между ними либо теряет страницу, либо переигрывает её.

**Тренировка — единица синхронизации.** У `workout_exercises` и `sets` нет ни
своей отметки курсора, ни `user_id`: pull ведёт по строке `workouts`, дети
тянутся по внешнему ключу, а запись ребёнка двигает `sync_seq` родителя (§3.1,
триггер). Без этого журнал подходов — то, ради чего §4.3 и существует, —
инкрементальному pull невиден.

**Тай-брейк конфликта.** LWW на равных `updated_at` не определён, а равные
отметки с двух устройств возможны. Разрешает их та же серверная отметка:
выигрывает бо́льший `sync_seq`. Без тай-брейка реплики расходятся — проверено
прогоном (см. ниже).

**Повторная доставка — факт, а не исключение.** Одна и та же строка приходит
дважды при пересинхронизации, и §4.3 этого не запрещает. Идемпотентность лежит
на ПРИМЕНЕНИИ: строка применяется как upsert по первичному ключу под правилом
конфликта, поэтому повторное применение той же версии даёт то же состояние.
Потребитель, который состояние не перезаписывает, а НАКАПЛИВАЕТ, из этого
свойства не следует и обязан объявить свою защиту явно — отметкой учёта, как
`low_confidence_counted_through` (§11.5), или производностью величины, как
`неделя[m]` (§7.3). Накопительный потребитель без такого объявления в релиз не
идёт.

#### Порядок применения

**Канонический порядок журнала — функция от набора строк, а не от порядка
доставки.** Сессии упорядочены по паре `(workouts.started_at, workouts.id)`,
подходы внутри сессии — по `sets.set_index`. Требование к ключу — одинаковость
на обеих репликах, а не соответствие настоящему времени: при расхождении часов
истинного порядка не существует вовсе, а сходимость требует одинаковости, не
истины.

**Порядок материализуется на приёме**, до того как строки попадут в любую
свёртку. Свёртки его не восстанавливают и не обязаны: `set_index` до FitCore
вообще не доезжает (в срезе подхода его нет — порядок массива и есть порядок
подходов), а сортировка по календарному дню внутридневной порядок не задаёт, то
есть две тренировки одного упражнения в один день ею не разводятся.

**Порядок внутри пакета** — по внешним ключам, родители раньше детей: тот же
порядок, что у выгрузки (`workouts → workout_exercises → sets`). Разбиение на
пакеты на результат не влияет.

**Где порядок не помогает.** Счётчик §11.5 зависит не от порядка входа, а от
момента вызова: отметка задним числом раньше `low_confidence_counted_through`
пропускается по построению, и это оговорённый предел точности. Сам момент вызова
при синхронизации остаётся открытым (§19.2, п.17). Утомление (§8.1) от порядка
не зависит вовсе: распад коммутативен, и журнал, свёрнутый в любом порядке, даёт
то же состояние.

**Проверено прогоном до внесения в текст.** Журнал из шести операций с одной
конфликтующей парой и одним удалением, 720 перестановок × пять форм доставки (по
одной операции, с дублированием, пакетами по 2, 3 и 4) = 3600 доставок;
сравнивалось полное состояние, включая производные `exercise_states` и
`muscle_fatigue`. С каноническим порядком все 3600 дают одно состояние; с
порядком прихода — два разных (две тренировки одного упражнения в один день
расходятся по `rep_extension`: 0 против 2). Повторная доставка того же пакета
состояния не меняет ни в одном прогоне. LWW без тай-брейка на равных
`updated_at` оставляет на репликах разные версии строки.

---

## 5. Онбординг

Цель — довести до первой тренировки максимально быстро, но собрать то, без чего
алгоритм не работает. Порядок экранов:

1. **Приветствие + дисклеймер.** Одна страница, явная кнопка «Понятно».
   Приложение не является медицинским изделием.
2. **PAR-Q** — 7 стандартных вопросов (§14.1). При красном флаге — экран с
   рекомендацией проконсультироваться с врачом и включением консервативного
   режима, но не блокировка.
3. **Базовое:** пол при рождении, год рождения, рост, вес.
4. **Опыт:** новичок (< 6 мес) / средний (6 мес – 2 года) / опытный (> 2 лет).
   Формулировки через поведение, а не через самооценку: «Знаю ли я, как
   выглядит правильная становая тяга?»
5. **Цель:** сила / набор мышечной массы / тонус и форма / выносливость / общее
   здоровье.
6. **Дни в неделю:** 1–7, с указанием конкретных дней недели (не только
   количества — это нужно планировщику).
7. **Инвентарь.** Самый важный и самый неудобный экран. Три пресета
   («дома без железа», «дома с гантелями», «зал») плюс детальная настройка:
   реальный список гантелей, блины, шаг стека. Пресет «зал» даёт непрерывный
   шаг 2.5 кг.
8. **Ограничения и травмы:** карта тела, выбор суставов, для каждого — «избегать»
   или «осторожно».
9. **Цикл** (только если `sex_at_birth = 'female'`):
   - «Отслеживаете ли вы менструальный цикл?» — да / нет / не сейчас
   - При «да»: **«Принимаете ли вы гормональную контрацепцию?»** Если да
     (КОК, ВМС с гормонами, имплант, инъекции) — явное объяснение, что при
     подавленной овуляции естественных фаз нет, и переход в режим без фаз с
     ежедневным чек-ином. Это ключевой экран, см. §11.5.
   - Дата начала последней менструации, обычная длина цикла, обычная
     длительность менструации, регулярность (регулярный / плавает / очень
     нерегулярный).

   Куда пишется каждый ответ (иначе §11.3 ссылается на данные, которых схема не
   хранит): дата → `cycle_events` как `period_start`; остальные три →
   `cycle_profiles.typical_cycle_length_days`, `typical_period_length_days`,
   `declared_regularity`. Ответ про контрацепцию → `phase_mode = 'no_phases'` с
   `no_phase_reason = 'contraception'`; «не хочу отвечать» → `'declined'`, не
   `'user_choice'`: это разные вещи, и первая при желании переспрашивается
   позже, вторая — нет.

   Любой из четырёх ответов можно пропустить. Если пропущена дата, опорной точки
   нет вовсе — это отдельное состояние, см. §11.3.
10. **Итог:** «Первые 2–3 тренировки — калибровочные. Веса будут занижены
    намеренно, приложение подберёт ваши за пару занятий».

Прерванный онбординг сохраняется пошагово, при перезапуске продолжается с
последнего экрана.

---

## 6. Библиотека упражнений

### 6.1 Объём

**60–80 упражнений** в MVP, каждое размечено глубоко. Качество разметки важнее
количества: алгоритм подбора хорош ровно настолько, насколько чисты данные.

Распределение примерно: ноги/ягодицы 22, спина 12, грудь 10, плечи 8, руки 8,
кор 10. Каждое упражнение должно иметь минимум по одному варианту под каждый
уровень инвентаря (без железа / гантели / зал), иначе домашний пользователь
упрётся в пустой подбор.

### 6.2 Схема упражнения

```json
{
  "slug": "hip_thrust_barbell",
  "name": "Ягодичный мостик со штангой",
  "pattern": "hinge",
  "muscle_contributions": {
    "glute_max": 0.60,
    "hamstrings": 0.20,
    "quads": 0.10,
    "erectors": 0.10
  },
  "equipment": ["bench_flat"],
  "equipment_optional": ["pad"],
  "load_type": "barbell",
  "weight_increment_source": "plates",
  "unilateral": false,
  "joint_stress": { "knee": "low", "lower_back": "medium", "hip": "medium" },
  "impact": "none",
  "skill_level": "intermediate",
  "default_rep_range": [8, 12],
  "default_rest_seconds": 120,
  "fatigue_cost": 1.0,
  "alternatives": ["hip_thrust_dumbbell", "glute_bridge_bw", "kas_glute_bridge"],
  "progression_family": "hip_thrust",
  "family_load_ratio": 1.0,
  "setup_seconds": 90,
  "cues": ["Подбородок к груди", "Рёбра вниз", "Сжать ягодицы в верхней точке"],
  "common_errors": ["Переразгибание поясницы", "Отрыв пяток"],
  "illustration": "hip_thrust_barbell"
}
```

### 6.3 Ключевые поля и зачем они

| Поле | Роль |
|---|---|
| `muscle_contributions` | Сумма ≈ 1.0. Ядро логики акцентов и учёта недельного объёма |
| `pattern` | `squat` / `hinge` / `lunge` / `push_h` / `push_v` / `pull_h` / `pull_v` / `carry` / `core` / `isolation`. Обеспечивает разнообразие тренировки |
| `load_type` | `bodyweight` / `bodyweight_loaded` / `dumbbell` / `barbell` / `machine` / `cable` / `band` / `kettlebell`. Определяет способ округления веса |
| `equipment` | Требования к инвентарю, кроме весов: упражнение выполнимо, только если выполнено каждое. Значения — закрытый словарь §6.6 |
| `equipment_optional` | Что пригодится, но не обязательно (`pad`). Только показ: на выполнимость не влияет, словарём §6.6 не ограничено |
| `joint_stress` | Фильтр по травмам. `avoid` исключает `high` и `medium`, `careful` — только `high` |
| `impact` | `none` / `low` / `high` — ударная нагрузка при приземлении. Единственный источник для овуляторного ограничения §11.2; из `pattern` и `joint_stress` не выводится (глубокий выпад нагружает колено, но приземления не даёт) |
| `progression_family` | Упражнения одной семьи делят историю прогрессии. Замена гантельного жима на штанговый не обнуляет прогресс |
| `family_load_ratio` | Рабочий вес упражнения относительно эталона своей `progression_family` (у эталона 1.0). Через него пересчитывается вес при переносе прогресса внутри семьи (§13.4): жим гантелей 20 кг ≠ жим штанги 20 кг. Обязателен в семье больше чем из одного упражнения — проверяет валидатор (§19.1) |
| `fatigue_cost` | Множитель вклада в остаточное утомление. Становая = 1.4, разгибание ног = 0.6 |
| `setup_seconds` | Бюджет времени: тренировка должна укладываться в `session_minutes` |
| `skill_level` | `novice` / `intermediate` / `advanced` — та же шкала, что `profiles.experience_level`: планировщик сравнивает их напрямую (§7.3). Новичку не выдаём рывковую тягу |

### 6.4 Мышцы

Плоский список слагов, никакой иерархии — иерархия только усложняет
суммирование объёма:

`glute_max`, `glute_med`, `quads`, `hamstrings`, `adductors`, `calves`,
`erectors`, `lats`, `traps_mid`, `traps_upper`, `rear_delts`, `side_delts`,
`front_delts`, `pecs`, `biceps`, `triceps`, `forearms`, `abs`, `obliques`.

### 6.5 Иллюстрации

MVP: статичные иллюстрации (одна поза старт + одна финиш) плюс текстовое
описание техники и cues. Видео отложено (§17).

**Лицензии проверить до начала работы.** Готовые открытые датасеты
(например free-exercise-db) можно использовать как черновик разметки, но
изображения оттуда требуют отдельной проверки лицензии. Безопасный путь —
заказать единый набор иллюстраций у иллюстратора с передачей прав.

К запуску веба идут изображения из проверенного открытого датасета с
пофайловой проверкой лицензии (§20.11). Заказ единого набора остаётся планом,
но перестаёт блокировать запуск.

### 6.6 Инвентарь

`equipment` — список **требований**, и все они обязательны: упражнение выполнимо
на профиле инвентаря (§3.1), только если выполнено каждое. Пустой список —
выполнимо без инвентаря.

Словарь закрытый: у каждого значения есть предикат над колонками
`equipment_profiles`, и значения без предиката не бывает. Новое значение вводится
в эту таблицу вместе с предикатом — и с колонкой §3.1, если её нет, — в одном
изменении SPEC. Значение вне таблицы — ошибка разметки; ловит её валидатор
(§19.1), а не планировщик.

| Значение | Выполнено, если |
|---|---|
| `bench_flat` | `bench` = `flat` или `adjustable` |
| `bench_adjustable` | `bench` = `adjustable` |
| `pullup_bar` | `pullup_bar` |
| `bands` | `bands` |
| `kettlebells` | `has_kettlebells` |
| `cable_machine` | `cable_machine` |
| `machine:<слаг>` | слаг ∈ `machines` |

**Требование — множество допустимых значений колонки, а не флаг.** `bench`
принимает три значения, и одно переименование колонки в требование этого не
выразит: горизонтальной скамье годится любая, наклонной — только регулируемая.

**Веса в словарь не входят.** Колонки весов — `dumbbells_kg`, `plates_kg`,
`barbell_kg`, `kettlebells_kg`, `machine_step_kg` — читает лестница достижимых
весов (§9.5), и второй раз их не проверяет никто. Отсюда второе условие
выполнимости: упражнение, чей `load_type` нагружается внешним весом (`dumbbell`,
`barbell`, `kettlebell`, `machine`, `cable`), невыполнимо, если его лестница
пуста — гантелей нет, штанги нет, шаг стека не задан. `bodyweight`,
`bodyweight_loaded` и `band` лестницы не имеют и этим условием не ограничены.
Значения `dumbbells`/`barbell` в словаре завели бы второй источник истины для
того же вопроса «есть ли чем нагрузить».

**Весовой `load_type` обязан называть свой инвентарь и в `equipment`:**
`kettlebell` — `kettlebells`, `cable` — `cable_machine`, `machine` — свой
`machine:<слаг>`. Лестница отвечает, есть ли веса, но не какой снаряд: у блока и
тренажёров `machine_step_kg` общий, и пользователь с одним тренажёром получил бы
на той же лестнице любой тренажёр и блок. Для гирь то же обеспечивает флаг.
Проверяет валидатор (§19.1).

Таблица выше — значения, которые уже форсируют колонки §3.1. Разметка этапа 2
может понадобить ещё (тумба, степ-платформа); такое значение приходит с новой
колонкой профиля по правилу выше, иначе пользователю негде его отметить.

---

## 7. Планировщик

### 7.1 Режим: недельный план с пересборкой

Пользователь видит план на текущую неделю. План — не догма: он пересобирается
при изменении входных данных.

**Триггеры пересборки:**

| Триггер | Что происходит |
|---|---|
| Смена фазы цикла (в т.ч. неожиданная) | Пересобираются оставшиеся дни недели |
| Пропуск тренировки | Оставшиеся дни пересобираются по изменившимся утомлению и накопленному объёму. Недельный масштаб `S_эфф` (§7.3) НЕ меняется: пропущенная сессия остаётся в знаменателе |
| Выполнена тренировка | Оставшиеся дни пересобираются от нового состояния: утомление, `неделя[m]`, предыдущая тренировка («Будущие дни» ниже). `S_эфф` не меняется |
| Изменение уверенности в фазе | Фазовые поправки перемасштабируются непрерывно (§11.2); при переходе через 0.3 меняется ещё и тип блока |
| Ручной оверрайд (§11.4) | Пересобирается только сегодняшний день; `rest` заменяет его на растяжку. Недельный объём НЕ перебалансируется: оверрайд живёт один день, и «догонять» его завтра нечем |
| Пользователь вручную поменял тип или акцент дня | Пересобирается только этот день + учёт в объёме |
| Изменение инвентаря | Пересобираются все будущие дни |
| Смена дней недели (`profiles.training_weekdays`) | Пересобираются будущие недели, начиная с ближайшей следующей генерации; уже сгенерированная текущая неделя не трогается |

Смена дней недели стоит особняком среди триггеров: она меняет не содержимое
дней, а саму сетку (§7.2) — набор дат задаёт и типы, потому что типы
раздаются в календарном порядке. Поэтому текущая неделя остаётся той, которую
пользовательница уже видела и по которой, возможно, уже тренировалась:
перекроить её значило бы переписать вторник задним числом. Новый набор вступает
в силу со следующей генерации недели.

**Пропущенное не догоняется, и это свойство формулы, а не отдельный механизм.**
Пропущенная сессия остаётся в знаменателе `S_эфф` (§7.3): её доля продолжает
делить недельную норму, поэтому оставшиеся дни получают ровно тот масштаб,
который получили бы и без пропуска. Отсюда инвариант §7.3: каждая выполненная
сессия отдаёт ровно ту долю недельной нормы, которая была ей запланирована, а
пропущенная — ноль; чужую долю не получает никто. Выпадение пропущенной сессии
из знаменателя и есть тот компенсаторный догон, который запрещает сценарий 32:
при пропуске одного из двух дней низа оно даёт оставшейся сессии 16 эффективных
подходов на ягодичные вместо восьми — 23 подхода, не влезающие ни в потолок пяти
подходов на упражнение, ни в `session_minutes`.

**Тип и акцент оставшихся дней пропуск не меняет.** Пересобирается содержимое;
сетка (§7.2) остаётся той, которую пользователь видел, и пропущенный день ног не
превращает завтрашний день верха в день ног. Довод тот же, по которому оверрайд
живёт один день: пропуск — факт исполнения, а не плановое решение, а ноги,
которые пропустили из-за боли, от переноса работы на завтра не выигрывают — о
болезненности, про которую не сообщили, §8.1 не знает. Цена решения называется
прямо: пропущенная работа на этой неделе не восполняется ничем.

Три случая, которые из этого следуют:

- **Пропущен день другого типа.** Для мышц оставшегося дня не меняется ничего:
  доля дня верха в ведущей мышце дня низа равна нулю, и слагаемое, которое
  «ушло» из знаменателя, там и не стояло. Теряет только ведущая мышца
  пропущенного дня.
- **Пропущен последний день недели.** Пересобирать нечего: оставшихся сессий
  нет, `S_эфф` пересчитывать не для кого. Триггер срабатывает и не даёт
  изменения.
- **Пропуск через границу недели.** Долг не переносится: `S_эфф` следующей
  недели считается от её собственной сетки и её собственной нормы. Переносятся
  только утомление (§8.1) и детренированность (§9.7) — обе по истории
  тренировок, и ни одна не возвращает недоданные подходы: утомление после
  пропуска ослаблено, и оставшиеся дни получают больше объёма, но не выше своей
  плановой цели, а детренированность действует в другую сторону и опускает
  базовые веса.

**Будущие дни — от замороженного состояния.** Пользователь видит содержимое всех
оставшихся дней недели, а строк `workouts` у них нет: тренировка появляется при
старте (§3.1). Каждый не начатый день собирается §7.3 от того, что известно
сейчас, без прогноза того, что будет сделано до него:

- утомление (§8.1) — только от выполненных подходов, с распадом до 12:00 этого
  дня по местному времени; запланированные, но ещё не выполненные дни до него
  утомления не добавляют;
- `неделя[m]` — та же свёртка по выполненным подходам (§7.3);
- «предыдущая тренировка» слагаемого w6 — последняя выполненная;
- готовность — §10 от состояния цикла на дату этого дня (§11.3, по отметкам,
  известным сейчас), без check-in и без оверрайда: у будущего дня их ещё нет, а
  оверрайд живёт один день (§11.4). Из того же состояния — плановый срез объёма
  и тип блока (§11.2).

Сегодняшний день, пока не начат, собирается так же, но со своими check-in и
оверрайдом. Идемпотентность пересборки (§7.1, §7.3) это не задевает: вход
будущего дня меняют только события — выполненная тренировка, пропуск, отметка
цикла, смена инвентаря, — а не течение времени внутри дня.

**Момент оценки утомления — 12:00 дня**, один и тот же для сегодняшнего и
будущих дней. Текущее время не годится: пересборка того же дня в 9:00 и в 18:00
дала бы разные тренировки. Начало дня (00:00) завышает утомление на
восемнадцать часов распада против тренировки в 18:00, и неделя пн / ср / пт
выходит заметно легче: в прогоне full body ×3 даёт бицепсу бедра 6.0 против 9.0,
низ / верх ×2 — ягодичным 14.1 против 16.0. Полдень совпадает с тренировкой в
18:00 по недельному объёму в пяти неделях из шести; расходится только при пяти
днях подряд (ягодичные 16.5 против 15.7, квадрицепс 10.7 против 12.7). Типичное
время тренировок пользователя было бы точнее, но требует истории, которой у
нового пользователя нет, и отдельного правила её счёта.

Цена называется прямо: при нескольких днях одной зоны подряд будущий день в
предпросмотре выглядит тяжелее и однообразнее, чем выйдет, — утомление и w6 от
ещё не выполненных тренировок в нём не учтены. В прогоне (пять дней «низ с
акцентом» подряд, 45 минут) предпросмотр понедельника показывает на все пять
дней одну и ту же тренировку, а фактический состав отличается от него в четырёх
днях из пяти. Поэтому **выполненная тренировка — триггер пересборки** оставшихся
дней, и строка «План обновлён» после неё печатается по общему правилу — только
если изменился состав или объём: при пяти днях подряд — после каждой
тренировки, в неделе пн / ср / пт — один-два раза за неделю.

Засчитывать запланированные дни выполненными (прогноз по цепочке) сделало бы
предпросмотр точнее, но записало бы в расчёт фидбэк, которого не было, и
расходилось бы с фактом при каждом отклонении. Не собирать будущие дни вовсе
нельзя: строка недобора по времени (ниже) суммирует именно не начатые сессии.

**Правило прозрачности:** любая пересборка сопровождается одной строкой
объяснения на экране «Сегодня»: «План обновлён: началась менструальная фаза,
объём на эту неделю снижен». Молчаливая пересборка недопустима — она
воспринимается как баг.

**Пересборка, которая ничего не изменила, строки не печатает.** «План
обновлён» — утверждение об изменившемся составе или объёме оставшихся дней; над
неизменившимся планом оно ровно такой же баг, как молчаливое изменение. Пропуск
попадает сюда постоянно: пропущенный день верха не двигает в дне низа ни одного
подхода.

**Статус недели — отдельная строка, не «План обновлён».** То, что неделя выйдет
легче запланированного, — правда о неделе, а не об изменении плана, и смешивать
их нельзя: «План обновлён» отвечает на вопрос «почему сегодня другое», статус
недели — на «почему за неделю выйдет меньше». Потеря считается по тому же
инварианту §7.3 и выражается в подходах:

```
потеря[m] = Σ по ПРОПУЩЕННЫМ сессиям (S_эфф(сессия) × доля_сессии[m])
```

«На этой неделе выйдет на 8 подходов меньше по ягодичным: вторник пропущен».
Строка показывается, только когда есть что сказать: потеря округляется до
целого, и при нуле строки нет — пропуск дня верха по ягодичным не теряет ничего.

**Недобор по времени — вторая причина, и называется она отдельно.** Короткий
`session_minutes` срезает объём у мышц, которые не поместились (§7.3), и неделя
выходит легче плана без всякого пропуска. Считается разницей со сборкой, которой
время не мешало:

```
недобор[m] = Σ по НЕ НАЧАТЫМ сессиям недели max(0, факт_без_бюджета[m] − факт[m])
```

`факт_без_бюджета` — та же сборка §7.3 с тем же входом и тем же seed, но без
ограничения `session_minutes`; у не начатых дней обе сборки — от замороженного
состояния (выше). Округление и порог — те же, что у пропуска.
«До конца недели выйдет на 8 подходов меньше по широчайшим: в 45 минут не
помещается».

С пропуском строки не сливаются по той же причине, по которой различаются
`ReasonCode` ослабления паттернов (§7.3): пропуск уже случился, а недобор по
времени меняется одним тапом по `session_minutes`.

**Почему разница со сборкой без бюджета, а не с планом.** Сравнение с
`S_эфф × доля` печатало бы строку почти каждую неделю: целые подходы и минимум
два на упражнение расходятся с дробной целью на полтора подхода и тогда, когда
время ни при чём (прогон: день «низ с акцентом» при 60 минутах — квадрицепс 7.0
против 7.2, приводящие 1.3 против 2.4). Сборка без бюджета при неограничивающем
бюджете совпадает с настоящей, и недобор ровно ноль: в прогоне строки нет у дня
«низ с акцентом» при 60 и 45 минутах и у full body 3 дня × 60 минут; при 2 днях
× 45 минут у full body из десяти мышц по 0.10 — широчайшие −8, средние дельты −8,
трицепс −6.

Выполненные сессии в недобор не входят: пересобрать их без бюджета нельзя —
нужен вход того дня (утомление, готовность), которого уже нет, та же причина, по
которой хранится `weight_readiness` (§7.6).

**Правило неприкосновенности:** уже начатая тренировка никогда не
пересобирается. Прошедшие дни не трогаются.

### 7.2 Генерация недельной сетки

Вход: `days_per_week`, конкретные дни недели, `experience_level`.

**Конкретные дни живут в `profiles.training_weekdays`** (§3.1): ISO-номера
1–7, 1 — понедельник, набор отсортирован и без повторов. Собирает их онбординг
(§5, шаг 6), а не тело запроса на генерацию: выбор принадлежит аккаунту, и
второй клиент (iOS, §20.3) обязан получить ту же сетку, не спрашивая заново.
Уникальность проверяется схемой, а не подразумевается: расстановка работает с
множеством дат, и набор `{2,2,4}` при `days_per_week = 3` дал бы два дня вместо
трёх — молча и с другими типами дней.

Цель, фаза, утомление и объём прошлых недель в расстановку не входят. Цель
действует через повторы и RIR (§9.1), остальные — при сборке тренировки (§7.3):
фаза — через плановый срез и штрафы score, утомление — через `volumeFactor` и w5,
выполненный объём — через `неделя[m]`. Поэтому смена фазы и пропуск пересобирают
содержимое дней, а не их типы (§7.1).

Правила расстановки:

- 1–2 дня → full body
- 3 дня → новичок: full body ×3; средний и опытный: верх / низ / full body
- 4 дня → верх/низ ×2
- 5 дней → верх / низ / верх / низ / full body
- 6 дней → пуш / пул / ноги / верх / низ + растяжка
- 7 дней → пуш / пул / ноги ×2 + растяжка

«Ноги» — `session_kind = lower`, отдельного типа нет (§3.1). Растяжка входит в
`days_per_week`: шесть дней — это пять силовых и растяжка. Типы назначаются
выбранным дням недели в календарном порядке в том порядке, в каком перечислены;
растяжка — последний выбранный день.

Особого акцентного дня нет: акцент выбирается по дням (ниже), и отдельный тип дня
под него не нужен.

**Интервал между тренировками одной зоны сетка не проверяет.** Недовосстановление
уже учитывают модель утомления (§8.1, §8.2) и слагаемое w5 (§7.3); второе правило
о том же дублировало бы их. Как это выглядит на пятом дне ягодиц подряд — §8.3.

**Акцент выбирается по дням, не сеткой.** Сетка ставит
`planned_days.accent_muscle = null`, акцент дню ставит пользователь (§1.1). Пока
акцент не выбран, день собирается по вектору без акцента, и акцентная колонка
§7.4 в нём не действует — даже для мышцы, которая акцентная в другой день недели:
колонка выбирается по сессии (§7.3). Дефолтные акценты §1.2 — то, что интерфейс
предлагает первым, а не значение, которое сетка ставит сама. Выбор или снятие
акцента — плановое решение (§7.3): меняются вектор дня и знаменатель `S_эфф`
недели.

Пользователь может в любой день заменить тип тренировки. Планировщик принимает
это и перебалансирует остальное.

### 7.3 Сборка конкретной тренировки

Задача: выбрать набор упражнений и объём так, чтобы вектор недельного объёма по
мышцам приблизился к целевому, при жёстких ограничениях.

**Единица объёма — эффективный подход (§7.4).** В ней считаются и доли целевого
вектора, и нормы §7.4, и все слагаемые целевой функции. Утомление (§8.1)
по-прежнему считается по сырым вкладам: это разные величины с разными шкалами, и
сводить их в одну нельзя.

**Целевой вектор — вход, а не константа спеки.** Вектор задаётся парой (тип дня,
акцент); доли — от эффективного объёма сессии. Таблица векторов — контент: живёт
в `FitContent` рядом с библиотекой, размечается на этапе 2 (§17), и планировщику
её передаёт вызывающая сторона — как срез упражнений (§7.5). Два вектора ниже —
примеры формы, на которых откалиброван этот раздел, а не таблица. Пример «низ
тела, акцент ягодицы»:

```
glute_max   0.40
hamstrings  0.20
quads       0.18
glute_med   0.10
adductors   0.06
calves      0.06
```

Тот же «низ» без акцента:

```
quads       0.30
glute_max   0.25
hamstrings  0.25
glute_med   0.08
adductors   0.06
calves      0.06
```

**Правила, которым обязан любой вектор:**

1. Слаги мышц — из §6.4, доли неотрицательны, сумма ≈ 1.0, как у
   `muscle_contributions` (§6.3).
2. У вектора с акцентом доля акцентной мышцы — наибольшая. Ведущая мышца дня —
   акцентная, и `S_эфф` делит норму на её долю (ниже): при доле меньше чужой
   сессия масштабировалась бы от мышцы, которая в ней не главная.
3. Ключ — пара (тип дня, акцент), и вектор для пары задаётся целиком. Правила
   «акцент преобразует базовый вектор» нет, и опубликованная пара показывает
   почему: пропорциональное масштабирование остальных при подъёме `glute_max`
   до 0.40 дало бы `quads` 0.24, `glute_med` 0.064, `adductors` и `calves` 0.048
   вместо 0.18, 0.10, 0.06, 0.06. `glute_med` с акцентом на ягодицы растёт, чего
   убывающее масштабирование не даёт в принципе; воспроизвело бы пару только
   правило, знающее синергистов акцентной мышцы, — иерархия мышц, которую §6.4
   отвергает.
4. Для каждой пары, которую может дать сетка §7.2 вместе с выбором акцента,
   вектор есть, а его мышцы покрыты упражнениями на каждом уровне инвентаря
   (§17). Отсутствие — ошибка разметки; ловит её валидатор (§19.1), а не
   планировщик.

Планировщик от конкретных чисел не зависит: `S_эфф`, цель и все слагаемые score
определены для любого вектора, который выполняет эти правила, и тестируется он
на синтетических векторах. Ширина вектора при этом не нейтральна: на плоском
векторе full body короткий бюджет обнулял целые мышцы на всю неделю, и против
этого стоит слагаемое w11 (ниже).

**Объём сессии.** Вектор задаёт форму, §7.4 — масштаб:

```
норма-старт(m, сессия) = нижняя граница §7.4: колонка «акцентная», если m — акцент
                         ЭТОЙ сессии, иначе «базовая»
потолок(m, сессия)     = верхняя граница §7.4 из той же колонки
ведущая мышца дня = акцентная; без акцента — мышца вектора с наименьшим
                    норма-старт(m, сессия) / Σ доля_сессии[m] по ЗАПЛАНИРОВАННЫМ сессиям недели
S_эфф   = норма-старт(ведущая мышца, сессия) / Σ доля_сессии[ведущая]
                                                по ЗАПЛАНИРОВАННЫМ сессиям недели
цель[m] = S_эфф × доля[m] × volumeFactor(плановый срез, утомление m)        // §10
```

`volumeFactor` — композиция §10 (`Readiness.volumeFactor`), а не своя формула:
плановый срез (фаза либо разгрузочная неделя) и утомление не перемножаются.

**Ведущая мышца дня без акцента — та, что даёт наименьший масштаб.** Прежнее
определение, «мышца с наибольшей долей вектора», у плоского вектора не выбирало
ничего: долей 0.10 у full body десять. В однородной неделе это безвредно — у всех
претендентов один масштаб, — но в смешанной знаменатель складывает долю мышцы по
всем дням, и выбор становится масштабом. В неделе верх / низ с акцентом / full
body `S_эфф` дня full body при разных «наибольших» мышцах — от 20.0 (ягодичные)
до 100 (пресс, который есть только в этом дне): разброс в пять раз от порядка
слагов в векторе. Минимум `норма / Σ долей` за неделю от порядка не зависит —
равные значения дают один и тот же масштаб, — и в однородной неделе совпадает с
прежним определением: норма у мышц без акцента одна, и минимум приходится на
наибольшую долю. В этой неделе full body получает 20.0: ведут ягодичные — их
доля за неделю больше всех, а норма в дне без акцента базовая (ниже, «Колонка
§7.4 — по сессии»).

**День с акцентом ведёт акцентная мышца, без минимума.** Минимум и там не дал бы
ни одной мышце выйти за норму, но заплатил бы акцентом: в неделе «низ с акцентом +
низ без акцента» (ниже) ведущей дня с акцентом стал бы квадрицепс — 20.83 вместо
24.62, — и `glute_max` за неделю упал бы с 13.69 до 12.18, а квадрицепс — с 9.05
до 8.37: минимум срезал бы весь акцентный день и не дал бы ничего ни одной мышце.
Акцент — причина, по которой продукт существует (§1.3).

**Колонка §7.4 — по сессии.** Акцентная колонка — и норма, и потолок — действует
только в дне, где мышца акцент. В остальные дни у той же мышцы базовая колонка,
даже если в другой день недели она акцентная: акцент — решение пользователя о
конкретном дне (§7.2), и распространять его на соседние дни значило бы отдать
дню без акцента объём, которого там не выбирали. Потолок сверяется с недельной
суммой `неделя[m] + факт[m]` по колонке ТЕКУЩЕЙ сессии — и в цели, и в слагаемом
w2.

Цена — в смешанных неделях. День без акцента часто ведёт мышца, акцентная в
другой день: сумма её долей за неделю наибольшая, а норма в этот день базовая, —
и масштаб всего дня падает. Прогон, средний уровень:

| Неделя | `S_эфф` дня без акцента | `glute_max` / квадрицепс за неделю (план) |
|---|---|---|
| низ с акцентом + низ | 15.38 (ведёт `glute_max`) против 20.83 (квадрицепс) при общей колонке на неделю | 13.69 / 9.05 против 15.05 / 10.68 |
| верх / низ с акцентом / full body | full body 20.0 (`glute_max`) против 28.6 (широчайшие) | 14.80 / 7.76 против 15.66 / 8.62; широчайшие 9.14 против 10.00 |

В сборке (тринадцать смешанных недель низа и верха / низа / full body, 60 и 45
минут) колонка объём скорее перераспределяет, чем срезает: недельный `glute_max`
меняется от −1.6 до +1.0 подхода, квадрицепс — от 0 до −2.0, бицепс бедра — от
+0.6 до −2.0; рост — в неделях, где дней с акцентом больше, чем без него. Потолок
по сессии в двенадцати неделях при 20–60 минутах цель не срезал ни разу: деление
нормы между сессиями и так держит недельный объём у нормы, и вся разница — от
колонки нормы. Однородные недели не меняются: у них одна колонка на все дни.

Делится на сумму долей за неделю, а не на число сессий: недельная норма ведущей
мышцы распределяется между сессиями пропорционально тому, сколько каждая из них
этой мышце отводит. Отсюда следствие, которое и требовалось §7.4: суммарный
недельный объём не зависит от числа тренировок одного типа. Пять дней ягодиц
подряд дают ту же неделю, что два (прогон на синтетике: 17.5 против 16.6
эффективного подхода на `glute_max` при потолке 20).

**Знаменатель — запланированные сессии недели, а не оставшиеся.** В сумму входят
все дни сетки (§7.2) со своим типом и акцентом, независимо от того, выполнены
они, пропущены или ещё впереди: `planned_days` недели любого `status` (§3.1).
Отсюда инвариант, которым §7.1 и закрывает «не догоняется компенсаторно»:

```
неделя[m] = Σ по ВЫПОЛНЕННЫМ сессиям (S_эфф(сессия) × доля_сессии[m])
```

Каждая выполненная сессия отдаёт ровно ту долю недельной нормы, которая была ей
запланирована, а пропущенная — ноль; чужую долю не получает никто.

Когда ведущая мышца и норма у сессий недели одни и те же — обычный случай, ради
которого формула и писалась, — это сворачивается в короткую форму «норма,
умноженная на долю выполненного»: при норме 16 одна выполненная сессия из двух
даёт 8.00 эффективного подхода на `glute_max`, две из трёх — 10.67, три из
пяти — 9.60. Короткая форма — следствие, а не определение: в смешанной неделе
(день низа с акцентом плюс день низа без акцента) у сессий разные нормы,
полностью выполненная неделя даёт 13.69 подхода на `glute_max` вместо 16, и верна
там только длинная форма. Знаменатель по ОСТАВШИМСЯ сессиям вместо
запланированных даёт на однородной неделе 16.00 в одной тренировке —
компенсаторный догон, запрещённый §7.1.

**Плановые решения меняют знаменатель, факты исполнения — нет.** Меняют: смена
типа дня или акцента пользователем (§7.1, «учёт в объёме») и перегенерация
сетки. Не меняют: пропуск, оверрайд `rest` (§11.4), незавершённая тренировка.
Правило одно на все три, и иначе быть не может: «догонять нечем» (§7.1) сказано
про потерянный день, а потерян он одинаково — пропустили его или заменили
растяжкой.

`S_эфф` нигде не хранится и пересчитывается при каждой пересборке: это чистая
функция от сетки недели, уровня и нормы ведущей мышцы. Пропуск меняет `status`
строки, а не состав строк, поэтому пересчёт после пропуска возвращает то же
число — требование §7.1 «пересборка с неизменившимся входом возвращает ту же
тренировку» выполняется без отдельного механизма. Хранимое значение было бы
вторым источником истины, который протухает ровно на том событии, которое его
законно меняет.

**Норма — ориентир, а не обязательство.** `S_эфф` считается от нормы §7.4 без
поправок, а всё, что применяется дальше, двигает фактический недельный объём в обе
стороны: плановый срез фазы или разгрузочной недели (§11.2), утомление по мышце
(до ×0.7, §8.2), потолок §7.4 сверху и округление до целых подходов с минимумом
два на упражнение снизу. В прогоне — 16.6 против нормы 16 в обычную неделю
(округление вверх), 17.5 за пять дней ягодиц подряд, 21.8 при потолке 20.
Отклонение и есть работа этих правил: фазовый срез затем и существует, чтобы
менять недельный объём. Гарантировать норму можно было бы только догоном
недоданного, а §7.1 его прямо запрещает.

**Освободившийся объём перераспределяется** (§8.3, п.4). Всё, что срезано у мышцы
утомлением или упёрлось в её недельный потолок, раскладывается по мышцам вектора
без утомления — пропорционально их долям и не выше их остатка до потолка. Иначе
«пятый день ягодиц подряд» давал бы вырожденную тренировку там, где §8.3 требует
перенести работу на восстановившиеся синергисты.

**Бюджет времени — потолок, а не цель.** Тренировка бывает заметно короче
`session_minutes`: при нормах §7.4 средний уровень на дне «низ с акцентом ягодицы»
набирает 11 подходов и 24 минуты из шестидесяти (прогон). Дотягивать объём до
времени нельзя — это ровно тот перебор, от которого стоит потолок §7.4.

**Расчётное время.**

```
работа(упр) = 40 с × (unilateral ? 2 : 1)
отдых(упр)  = default_rest_seconds × restFactor
restFactor  = readiness < 0.9 ? 1.2 : (readiness > 1.05 ? 0.8 : 1.0)      // §13.3

время = Σ по упражнениям (setup_seconds + подходы × работа + подходы × отдых)
        − отдых(последнего упражнения по порядку сессии)
```

Отдых считается после КАЖДОГО подхода, включая последний подход упражнения: он и
есть переход к следующему, а `setup_seconds` следующего ложится поверх него — так
переход стоит `отдых + setup`, а не одно из двух. Отдых после последнего подхода
ТРЕНИРОВКИ не считается: тренировка на нём заканчивается. Какое упражнение
последнее, определяет порядок сессии («Порядок упражнений» ниже), а он — чистая
функция от набора, поэтому время определено и на жадном шаге, до того как порядок
проставлен.

**Работа в подходе — константа, не функция повторов.** 40 с — это десять повторов
по четыре секунды или тринадцать по три, середина того, что дают диапазоны §9.1.
Формула от повторов была бы честнее, и `target_rep_min`/`target_rep_max` уже
определены (§9.1), но диапазон ещё не окончательный: суженный диапазон §9.5 не
сохраняется, фазовые диапазоны §11.2 не применяются, а переход на повторы изменил
бы проверенные прогоном числа сценария 29. Она тянула бы и `rep_extension` (§9.5):
пользователь на `rep_max + 4` делает заметно более долгий подход. **Когда §9.5
закроется, сюда вернуться:** работа станет функцией назначенного диапазона.

**Односторонние удваивают работу, но не отдых.** Стороны выполняются подряд,
полного отдыха между ними не бывает. Учёт объёма это не задевает: подход остаётся
одним подходом, и в эффективных подходах (§7.4) это уже верно — односторонний
подход даёт каждой стороне столько же, сколько двусторонний даёт обеим.
Удваивается только время: в десять минут помещается четыре подхода одностороннего
упражнения против шести двустороннего с тем же `setup_seconds` (прогон).

**Множитель отдыха — ступенька на порогах готовности §10**, тех же, что у ±1
подхода на сессию: ниже 0.9 — ×1.2, выше 1.05 — ×0.8, границы строгие. Новых
порогов не вводим. Непрерывная поправка здесь хуже: готовность живёт в
[0.75, 1.10], диапазон несимметричный, и линейный множитель до −20% не дошёл бы
никогда. Бюджет и таймер отдыха (§13.3) читают одно и то же число.

**Внутрисессионные поправки в бюджет не входят.** Надбавка за «тяжело» (+30 с),
кнопка «+30 сек» и досрочно пропущенный таймер (§13.3) на момент сборки
неизвестны. Бюджет — оценка плана, а не обещание по настенным часам; расхождение
с фактической длительностью ожидаемо и починки не требует.

**Разминка и заминка в `session_minutes` не входят.** Динамическая мобильность
(§12.1) — 5–8 минут перед первым упражнением, автозаминка (§12.2) — после
последнего; обе предлагаются и пропускаются одним тапом, поэтому заранее
неизвестно, состоятся ли они, и резервировать под них бюджет нельзя: шесть минут
из двадцати оставляют два упражнения и два паттерна, то есть сценарий 29 (§18)
перестаёт выполняться. `session_minutes` — бюджет силовой части. Чтобы обещание
не расходилось с тем, что пользователь видит, разминка показывается явной
надбавкой: «+5–8 минут разминки» рядом с длительностью тренировки (§13.1, §13.2).

**Ограничения (жёсткие):**

- Только упражнения, выполнимые на текущем инвентаре: каждое требование
  `equipment` выполнено и лестница веса не пуста (§6.6)
- Исключены упражнения, конфликтующие с активными травмами
- Исключены упражнения с активным флагом боли (§8.4)
- `skill_level` ≤ уровня пользователя
- Минимум 3 разных `pattern` — среди упражнений, работающих хотя бы на одну мышцу
  вектора дня. Без этой оговорки правило закрывается упражнением мимо цели: в
  прогоне в день низа с травмой колена пролезала тяга в наклоне, потому что
  «третий паттерн» ей засчитывался, а к цели дня она не добавляла ничего
- Суммарное расчётное время ≤ `session_minutes`
- Не более 2 упражнений из одной `progression_family`
- Недельная цель мышцы не выше её потолка §7.4

**Когда ограничения несовместимы.** Безопасность — инвентарь, травмы, флаги боли,
`skill_level` — не ослабляется никогда. Ослабляется требование трёх паттернов, и
по двум разным причинам: столько паттернов не **доступно** (травма, инвентарь)
либо столько не **влезает** в `session_minutes`. Время не превышается ни в том, ни
в другом случае: оно ослабляет паттерны, а не ослабляется само.

Наружу идёт `ReasonCode` с указанием причины — для пользователя это разные вещи:
«на вашем инвентаре других движений нет» она изменить не может, а «в двадцать
минут больше не помещается» меняется одним тапом по `session_minutes`. Молчаливое
сведение обеих причин к одной строке отняло бы у неё этот тап.

Сценарий 30 (§18) — первый случай: при травме колена на низ остаются только
шарнирные и изоляция, и тренировка собирается из них. Сценарий 29a — второй: при
четырнадцати минутах собираются два упражнения и два паттерна, при восьми — одно
упражнение и один; тренировка при этом не пуста и в бюджет укладывается.

**Целевая функция (мягкая).** Все слагаемые — штрафы в эффективных подходах,
идеальная сборка даёт 0:

```
score = − w1  · Σ по мышцам      |факт[m] − цель[m]|
        − w2  · Σ по мышцам      max(0, неделя[m] + факт[m] − потолок[m])
        − w3  · Σ по паттернам   max(0, упражнений с этим паттерном − 2)
        − w4  · Σ по упражнениям (базовой линии нет ? 1 : 0)
        − w5  · Σ по упражнениям подходы · Σ по мышцам вклад[m] · fatigue_cost · утомление[m]
        − w6  · Σ по упражнениям (было в предыдущей тренировке ? 1 : 0)
        − w7  · Σ по упражнениям |Cycle.exerciseBias|            // §11.2, уже × cycleConfidence
        −       Σ по упражнениям min(w8 · block_mismatch + w9 · complexity_at_low_readiness,
                                     max(w8, w9))
        − w10 · Σ по упражнениям (упражнение «на поддержании» ? 1 : 0)      // пока 0: §9.5, пп.3–4
        − w11 · Σ по мышцам вектора (доля[m] / max доля)³ · max(0, 1 − неделя[m] − факт[m]) / оставшихся[m]

утомление[m] = (1 − volumeMultiplier[m]) / 0.3     // §8.2; 0 у свежей мышцы, 1 у невосстановленной
оставшихся[m] = сессий недели от текущей включительно, в векторе которых есть m
```

`неделя[m]` — **свёртка по фактически выполненным подходам** тренировок текущей
недели со `status = done`, в эффективных подходах (§7.4). Не инкремент:
собранный, но ещё не выполненный план в неё не входит, включая план сегодняшнего
дня. Иначе повторная пересборка того же дня — а их за день бывает несколько
(смена фазы, пропуск, смена инвентаря) — считала бы собственный результат второй
раз и с каждым разом резала бы сессию: в прогоне при потолке 20 и
`неделя[m] = 17` первая сборка берёт три подхода, вторая уже ноль. Это тот же
класс ошибки, что двойной учёт закрытия цикла (§11.5), но закрывается он здесь
иначе — не отметкой учёта, а тем, что величина производная: пересчёт из
состояния идемпотентен по построению, и хранить «какие пропуски уже учтены» не
нужно, потому что учитывать нечего. Считается по ключу тренировки, чтобы
повторная доставка события (§4.3) и записи с двух устройств (§18, сценарий 37)
не дали одну сессию дважды.

**У пары w8/w9 потолок стоит внутри суммы — на уровне одного упражнения.** Это
единственное слагаемое с такой структурой, и она не косметическая: потолок после
суммирования ограничивал бы всю тренировку, и сборка из пяти упражнений, каждое из
которых блоку не подходит, штрафовалась бы на те же 0.5 — по одной десятой подхода
на упражнение, то есть правило исчезло бы. Потолок защищает от двойного счёта по
ОДНОМУ упражнению (фазовый приоритет и низкая готовность говорят о нём одно и то
же), а не ограничивает, сколько таких упражнений может быть в тренировке. У
остальных слагаемых вес вынесен за знак суммы, и ограничения сверху у них нет.

**Только штрафы, без бонусов.** Слагаемое-бонус за упражнение выгодно набирать,
добавляя упражнения сверх объёма: прогон с бонусами за разнообразие, знакомость и
приоритет блока раздувал сборку до семи упражнений в менструальную фазу — ровно
там, где объём обязан падать. У штрафной формы нулевой score означает «объём лёг
точно в цель, и ни одно упражнение не вызывает возражений».

`distance` считается по объединению мышц: у мышцы вне вектора дня цель равна нулю.
Иначе упражнение, не работающее на мышцы дня, ничего не стоит и берётся ради
разнообразия. Побочные вклады базовых упражнений при этом остаются дешёвыми
(разгибатели в тяге на прямых ногах — 0.2 подхода), а упражнение целиком мимо дня
— дорогим (тяга в наклоне в день низа — 2.2).

| Вес | Значение | Курс обмена |
|---|---|---|
| w1 | 1.0 | единица шкалы: один эффективный подход мимо цели |
| w2 | 2.0 | подход сверх недельного потолка стоит как два мимо цели |
| w3 | 0.5 | третье упражнение одного паттерна |
| w4 | 0.5 | упражнение без базовой линии уступает знакомому при разнице до 0.5 |
| w5 | 2.0 | подход по полностью утомлённой мышце с `fatigue_cost` 1.0 |
| w6 | 0.5 | упражнение из вчерашней тренировки уступает при разнице до 0.5 |
| w7 | 3.0 | прыжковое при полной уверенности уступает при разнице до 0.9 |
| w8 | 0.5 | нежелательное для типа блока (§11.2) |
| w9 | 0.5 | технически сложное при готовности < 0.85 |
| w10 | 1.0 | упражнение «на поддержании» уступает альтернативе при разнице до 1.0; пока не действует (§9.5, пп.3–4) |
| w11 | 5.0 | мышца вектора без единого эффективного подхода за неделю — до пяти подходов мимо цели на её последней сессии недели |

Литературных значений у весов нет и быть не может: это курсы обмена между целями
подбора, а не измеримые величины. Каждый проверен прогоном на синтетических
упражнениях (§18, сценарии 27–33):

- **w2 = 2.0** — плато: выше поведение не меняется. При `glute_max` 19 из 20
  остаток перебора структурный (квадрицепс и бицепс бедра не нагрузить, не задев
  ягодичные), итог недели 21.8 против потолка 20 при любом w2 ≥ 2.
- **w5 = 2.0** — при 0.5 правило §8.3, п.3 не работает вовсе, при 1.0 включается
  только на «мышца не восстановлена», при 2.0 — уже на частичном утомлении, как и
  непрерывный срез объёма §8.2. Проверено парой упражнений одной семьи, которые
  различаются только `fatigue_cost` (1.0 против 0.7).
- **w7 = 3.0** — `exerciseBias` даёт до 0.3, значит максимум штрафа 0.9. Прыжковое
  упражнение уходит, когда есть замена того же паттерна, и остаётся, когда её
  нет: фаза остаётся мягким штрафом, а не фильтром (§11.2).
- **w11 = 5.0** — первое значение, при котором покрытие почти полное.
  Восемнадцать недель на синтетике (три вектора full body по 8–10 мышц, 2 и 3
  дня, 45 / 30 / 20 минут): мышце-недель без единого эффективного подхода при
  w11 = 0 — 36, при 1 — 7, при 2 — 5, при 3 и 4 — 3, при 5 — 1, дальше 0–2 без
  тренда (жадный отбор). При 8 остаётся 0, но акцент в смешанных неделях теряет
  больше: ягодичные суммарно −3.0 против −0.7 при 5.

**Слагаемое покрытия w11.** Без него короткий бюджет на широком векторе обнуляет
одни и те же мышцы каждый день недели: при 2 днях × 45 минут — это дефолт
`session_minutes`, а §7.2 даёт 1–2 дням full body — вектор из десяти мышц по 0.10
получал за неделю ноль на широчайшие, средние трапеции и средние дельты, 30%
вектора. Минимум паттернов этого не ловит — он ни разу не ослаблялся. Причина —
в `distance` по объединению мышц: у базовых упражнений на низ синергисты сами в
векторе, у базовых на верх побочные вклады уходят в дельты, трицепс и бицепс вне
вектора и штрафуются, и при нехватке времени верх проигрывает. Вход каждый день
одинаковый, и w6 недостаточно, чтобы менять состав. Для сравнения: «низ с
акцентом» при 20 минутах теряет только икры, 6% вектора.

Форма слагаемого выбрана прогоном:

- **Порог — один эффективный подход.** Слагаемое отвечает на «мышца на этой неделе
  не получила ничего», а не «получила меньше плана»: объём оно не добавляет, это
  работа цели и w1.
- **Вес — куб доли мышцы относительно наибольшей в векторе.** Без веса w11 = 3
  заставлял день «низ с акцентом» при 30 минутах брать икры с долей 0.06 и ронял
  `glute_max` за неделю с 16.0 до 14.1 — акцент, ради которого продукт существует
  (§1.3). Линейный вес чинил однородную неделю (15.7), но не смешанную: икры есть
  только в дне низа, там у них последняя сессия недели, и при 30 минутах они
  вытесняли отведение из акцентного дня во всех четырёх прогнанных порядках дней.
  Вытеснений мышцей с долей 0.06 из акцентного дня при 30 и 20 минутах (две
  однородные недели и восемь смешанных): линейный вес — 4 из 10, квадрат — 1,
  куб — 0; ягодичные в смешанных неделях суммарно −2.8 при линейном, −1.8 при
  квадрате и −0.7 при кубе. В однородной неделе «низ с акцентом» недельный
  `glute_max` при кубе тот же, что без w11, при любом бюджете: 16.0 при 60, 45 и
  30 минутах, 10.1 при 20.
  На плоском векторе все отношения равны 1, и степень ничего не меняет. Цена:
  икры могут остаться за неделю без работы, что и требовалось, а на векторе с
  долями 0.15 / 0.10 при 2 днях × 20 минут остаётся с нулём пресс.
- **Деление на `оставшихся[m]`.** Пока у мышцы есть ещё сессии на неделе, штраф
  мягкий, на её последней — полный. В однородной неделе при кубе деление ничего не
  меняет; в смешанной при 20 минутах без него акцент теряет больше в двух порядках
  дней из трёх: ягодичные 5.5 против 6.2 и 4.3 против 5.9; в третьем поровну, 5.5.

Что слагаемое не делает, называется прямо. Оно меняет, **какие** мышцы получают
работу при нехватке времени, а не сколько: у того же вектора при 2 днях × 45
минут широчайшие получают 2.0 эффективного подхода против плановых 10, и
недобор остаётся — его показывает строка статуса недели (§7.1). На пределе оно
покупает ширину глубиной: при 2 днях × 20 минут квадрицепс за неделю — 3.0 вместо
7.0, бицепс бедра — 2.0 вместо 5.0, зато ни одна мышца верха не остаётся с нулём.

Это не догон, запрещённый §7.1: `S_эфф` и `цель[m]` слагаемое не трогает, а после
пропуска меняется только состав оставшихся дней — ровно то, что §7.1 и разрешает
перебалансировать. `неделя[m]` — свёртка по выполненным подходам, поэтому
слагаемое идемпотентно при повторной пересборке дня так же, как w2.

**Смешанные недели** (верх / низ с акцентом / full body в трёх порядках и
верх / низ / full body / низ; 60, 45, 30, 20 минут; `оставшихся[m]` — по сессиям,
в векторе которых мышца есть; ведущая мышца дня без акцента — по правилу «Объём
сессии» выше). При 60 и 45 минутах недельный `glute_max` не меняется ни в одном
случае, а мышц с нулём за неделю не становится больше. При 30 и 20 минутах
слагаемое по-прежнему покупает ширину глубиной и иногда — за счёт акцента: день
full body при нехватке времени отдаёт ягодичные мышцам с той же долей 0.10
(пресс, дельты), которые иначе остались бы с нулём. Ягодичные за неделю при 30 и
20 минутах: 10.0 → 9.7 и 5.9 → 6.2 (верх / низ / full body), 10.0 → 9.7 и
5.9 → 5.5 (full body / верх / низ), 10.0 → 9.7 и 5.9 → 5.9 (низ / full body /
верх), 15.1 → 15.1 и 12.9 → 13.2 (четыре дня). Это не вытеснение малой долей, и
степень его не лечит: у плоского вектора все отношения долей равны.

**Потолок на сумму w8 + w9.** Поздняя лютеиновая фаза и сама просит тренажёры
вместо технически сложной базы, и роняет готовность, из-за которой то же правило
срабатывает второй раз: причина одна. Их сумма ограничена большим из двух весов —
то же правило и тот же довод, что у RIR (§10, «сумма, ограниченная сверху +1»):
сумма, а не максимум, чтобы разнонаправленные вклады не стирали друг друга, и
потолок, чтобы одна причина не считалась дважды.

«Технически сложная база» — упражнение с `pattern` из `squat`, `hinge`, `lunge`,
`push_h`, `push_v`, `pull_h`, `pull_v` и `skill_level` выше `novice`. «Тренажёры»
из §11.2 — `load_type` `machine` или `cable`. Порог низкой готовности для w9 —
0.85, тот же, за которым §10 поднимает RIR: нового порога не вводим.

`block_mismatch` — что именно тип блока (§11.2) предпочёл бы не давать:

| Тип блока | Штраф 1 получает |
|---|---|
| Восстановительный (менструальная) | технически сложная база |
| Силовой (фолликулярная) | изоляция |
| Пиковый (овуляторная) | — ударная нагрузка идёт отдельным слагаемым w7 |
| Объёмный (ранняя лютеиновая) | — влияет на подходы и диапазоны, не на подбор |
| Разгрузочный (поздняя лютеиновая) | технически сложная база |
| Нейтральный (`cycleConfidence` < 0.3) | — |

Тип блока приходит из `CycleState.periodization.blockType` уже гейтированным
порогом 0.3 (§11.2): ниже порога он нейтральный, и слагаемое обнуляется само.

**Из непрерывного объёма в целые `target_sets`.**

1. Каждое выбранное упражнение получает 2 подхода.
2. Пока это улучшает score — один подход тому упражнению, которое улучшает его
   сильнее всего. Потолок — 5 подходов на упражнение и бюджет времени.
3. Если объём не принимает даже минимум (глубокий срез), снимается упражнение,
   снятие которого улучшает score, — пока их не меньше трёх и пока выполняется
   минимум паттернов.
4. Сюда же ложатся добавленные подходы §9.5, п.2: к подходам упражнения
   прибавляется `exercise_states.extra_sets_added`. Потолок пяти подходов и
   бюджет времени действуют и на них: что не поместилось, не кладётся, а
   счётчик от этого не откатывается (§9.5).
5. Последним — ±1 подход на сессию по готовности (§10): `sessionSetDelta` и
   `exerciseForSessionSetIncrease` / `…Decrease`. +1 не даётся, если ломает бюджет
   времени; −1 не опускает упражнение ниже одного подхода.

Порядок именно такой, как требует §10 («Предельный случай»): недельный фактор в
цели сессии («Объём сессии» выше), затем целые подходы, затем ±1 на конкретной
сессии.

**Повторы и RIR упражнения.** Границы повторов и `baseRIR` — из §9.1. Целевой RIR
упражнения:

```
target_rir     = baseRIR + min(phaseRIR + readinessRIRBump, +1)
               + fatigueRIRBump + conservativeRIRBump                            // §10, §14.1
fatigueRIRBump = 1, если хоть одна нагруженная упражнением мышца не восстановлена (§8.2), иначе 0
```

«Нагруженная» — с ненулевым вкладом в `muscle_contributions`: то же множество, по
которому §10 срезает надбавку к весу.

**Алгоритм: жадный отбор, ремонт паттернов, локальное улучшение.**

1. Пул — все упражнения среза (§7.5), прошедшие жёсткие ограничения.
2. Жадный шаг: для каждого кандидата считается полная раскладка подходов и score,
   берётся лучший. Останов — когда ни один кандидат не улучшает score, либо
   упражнений семь, либо ни одно не влезает в бюджет времени.
3. Ремонт паттернов: пока разных паттернов меньше требуемого, добавляется лучший
   кандидат с новым паттерном.
4. Локальное улучшение: замена одного упражнения на любое другое того же
   `pattern` из среза, если score растёт. Лучшее улучшение за проход, не первое;
   не более 20 проходов (на синтетике сходится за 1–3).

Обычная тренировка — 4–7 упражнений; бюджет времени опускает и ниже (сценарий 29:
при `session_minutes = 20` собираются 4 упражнения на 19.7 минуты, при 16 — три,
при 14 — два).

**Состав подбирается по объёму БЕЗ равномерных плановых поправок, подходы — С
ними.** Фаза и разгрузочная неделя умножают все мышцы одинаково, поэтому форму
вектора не меняют, и менять из-за них список упражнений незачем. В прогоне
множители 0.75 / 1.0 / 1.15 дают 9 / 11 / 12 подходов при одном и том же составе —
значит строка «объём на эту неделю снижен» (§7.1) объясняет пересборку полностью.
Утомление действует по мышцам неравномерно и состав менять обязано (§8.3, п.3);
смена типа блока (§11.2) — тоже, и объясняется своей причиной.

Локальное улучшение ограничено тем же `pattern`, а не списком `alternatives`:
список — разметка этапа 2, и качество шага зависело бы от того, насколько полно её
заполнили (§19.1). `alternatives` остаётся там, где нужен именно отобранный
человеком набор: замена в один тап (§13.4) и «на поддержании» (§9.5, п.4).

**Ничьи и детерминизм.** Score сравнивается с точностью 1e-9; при равенстве
выигрывает упражнение с меньшим рангом в перестановке, заданной инжектируемым
seed. Ничьи в реальном контенте часты: вклады размечаются с округлением, и
упражнения с одинаковым профилем встречаются постоянно. Seed передаёт вызывающая
сторона, и он обязан быть стабильным для пары (пользователь, дата дня) — иначе
пересборка с неизменившимся входом вернула бы другую тренировку, а §7.1 запрещает
молчаливые изменения. Порядок упражнений во входном срезе на результат не влияет
(проверено прогоном).

**Порядок упражнений:** сначала многосуставные с высоким `fatigue_cost`, потом
изоляция. Акцентная мышца получает как минимум одно упражнение в первой половине
тренировки, пока пользователь свежий.

### 7.4 Недельный объём

Целевые подходы на мышцу в неделю:

| Уровень | Базовая мышца | Акцентная мышца |
|---|---|---|
| Новичок | 8–10 | 10–14 |
| Средний | 10–16 | 16–20 |
| Опытный | 12–20 | 20–24 |

**Учёт — в эффективных подходах.** Подход засчитывается ведущей мышце упражнения
целиком, остальным — пропорционально: `вклад[m] / максимальный вклад упражнения`.
Подход в тяге на прямых ногах даёт `hamstrings += 1.0`, `glute_max += 0.8`,
`erectors += 0.2`.

Так числа таблицы означают то же, что в источниках, откуда они взяты. Чисто
дробный учёт (доли, суммирующиеся в 1.0) при тех же числах давал бы в 1.7–2.1 раза
меньше на ту же работу — на синтетике неделя из двух дней низа по 17 подходов даёт
`glute_max` 13.0 против 22.3, — и нижние границы таблицы стали бы недостижимыми в
принципе: чтобы приводящие с их долей 0.06 в векторе §7.3 набрали 10 подходов,
неделя должна содержать 167 подходов на низ. Утомление (§8.1) продолжает считаться
по сырым вкладам: там подход, размазанный по пяти мышцам, и должен давать каждой
свою долю.

**Нижняя граница диапазона — стартовая норма, и задаётся она только ведущей мышце
дня** (акцентной; без акцента — по правилу §7.3, «Объём сессии»). Колонка — по
сессии: акцентная у мышцы, которая акцент этого дня, базовая у всех остальных
(§7.3, «Колонка §7.4 — по сессии»). Остальные мышцы получают объём по форме
вектора §7.3, и он у них ниже нижней границы: в прогоне средний уровень с
акцентом на ягодицы набирает за неделю 16.6 подхода на `glute_max` и 8.0 на
квадрицепс. Это не недосмотр: доли вектора отличаются в 6–7
раз, границы таблицы — в полтора, и выполнить их одновременно нельзя. Приоритет у формы дня,
потому что именно она несёт акцент (§1.3). С какой скоростью норма поднимается от
нижней границы к верхней — открытый вопрос, §19.2, п.13.

**Верхняя граница жёсткая для цели и мягкая для факта.** Потолок берётся из той же
колонки, что и норма, — по сессии, — и сверяется с недельной суммой. Планировщик
никогда не ставит мышце недельную цель выше потолка: когда потолок выбран, цель
равна нулю, а освободившийся объём уходит другим мышцам (§7.3). Фактический
перебор от побочных вкладов штрафуется `w2` (§7.3), но не запрещается: почти
каждое упражнение на низ задевает ягодичные, и жёсткий запрет на факт оставил бы
на третьем дне подряд
только сгибание ног и подъёмы на носки — вместо «не блокируем» (§8.3) вышла бы
вырожденная тренировка. Остаточный перебор в прогоне — 21.8 против потолка 20.

Держит потолок сам планировщик — тем, что делит недельную норму между сессиями
(§7.3), а не модель восстановления: срез §8.2 ограничен снизу множителем 0.7, и
пять дней ягодиц подряд без потолка дают новичку 24.7 подхода при потолке 14.

### 7.5 Вход: срез библиотеки упражнений

Планировщик не читает библиотеку упражнений (§6) сам. `FitCore` — чистые функции
над значимыми типами (§2.1) и ни от одного пакета проекта не зависит:
`FitContent` зависит от него, а не наоборот. Поэтому вызывающая сторона
передаёт планировщику срез — по записи на каждое упражнение библиотеки, и в
записи только те поля §6.2, которые читают правила планировщика. В `FitCore`
запись среза — `ExerciseCandidate`. Целевой вектор дня (§7.3) — такой же вход:
планировщик получает его от вызывающей стороны, а не из `FitContent`.

**Библиотека передаётся целиком, без предварительного отбора.** Жёсткие
ограничения §7.3 проверяет сам планировщик — и те, что можно было бы применить
заранее: инвентарь, травмы, флаги боли, `skill_level`. Если бы упражнения
отбирал вызывающий код, правила подбора жили бы вне ядра: тест сценария 30
(§18) проверял бы не планировщик, а то, что ему подали, а сборка тренировки
(§7.3) и замена в один тап (§13.4) могли бы отбирать по-разному. По той же
причине правило, какой сустав приписать флагу боли, одно для всех вызывающих
сторон (§19.2, п.8).

**Состав.** Поле входит в срез, если его читает правило, адресованное
планировщику, — в этом разделе или в тех, что планировщик исполняет:

| Поле §6.2 | Какие правила его читают |
|---|---|
| `slug` | Исключение по флагу боли (§8.4, п.3); `exercise_familiarity` и `repetition_from_last` (§7.3); ссылки из `alternatives`; `workout_exercises.exercise_slug` (§3.1) |
| `pattern` | Минимум 3 разных `pattern` и `pattern_diversity` (§7.3); порядок «многосуставные, потом изоляция» (§7.3); другой паттерн на переутомлённой мышце (§8.3, п.3) |
| `muscle_contributions` | Расстояние до целевого вектора и перебор недельного объёма (§7.3, §7.4); `fatigue_conflict` и акцентная мышца в первой половине (§7.3); синергисты (§8.3, п.4); близость профиля при замене (§8.4, п.2; §13.4); куда ложится ±1 подход, готовность для веса и надбавка утомления к RIR (§10) |
| `equipment` | Выполнимость на текущем инвентаре (§7.3, §6.6) |
| `joint_stress` | Травмы, `avoid` и `careful` (§14.4); исключение `high` в консервативном режиме (§14.1); замена с другим `joint_stress` (§8.4, п.2) |
| `impact` | Овуляторное ограничение (§11.2) |
| `skill_level` | `skill_level` ≤ уровня пользователя (§7.3); потолок `novice` в консервативном режиме (§14.1) |
| `progression_family` | Не более 2 упражнений из одной семьи (§7.3); более сложный вариант (§9.5, п.3); перенос прогресса при замене (§13.4) |
| `family_load_ratio` | Пересчёт базовой линии при переносе прогресса внутри семьи: замена в один тап (§13.4) и более сложный вариант (§9.5, п.3) |
| `fatigue_cost` | Порядок упражнений (§7.3); меньший `fatigue_cost` на переутомлённой мышце (§8.3, п.3) |
| `setup_seconds` | Суммарное расчётное время ≤ `session_minutes` (§7.3) |
| `default_rest_seconds` | Суммарное расчётное время (§7.3); длительность таймера отдыха (§13.3) — одно и то же число |
| `unilateral` | Суммарное расчётное время (§7.3): односторонний подход стоит вдвое дороже по работе |
| `load_type` | «Тренажёры и изоляция вместо технически сложной базы» в приоритете разгрузочного блока (§11.2) — слагаемое w8 целевой функции (§7.3) |
| `alternatives` | Упражнение «на поддержании» (§9.5, п.4) и замена в один тап (§13.4) |

**`alternatives` — поле записи, а не отдельный вход.** Слаги из списка
разрешаются внутри того же среза: библиотека передана целиком, и каждая
альтернатива в нём есть. Альтернатива проходит те же жёсткие ограничения, что
и любое упражнение: попадание в список не обходит ни инвентарь, ни травму, ни
флаг боли. Список направленный — если у A в альтернативах B, у B в альтернативах
A быть не обязано. Слаг, которого в библиотеке нет, — ошибка разметки; ловит её
валидатор схемы (§19.1), а не планировщик. Локальное улучшение (§7.3) этим
списком не ограничено: оно перебирает упражнения того же `pattern` из всего
среза, потому что качество шага не должно зависеть от полноты разметки. Список
нужен там, где важен именно отобранный человеком набор.

Замена в один тап (§13.4) семьёй не ограничена: `progression_family` решает
только, переносится ли прогресс. Замена внутри семьи — это более сложный вариант
§9.5, п.3, и опирается она на `progression_family`, а не на `alternatives`.

**Инвентарь — два отдельных входа.** Выполнимость (§6.6) читает две части одной
строки `equipment_profiles` (§3.1), и планировщик получает их раздельно:

- **`EquipmentProfile`** — веса: `dumbbells_kg`, `kettlebells_kg`, `plates_kg`,
  `barbell_kg`, `machine_step_kg`. Из него строится лестница (§9.5); тип уже есть
  в `FitCore/Equipment` и под планировщик не расширяется.
- **`EquipmentAvailability`** — всё остальное, что читает словарь §6.6: `bench`,
  `pullup_bar`, `bands`, `has_kettlebells`, `cable_machine`, `machines`. Срез
  планировщика, как `ExerciseCandidate`, и живёт в его папке.

Лестница — ответ на «чем нагрузить», а не на «что есть в зале»: смешивать их в
одном типе значило бы отдать округлению веса поля, которые оно не читает.

**Контракт согласованности.** Два входа описывают одну строку, и разойтись они
могут там, где у весов есть свой флаг: пользователь снял «есть гири», не очистив
список. Правило: **флаг главнее**. Вызывающая сторона, строя `EquipmentProfile` из
строки, передаёт:

- `kettlebells_kg` пустым, если снят `has_kettlebells`;
- `machine_step_kg` пустым, если нет ни `cable_machine`, ни одного слага в
  `machines` — своего флага у шага нет, он общий у блока и тренажёров.

Проверяет это она, а не планировщик: планировщик получает уже согласованную пару
и не выбирает, кому из двух верить. Для выполнимости контракт избыточен — гиревое
упражнение и так отсеет требование `kettlebells`, — но `EquipmentProfile` читает не
только подбор: лестница из него строит и `prescribed_kg` (§7.6), и пересчёт
прогрессии (§4.3), а там словаря §6.6 нет, и по несогласованной паре они
округляли бы вес к гирям, которых у пользователя нет.

**Чего в срезе нет:**

- `name`, `cues`, `common_errors`, `illustration` — показ, а не подбор.
- `equipment_optional` — на выполнимость не влияет.
- `weight_increment_source` — квантование веса (§9.5), а не выбор упражнения.
  `load_type` в срезе есть, но по другой причине — приоритет разгрузочного блока
  (§11.2) отличает тренажёры от свободного веса.
- `default_rep_range` — `target_rep_min`/`target_rep_max` назначаются по цели
  (§9.1), а не по разметке упражнения.

Столбец «Приоритет» §11.2 (изоляция, тренажёры, технически сложная база) и
«меньше технически сложных» при низкой готовности (§10) переведены в поля:
`pattern` и `skill_level` дают «технически сложную базу», `load_type` — тренажёры.
Оба правила — слагаемые w8 и w9 целевой функции §7.3, с потолком на их сумму.

**Срез не расширяется про запас.** Новое правило, которому нужно поле вне среза,
добавляет его в таблицу выше в том же изменении SPEC. По срезу видно, от каких
полей разметки зависит подбор, — но только пока в нём нет лишнего.

### 7.6 Выход: готовность для веса

Для каждого упражнения тренировки планировщик проставляет в
`workout_exercises.weight_readiness` (§3.1) готовность, применённую к его весу, —
`weightReadiness` (§10, «Вес следует порогу RIR»). Проставляет тем же расчётом,
что и `prescribed_kg`: у упражнения с весом
`prescribed_kg = roundToAchievable(baseline_kg × weight_readiness)` (§9.6).
Когда переписывается `prescribed_kg` — пересборка дня (§7.1), замена упражнения
(§13.4), — переписывается и `weight_readiness`.

**Пересчёт читает хранимое значение и не подставляет дневное.** При пересчёте
состояния прогрессии из журнала (§4.3) готовность сессии упражнения (§9.6)
берётся из `workout_exercises.weight_readiness`, а не из `workouts.readiness`.
Сегодня демпфирование §9.6 дало бы на обоих одно и то же — срез не опускает
готовность ниже 1.0, а демпфирование включается ниже 0.95 (§10), — но это
совпадение порогов, а не контракт: первое же правило прогрессии, читающее
готовность выше 0.95, развело бы состояние, посчитанное в день тренировки, и
пересчитанное после конфликта синхронизации, хотя пересчёт по журналу (§4.3)
существует ровно затем, чтобы они сходились. Вычислить `weightReadiness` заново
при пересчёте нельзя: для этого нужно утомление мышц на момент тренировки (§8.1)
и разметка `muscle_contributions`, которая к тому времени могла измениться.
Поэтому значение хранится как факт того, что применили, — как и `prescribed_kg`
(§9.4).

`workouts.readiness` остаётся дневным числом — для разбора «почему мне это
дали» (§3.1) и для правил §10, которые читают дневную готовность: ±1 подход на
сессию и RIR +1 ниже 0.85.

---

## 8. Модель восстановления

### 8.1 Остаточное утомление

После каждой тренировки для каждой мышцы `m`:

```
Δfatigue[m] = Σ over sets (
    contribution[exercise][m]
  · fatigue_cost[exercise]
  · intensity_factor(feedback)
)

intensity_factor:  easy 0.6 | ok 1.0 | hard 1.35 | failed 1.5
```

Распад экспоненциальный:

```
fatigue[m](t) = fatigue[m](t₀) · 0.5 ^ ((t − t₀) / halfLife[m])

halfLife: крупные — 30 ч
            glute_max, quads, hamstrings, lats, pecs, adductors
          мелкие — 20 ч
            biceps, triceps, side_delts, calves, glute_med,
            traps_mid, traps_upper, rear_delts, front_delts, forearms,
            abs, obliques
          erectors — 40 ч (поясница восстанавливается дольше всех)
```

Список исчерпывает все 19 слагов §6.4: у каждой мышцы период полураспада
задан явно, значения по умолчанию нет. Восемь мышц (`glute_med`,
`traps_mid`, `traps_upper`, `rear_delts`, `front_delts`, `forearms`, `abs`,
`obliques`) отнесены к «мелким» консервативно: SPEC §8.2 требует не
блокировать тренировку утомлением, а более быстрый распад для мышцы без
отдельного клинического обоснования реже завышает её утомление там, где это
не подтверждено. `glute_med`, несмотря на смежность с `glute_max`, — не
исключение: мышца заметно меньше и работает как стабилизатор, а не основной
разгибатель бедра, поэтому остаётся среди мелких, а не переходит в крупные
вместе с ягодичными. `adductors` — исключение из этой группы: приводящие
бедра работают как разгибатель бедра наравне с ягодичными и бицепсом бедра в
приседе и шарнирных движениях, и по мышечной массе сопоставимы с ними, так что
относить их к той же группе, что бицепс плеча или икры, было бы неверно по
тому же признаку, которым разделены сами группы — отсюда 30ч, а не
консервативный дефолт.

Пороги: `fatigue < 0.8` — восстановлена, `0.8–1.8` — частично, `> 1.8` — нет.

### 8.2 Влияние на рекомендации

Утомление мышцы поднимает целевой RIR (меньше близость к отказу) и снижает
рекомендованный объём для этой мышцы, но **не блокирует** тренировку.

Конкретные поправки по порогам §8.1:

```
fatigue < 0.8   (восстановлена):    RIR +0,  объём × 1.0
0.8 ≤ f ≤ 1.8   (частично):         RIR +0,  объём × (1.0 − 0.3 · (f − 0.8) / (1.8 − 0.8))
fatigue > 1.8   (не восстановлена): RIR +1,  объём × 0.7
```

В полосе «частично» объём режется линейно: на нижней границе (0.8) поправки
нет, на верхней (1.8) срез достигает тех же −30%, что и в §8.3. Так утомление
влияет на рекомендацию непрерывно, а не скачком на пороге 1.8. Подъём целевого
RIR — только в крайнем случае: §8.3 описывает именно его, и работать дальше от
отказа на умеренном утомлении незачем.

Минимальный множитель объёма — 0.7 при любом сколь угодно большом `fatigue`:
объём режется, но тренировка не вырождается в ноль (см. «не блокирует» выше).

### 8.3 Конфликт «пятый день ягодиц подряд»

Разрешаем, но меняем наполнение. Конкретно:

1. Целевой RIR +1 (работаем дальше от отказа).
2. Объём на переутомлённую мышцу −30%. Это крайний случай шкалы §8.2
   (`fatigue > 1.8`); при частичном восстановлении срез меньше и растёт
   линейно.
3. Приоритет отдаётся упражнениям с другим `pattern` и меньшим
   `fatigue_cost` — вместо приседа со штангой ягодичный мостик или отведение
   в кроссовере.
4. Свободный объём перераспределяется на восстановившиеся синергисты.
5. На экране — честное объяснение: «Ягодицы ещё не восстановились после
   вторника. Сегодня лёгкая работа с акцентом на среднюю ягодичную — она
   отдохнула».

**Не блокируем и не показываем модалку.** Модалки на каждый чих — частая
причина удаления фитнес-приложений.

### 8.4 Флаг боли

Отдельная кнопка на экране подхода. При нажатии:

1. Текущее упражнение немедленно прекращается, подход помечается
   `pain_flag = true`.
2. Предлагается 3 альтернативы с похожим профилем вклада мышц, но другим
   `joint_stress`.
3. Упражнение исключается из подбора на 14 дней. Граница включающая: на 14-й
   день после флага упражнение ещё исключено, на 15-й уже доступно. Так же
   включающее и 30-дневное окно в п.4–5 ниже.
4. Если флаг боли по одному упражнению повторяется 2 раза за 30 дней —
   предложение добавить постоянное ограничение в профиль.
5. Если флаг боли по разным упражнениям с одним `joint_stress`-суставом
   3 раза за 30 дней — мягкая рекомендация показаться специалисту.
   «Разные упражнения» считаются по числу различных `exercise_slug`, а не по
   числу событий, иначе п.5 срабатывал бы от повторной боли в одном и том же
   упражнении, который уже покрыт п.4. Какой именно сустав приписывается
   флагу, когда `joint_stress` упражнения содержит несколько суставов
   одинаковой степени, — открытый вопрос, см. §19.2, п.8.

Боль ≠ тяжело. Разделение важно и для безопасности, и для чистоты данных
алгоритма: подход с болью не должен интерпретироваться как «слишком тяжёлый
вес».

---

## 9. Алгоритм адаптации нагрузки

### 9.1 Модель: двойная прогрессия с RIR-модуляцией

Каждое упражнение имеет состояние:

- `baseline_kg` — базовый рабочий вес
- `[rep_min, rep_max]` — целевой диапазон повторов
- `rep_extension` — расширение верхней границы (0..4), см. §9.5
- `stall_count` — счётчик застоя
- `in_calibration` — режим калибровки

**Принцип:** держим вес, пока не выйдем на верх диапазона во всех рабочих
подходах, затем повышаем вес и возвращаемся к низу диапазона.

Диапазоны по цели:

| Цель | Диапазон | Целевой RIR |
|---|---|---|
| Сила | 4–6 | 1–2 |
| Гипертрофия | 8–12 | 1–2 |
| Тонус / форма | 10–15 | 2–3 |
| Выносливость | 15–20 | 2–3 |
| Общее здоровье | 10–15 | 2–3 |

Строка `general` совпадает со строкой тонуса: обоснования для других чисел нет, а
`profiles.goal` это значение допускает (§3.1), и без строки у него не было бы ни
диапазона, ни RIR.

**Из диапазонов таблицы в числа упражнения.** `workout_exercises` хранит одну пару
границ повторов и одно целевое число RIR (§3.1):

```
target_rep_min = низ диапазона цели
target_rep_max = верх диапазона цели + exercise_states.rep_extension     // §9.5
baseRIR        = experience_level == novice ? верх RIR цели : низ RIR цели
```

Новичку — верхняя граница RIR: оценивать запас до отказа учатся с опытом, у
новичка ошибка оценки больше, и лишний повтор запаса страхует от отказа, который
она не распознает. Среднему и опытному — нижняя. Итоговый `target_rir` — `baseRIR`
с поправками фазы, готовности, утомления и консервативного режима (§10; для
упражнения — §7.3).

**Границы считает одна функция, и она одна на три места.** `Planner.repRange`
(FitCore) даёт пару границ по цели и состоянию упражнения; её вызывают запись
`workout_exercises.target_rep_min`/`target_rep_max`, построение дерева решений
(§20.9) и заполнение `exercise_states.current_rep_min`/`current_rep_max`. Второй
реализации формулы выше не существует ни на сервере, ни во фронтенде — иначе
дерево и предписание разошлись бы, а тест 20c этого не увидел бы (он сверяет
дерево с `Progression.nextSet` на одном и том же диапазоне, то есть слеп именно
к выбору диапазона).

**Функция вызывается на состоянии, которое реально использует сборка, включая
эффекты §9.7, применённые до неё** — не на сыром `exercise_states` до сброса.
Разница не теоретическая: после 30 дней перерыва детренированность обнуляет
`rep_extension` внутри сборки, и хранимое состояние с `rep_extension = 3` дало
бы `8–15` там, где сессия предписывает `8–12`. То же состояние, из которого
считается предписание, идёт и в `current_rep_min`/`current_rep_max`.

`default_rep_range` (§6.2) диапазон упражнения не задаёт: границы берутся из цели.

### 9.2 Фидбэк после подхода

Пользователь вводит: фактические повторы, фактический вес (оба предзаполнены
рекомендацией, меняются тапом) и одну кнопку из четырёх.

| Кнопка | Внутренний RIR |
|---|---|
| Легко | ≥ 4 |
| Нормально | 2–3 |
| Тяжело | 0–1 |
| Не осилила | недобор до `rep_min` |

Четыре кнопки, а не шкала RPE 1–10: новички ошибаются в оценке запаса на 2–3
повтора, а точность в зале обратно пропорциональна количеству вариантов.

### 9.3 Реакция внутри сессии (следующий подход того же упражнения)

```
func nextSetWeight(current: Double, feedback: Feedback,
                   actualReps: Int, range: ClosedRange<Int>,
                   isCalibration: Bool, equipment: Equipment) -> Double {

  let raw: Double

  switch (feedback, actualReps) {
  case (.failed, _):
      raw = current * 0.90
  case (.hard, let r) where r < range.lowerBound:
      raw = current * 0.95
  case (.hard, _):
      raw = current                       // в диапазоне и тяжело — то, что нужно
  case (.ok, _):
      raw = current
  case (.easy, let r) where r >= range.upperBound:
      raw = isCalibration ? current * 1.15 : current * 1.05
  case (.easy, _):
      raw = current                       // легко, но повторов мало: добираем повторами
  }

  return equipment.roundToAchievable(raw, direction: raw < current ? .down : .up,
                                     loadType: exercise.loadType)
}
```

Правило: понижение округляется **вниз**, повышение — **вверх**. Никогда не
повышаем более чем на один достижимый шаг за подход вне калибровки.

Два подряд `failed` в одном упражнении → упражнение завершается досрочно,
оставшиеся подходы помечаются `sets.skipped = true`, и сессия заканчивается с
меньшим объёмом на эту мышцу.

**Переноса объёма на следующее упражнение нет.** Прежняя формулировка требовала
его, не задавая механики, и противоречила правилу неприкосновенности §7.1
(«уже начатая тренировка никогда не пересобирается»). Перенос пришлось бы
класть на соседнее упражнение в порядке сессии, а в дне с акцентом соседнее
обычно нагружает ту же мышцу — ту, на которой пользователь только что дважды
не доделал подход и которая уже получила от этих подходов утомление с
множителем 1.5 (§8.1). Это работало бы против §8.2, где утомление объём
срезает, а не добавляет.

Потерянные подходы не догоняются и в оставшиеся дни недели: `неделя[m]` —
свёртка по фактически выполненным подходам (§7.3), `S_эфф` от досрочного
завершения не меняется, и оставшиеся дни пересобираются по тому же правилу,
что после пропуска (§7.1). Планировщику здесь делать нечего: решение целиком
внутрисессионное, и наружу оно выражается только отметкой `skipped` у
неначатых подходов.

### 9.4 Реакция между сессиями

Смотрим на последнюю сессию с этим упражнением (и две предыдущие для устойчивости).

**Опорный подход.** Все решения между сессиями считаются по **открывающему**
рабочему подходу сессии — не по последнему и не по максимуму за сессию. Вес
последующих подходов назначает внутрисессионная реакция (§9.3), а она понижает
его ровно на `failed` и на `hard` ниже `rep_min`. Если смотреть на последний
подход, признак «пользователь снизил вес» выполняется сам собой всякий раз,
когда такой фидбэк вообще был, и один плохой подход откатывает базовую линию —
в прямом противоречии с принципом в конце этого раздела.

**Оверрайд веса.** Пользователь может изменить предзаполненный вес тапом
(§9.2). Оверрайдом считается отклонение открывающего подхода от предписания,
**лежащее при этом по ту же сторону от `baseline_kg`**:

```
override = вниз,  если actual_kg < prescribed_kg И actual_kg < baseline_kg
override = вверх, если actual_kg > prescribed_kg И actual_kg > baseline_kg
иначе оверрайда нет        (открывающий подход; порог сравнения — цент)
```

Сравнение с `prescribed_kg`, а не с `baseline_kg`: предписание — это
`baseline_kg × readiness` (§9.6), поэтому на всяком дне с readiness ≠ 1.0
принятое как есть предписание читалось бы как оверрайд. `prescribed_kg` —
факт из журнала: то, что реально показали пользователю, и его не нужно
пересчитывать при смене алгоритма.

Второе условие, «по ту же сторону от `baseline_kg`», не перестраховка: readiness
доходит до 1.10 (§10), то есть предписание бывает **выше** базовой линии. Отказ
от такой надбавки (взяла меньше предписанного, но не меньше своей базовой линии)
— не заявление «мне тяжело на моём рабочем весе». Симметрично вверх: принятая
надбавка оверрайдом не является.

**Направление обязательно.** Повышение никогда не уменьшает `baseline_kg`,
понижение никогда не увеличивает. Само это не выполняется: округление до
достижимого веса клэмпит к границам лестницы (вверх — к максимуму, вниз — к
минимуму), а `baseline_kg` лестницей не ограничен, потому что заводится из
фактического веса пользователя (тренировка на чужом инвентаре). Если ступени в
нужную сторону нет, базовая линия остаётся на месте.

```
Повышение веса, если ВСЕ выполнены:
  - все рабочие подходы достигли rep_max + rep_extension
  - ни в одном подходе фидбэк не был 'failed'
  - минимум в одном подходе фидбэк был 'easy' или 'ok'
  → если override вверх: baseline_kg = округлить ВВЕРХ до достижимого(actual_kg
    открывающего подхода), rep_extension = 0, extra_sets_added = 0. Проверка
    «прыжок ≤ 10%» (§9.5) не применяется — вес уже отработан фактически. Если
    результат округления не выше baseline_kg (лестница исчерпана сверху) —
    повышения нет, см. §9.5
  → иначе см. §9.5 (может вылиться в расширение диапазона вместо повышения веса)

Понижение веса:
  - две сессии подряд с недобором до rep_min в любом рабочем подходе
  - ИЛИ одна сессия с двумя 'failed'
  - ИЛИ override вниз И открывающий подход получил 'hard' или 'failed'
    (пользователь сам взял легче, и этого не хватило)
  → если override вниз: baseline_kg = округлить ВНИЗ до достижимого(actual_kg
    открывающего подхода) — шаг вниз уже сделан пользователем
  → иначе (в том числе когда вес снижен ГОТОВНОСТЬЮ, а не пользователем):
    baseline_kg на один достижимый шаг вниз от базовой линии
  → если результат не ниже baseline_kg (лестница исчерпана снизу) —
    понижения нет, базовая линия остаётся на месте
  → rep_extension = 0, extra_sets_added = 0, stall_count = 0

Застой:
  - три сессии подряд без повышения при отсутствии понижения
  → stall_count += 1
  - при stall_count = 1: deload −10%, вернуться к rep_min, набирать заново,
    extra_sets_added = 0
  - при stall_count = 2: предложить замену упражнения на альтернативу из
    той же progression_family
```

**Что считается «сессией подряд».** Прогоны в правилах понижения и застоя
считаются только по обычным рабочим сессиям:

- сессия без записанных подходов — артефакт данных, а не тренировка: не
  участвует ни в одном прогоне и не сбрасывает счётчик перерыва (§9.7);
- калибровочная сессия (§9.8) **обрывает оба прогона**: ни «две подряд с
  недобором», ни «три подряд без прогресса» нельзя утверждать, когда одна из
  них — подбор веса с шагом ±15%. При этом для §9.7 она считается выполненной:
  мышца работала, счётчик перерыва сбрасывается. Это верно и когда
  калибровочная сессия первая — она задаёт `baseline_kg`, но в прогонах не
  участвует;
- сессия взвешенного упражнения, где вес вообще не записан (`actual_kg` пуст),
  базовой линии не задаёт и решений по весу не даёт.

**Один плохой день не откатывает вес.** Это прямое следствие двухуровневой
модели: внутри сессии реагируем быстро, между сессиями — по двум-трём точкам.

### 9.5 Недостижимый вес

Главная проблема домашних тренировок. Гантели 2/4/6/8 кг: шаг с 6 на 8 — это
+33% нагрузки, что не осилить.

Вызывается из §9.4 тогда, когда повышение по фактически взятому весу не
состоялось: оверрайда вверх не было либо лестница исчерпана сверху.

```
func planProgression(state: ExerciseState, equipment: Equipment) -> Progression {
  let next = equipment.nextAchievableWeight(above: state.baselineKg,
                                            loadType: exercise.loadType)
  guard let next else {                            // тяжелее нет вообще
      if state.repExtension < 4   { return .extendReps }
      if state.extraSetsAdded < 2 { return .addSet }
      return .suggestHarderVariant                 // подробности — в списке ниже
  }

  let jump = (next - state.baselineKg) / state.baselineKg

  if jump <= 0.10 {
      return .increaseWeight(to: next)             // нормальный шаг
  }

  // Шаг слишком велик: растём повторами внутри расширенного диапазона
  if state.repExtension < 4 {
      return .extendReps                           // rep_max += 2, до +4
  }

  // Расширение исчерпано — прыгаем на вес и режем повторы
  return .increaseWeightWithRepReset(to: next,
                                     newRange: state.baseRange.lowerBound
                                             ... state.baseRange.lowerBound + 2)
}
```

Если тяжелее нет вообще (упёрлись в максимальную гантель или в собственный вес):

1. Растим повторы до `rep_max + 4`.
2. Затем добавляем подход (до +2 подходов от базового).
3. Затем — предложение перейти на более сложный вариант из
   `progression_family` (например, приседания → болгарский сплит-присед),
   если такой размечен. Вес переносится по §13.4.
4. Если ничего нет — упражнение помечается как «на поддержании», и планировщик
   начинает предпочитать альтернативы.

**Пункты 3–4 пока не действуют.** Что делает вариант внутри
`progression_family` «более сложным», не определено: мерой сложности не
объявлены ни `skill_level`, ни `family_load_ratio`. Флаг «на поддержании» нигде
не хранится. Пока определения нет, предлагать более сложный вариант нечем, а
слагаемое w10 (§7.3) всегда равно нулю: упражнение, которому некуда расти,
планировщик не отодвигает. Вес w10 в таблице §7.3 сохранён для того дня, когда
флаг появится. Открытый вопрос — §19.2, п.14.

**Не реализовано (1 из 3).** Суженный диапазон из `increaseWeightWithRepReset`
нигде не сохраняется. Место в схеме есть (`exercise_states.current_rep_min` /
`current_rep_max`), но решение о сужении доступно только вызывающему коду и до
следующей сессии не доживает: прогрессия обрабатывает этот случай как обычное
повышение веса со сбросом `rep_extension`. Планировщик проставляет
`target_rep_min`/`target_rep_max` по цели и `rep_extension` (§9.1) и суженного
диапазона не видит. Когда сужение начнёт сохраняться, в том же изменении меняются
правило §9.1 для `target_rep_*`, формула времени (§7.3) и фазовые диапазоны
(§11.2).

Шаг 2 — счётчик `extra_sets_added` (§3.1), часть состояния прогрессии, как и
`rep_extension`: растёт на решении «добавить подход» и поэтому восстанавливается
пересчётом из журнала (§4.3) вместе с остальным состоянием. Планировщик получает
его на вход и прибавляет к `target_sets` (§7.3, «Из непрерывного объёма в целые
`target_sets`», п.4).

**Сбрасывается там же, где `rep_extension`:** на повышении веса, на понижении и
на deload по застою (§9.4), на перерывах от 22 дней (§9.7). Добавленные подходы —
компенсация за «тяжелее нет вообще»; после понижения, deload или перерыва тяжелее
снова есть, и компенсировать нечего. Оставить их значило бы держать +2 подхода на
сниженном весе — в том числе в калибровке после перерыва больше 45 дней, где
§9.7 обещает «начнём чуть легче».

**Счётчик записывает решение, а не выполненные подходы.** Сколько подходов было
бы без добавленных, нигде не записано: `target_sets` — уже итог раскладки §7.3 и
меняется от сессии к сессии. Так же устроен `rep_extension` — он фиксирует
расширение диапазона, а не то, добрала ли пользователь новые повторы. Следствие
называется прямо: если добавленный подход не поместился (потолок пяти подходов
или бюджет времени), счётчик всё равно вырос, и после двух таких раз каскад
переходит к шагу 3. Это законно: тяжелее нет, добавить подход некуда — расти в
этом упражнении больше нечем.

### 9.6 Множитель готовности и защита базовой линии

Ключевой момент, который легко испортить: **дневная готовность не должна
портить долгосрочную базовую линию**.

```
displayedWeight = roundToAchievable(baseline_kg × readiness)
```

где `readiness ∈ [0.75, 1.10]` (§10) — готовность, применённая к весу этого
упражнения: на невосстановленной мышце её надбавка выше 1.0 срезается (§10,
«Вес следует порогу RIR»). Она же хранится в `workout_exercises.weight_readiness`
(§3.1, §7.6), и демпфирование ниже читает именно её — и в день тренировки, и при
пересчёте из журнала (§4.3), — а не дневное `workouts.readiness`.

Фидбэк, полученный в день с низкой готовностью, обновляет `baseline_kg` с
демпфированием:

```
if readiness < 0.95 {
    // «Тяжело» на сниженном весе в день с readiness 0.8 — это ожидаемо,
    // а не сигнал, что базовая линия завышена
    dampingFactor = 0.4
} else {
    dampingFactor = 1.0
}

baseline_kg += rawAdjustment × dampingFactor
```

Множитель применяется к `rawAdjustment` **симметрично: к поправке любого
знака**. Из формулы это следует и так, но разобран выше только случай
понижения, поэтому сказано явно — повышение в день с readiness 0.8
демпфируется ровно так же. Демпфируется только реакция на фидбэк; множители
детренированности (§9.7) и deload при застое (§9.4) приходят готовыми и через
демпфирование не проходят.

Само же демпфирование одностороннее по построению: оно включается только ниже
0.95, а весь верх диапазона (0.95…1.10) идёт с множителем 1.0. **Верхнюю
половину защищает не демпфирование, а то, от чего считается поправка:**

- базовая линия двигается только по оверрайду пользователя (§9.4) либо по
  каскаду §9.5, считающему от самой `baseline_kg`;
- отработанный `displayedWeight` сам по себе не двигает базовую линию
  **никогда** — ни вверх, ни вниз;
- поэтому отказ от надбавки готовности не считается оверрайдом (§9.4): иначе
  день с readiness 1.10 понижал бы базовую линию всякий раз, когда пользователь
  берёт свой обычный вес вместо предложенного и отмечает «тяжело»;
- и по той же причине, когда понижение происходит по другому основанию (два
  `failed`), шаг вниз считается ОТ БАЗОВОЙ ЛИНИИ, а не от сниженного
  готовностью предписания — иначе день с низкой готовностью наказывал бы
  базовую линию сильнее, чем день на полном весе.

Без этих правил день с readiness 1.10 двигал бы `baseline_kg` вверх, до
раздутого готовностью веса в обход проверки «прыжок ≤ 10%» (§9.5), а день с
readiness 0.75 — вниз, глубже, чем того заслуживает результат. Это то же
нарушение принципа «дневная готовность не должна портить долгосрочную базовую
линию», что и откат прогресса в менструальную фазу, только в другую сторону.

Без этого механизма каждая менструальная фаза откатывала бы прогресс на месяц
назад — классическая ошибка адаптивных приложений.

### 9.7 Детренированность

Перерыв в тренировках по конкретному упражнению:

| Перерыв | Действие |
|---|---|
| ≤ 10 дней | Ничего |
| 11–21 день | `baseline_kg × 0.92` |
| 22–45 дней | `baseline_kg × 0.85`, `rep_extension = 0`, `extra_sets_added = 0` |
| > 45 дней | `in_calibration = true`, `baseline_kg × 0.75`, `rep_extension = 0`, `extra_sets_added = 0` |

При возврате показывается объяснение: «Не тренировали это 3 недели, начнём
чуть легче — вернёте вес за пару занятий».

### 9.8 Калибровка (холодный старт)

Первые 2–3 тренировки явно помечены в UI как калибровочные.

**Стартовый вес** берётся из консервативных таблиц от веса тела, опыта и пола,
затем умножается на 0.6. Намеренное занижение: безопасно, и алгоритм быстро
поднимет.

Пример коэффициентов (женщина, новичок, доля от веса тела на одну гантель):

| Упражнение | Коэффициент |
|---|---|
| Жим гантелей лёжа | 0.12 |
| Тяга гантели в наклоне | 0.15 |
| Приседания с гантелями (гоблет) | 0.20 |
| Румынская тяга с гантелями | 0.18 |
| Жим гантелей стоя | 0.08 |

Множители: средний уровень ×1.5, опытный ×2.0, мужчина ×1.5.

**Не реализовано (2 из 3).** Таблицы стартового веса живут вне ядра прогрессии —
им нужны данные профиля (вес тела, пол, опыт) и коэффициент упражнения, которых
у `FitCore` нет по правилу зависимостей. Пока их нет, начальной базовой линией
становится вес, установленный первой записанной сессией, а сами таблицы обязан
применить онбординг (этап 3) до того, как первый подход попадёт в журнал.
Коэффициента на упражнение в схеме §6.2 тоже нет — его нужно добавить туда же,
где живут `impact` и `family_load_ratio`.

**Поведение в калибровке:**

- шаг вверх при «легко» — +15% вместо +5%
- разрешено до 3 повышений внутри одного упражнения за сессию — **не
  реализовано (3 из 3):** это счётчик в пределах одной сессии, а прогрессия
  между сессиями им не владеет; ограничение обязан накладывать экран
  тренировки (этап 4), который и вызывает реакцию §9.3 подход за подходом
- результаты калибровочных подходов **не идут** в модель утомления и в
  недельный объём
- выход из калибровки: два подхода подряд с фидбэком «нормально» или «тяжело»
  при попадании в целевой диапазон повторов

Отдельного экрана калибровки нет — это тот же экран тренировки с баннером
«Подбираем ваши веса» и более крупным шагом.

---

## 10. Готовность (readiness)

Единое число, сводящее фазу цикла, чек-ин и (в v2) данные восстановления.

```
phaseTerm =
    override != null
      ? overrideAdjustment                              // §11.4: ЗАМЕНЯЕТ фазу, не суммируется
      : phaseUnknown
          ? 0                                           // фазовой составляющей нет (§11.3, §11.5)
          : effectivePhaseAdjustment × cycleConfidence  // §11.2 + личный профиль §11.4

checkinScale =
    phaseUnknown
      ? 1.6
      : 1.0 + 0.6 × (1 − cycleConfidence)

phaseUnknown = phaseMode == no_phases  ||  опорной даты нет (§11.3)

readiness = clamp(
    1.0
  + phaseTerm
  + checkinAdjustment × checkinScale
  + recoveryAdjustment,          // v2: HRV и сон, в MVP = 0
  0.75, 1.10
)
```

`phaseTerm` — одно слагаемое, а не два: оверрайд подставляется **вместо**
фазовой поправки. Пользователь главнее модели (§11.4), поэтому складывать их
нельзя — иначе `push` в фолликулярной фазе давал бы +0.13, а в менструальной
−0.02, то есть одна и та же кнопка означала бы разное.

`checkinScale` растёт по мере падения уверенности в фазе: чем меньше мы знаем о
цикле, тем больше веса у того, что пользователь сказала про себя сегодня. При
`cycleConfidence = 1.0` множитель равен 1.0, при 0 — 1.6. Режим без фаз (§11.5) —
предельный случай той же формулы, а не отдельная ветка.

`phaseUnknown` объединяет два разных состояния с одинаковым следствием для
готовности. В режиме без фаз фаз нет по определению (§11.5); когда опорной даты
нет вовсе (§11.3), режим остаётся `phases`, но день цикла неизвестен и
`cycleConfidence` не определён — вторая ветка обеих формул неприменима. В обоих
случаях фазовая составляющая равна нулю, а весь вес переходит на чек-ин
(`checkinScale = 1.6`). Оверрайд действует всегда (§11.4): он проверяется раньше
`phaseUnknown`. Без этой ветки готовность в таких состояниях не вычислялась бы
вовсе.

**Компоненты чек-ина** (энергия, болезненность мышц, качество сна, стресс —
каждый 1–5):

```
checkinAdjustment =
    (energy − 3)        × 0.020
  + (3 − soreness)      × 0.015
  + (sleepQuality − 3)  × 0.015
  + (3 − stress)        × 0.010
```

Диапазон: примерно −0.12 .. +0.12, после умножения на `checkinScale` — до
±0.19 при нулевой уверенности и в режиме без фаз.

**Пропущенный или частичный чек-ин.** Чек-ин сворачиваемый (§13.1): его могут
заполнить частично или не заполнить вовсе — все четыре поля `daily_checkins`
допускают `null`, а строки за день может не быть. Отсутствующий компонент
читается как нейтральный: его слагаемое равно нулю, ровно как у ответа 3. Нет
строки — `checkinAdjustment = 0`. Молчание не штрафуется и не поощряется: пропуск
шага не должен давать худший продукт и не должен сдвигать рекомендацию ни в
какую сторону. В режиме без фаз, где чек-ин — единственный сигнал, это значит,
что без него готовность равна 1.0 (плюс оверрайд, если нажат) — нейтральный
день, а не сниженный. Оверрайд от шкал чек-ина не зависит.

**Оверрайд** (§11.4): `push` → +0.08, `ease` → −0.10.

`rest` числа не имеет: это решение планировщика, а не слагаемое. День заменяется
на растяжку, запись `workouts` не создаётся (создаётся `stretch_sessions`).
Если пользователь всё же начинает тренировку в день `rest` — приложение не
запрещает — оверрайд численно считается за `ease` (−0.10).

**Что правит готовность, а что фаза.** Уровни разведены, чтобы поправки не
складывались дважды:

| | Фаза (§11.2) | Готовность (§10) |
|---|---|---|
| Объём | Недельный, ±% в цели сессии (§7.3) | ±1 подход на сессию: −1 при `readiness < 0.9`, +1 при `> 1.05` (ниже) |
| RIR | Целевой RIR блока | +1 при `readiness < 0.85` |
| Вес | — | `baseline_kg × readiness` (§9.6); надбавка выше 1.0 — не на невосстановленной мышце (ниже) |
| Упражнения | Мягкие штрафы (§11.2) | При низкой готовности — меньше технически сложных |

**RIR от фазы и готовности — сумма, ограниченная сверху +1.** Не максимум:

```
readinessRIRBump         = readiness < 0.85 ? +1 : 0
phaseRIR                 = phaseUnknown ? 0 : effectiveRIRShift          // §11.2
rirFromPhaseAndReadiness = min(phaseRIR + readinessRIRBump, +1)
targetRIR                = baseRIR + rirFromPhaseAndReadiness
                         + fatigueRIRBump + conservativeRIRBump                  // §8.2, §14.1, сверх
```

Потолок нужен из-за двойного счёта: поздняя лютеиновая фаза (RIR +1) вместе с
просевшей из-за неё же готовностью давала бы +2 и превращала рабочий подход в
разминочный. Источник у них общий — фаза роняет готовность, и та же фаза отдельно
поднимает RIR.

Но это потолок на сумму, а не «берём большее из двух». Фазовая поправка бывает и
отрицательной — фолликулярная и овуляторная дают −1, ближе к отказу, — и максимум
её стирал бы:

| фаза | готовность | сумма с потолком | максимум |
|---|---|---|---|
| поздняя лютеиновая, +1 | < 0.85, +1 | **+1** (2 → потолок) | +1 |
| фолликулярная, −1 | обычный день, 0 | **−1** (потолок не достигнут) | 0 — фазовое −1 стёрто |
| фолликулярная, −1 | < 0.85, +1 | **0** | +1 — фаза не учтена вовсе |

Во второй строке максимум отменял бы фолликулярное −1 в каждый обычный день, и
фазовая поправка к RIR работала бы только в одну сторону. Сумма с потолком
сохраняет её и срезает только совпадение двух плюсов — ровно тот двойной счёт,
ради которого правило существует.

Надбавка от остаточного утомления (§8.2) под это правило **не подпадает** и
добавляется сверх. Она измеряет другое — состояние конкретной мышцы, а не общее
самочувствие дня, — и служит безопасности, а не подстройке нагрузки. Ограничивать
её ради красоты формулы нельзя. Флаг боли (§8.4) на целевой RIR не влияет вовсе:
он прекращает упражнение и исключает его из подбора, а не меняет число.

Так же сверх потолка идёт +1 консервативного режима (§14.1): он включается
красным флагом PAR-Q, служит безопасности, а не самочувствию дня, и срезать его
совпадением с поздней лютеиновой фазой или низкой готовностью нельзя. Вместе с
ними итог — +2.

**Инвариант:** при `fatigue > 1.8` итоговый целевой RIR не ниже базового. При
нынешних значениях он выполняется арифметически и ничего не ограничивает —
фазовый вклад не глубже −1, надбавка утомления +1, готовность к RIR только
прибавляет, поэтому сумма никогда не опускается ниже базы. Записан на случай
изменения констант: если фазовый вклад когда-нибудь станет −2, защита утомления
молча превратится в ноль, и поймать это будет нечем.

**Срезы объёма не перемножаются.** На недельный объём мышцы действует один
плановый срез — от фазы (§11.2) в режиме `phases`, либо от разгрузочной недели
(§11.5) в режиме `no_phases`, а без опорной даты планового среза нет вовсе
(1.0), — и утомление (§8.2). Плановый срез берётся не больше чем из одного
источника, никогда из двух сразу, но правило композиции с утомлением у них общее:
произведение давало бы двойное наказание за одно и то же.

```
volumeFactor = fatigueFactor < 1.0
    ? min(plannedFactor, fatigueFactor)   // из двух срезов берётся сильнейший
    : plannedFactor                        // надбавку планового среза получает только свежая мышца

plannedFactor =
    phase_mode == no_phases ? (текущая неделя разгрузочная ? 0.85 : 1.0)   // §11.5, накопление/разгрузка
  : опорной даты нет        ? 1.0                                          // §11.3: фазы нет, срезать нечем
  :                           phaseFactor[P]                               // §11.2

phaseFactor[P] = 1 + effectiveVolumeShift        // = 1 + volumeShift[P] × cycleConfidence (§11.2)
```

`phaseFactor[P]` — множитель, уже масштабированный уверенностью (в FitCore —
`PhasePeriodization.volumeMultiplier`), а не сырое табличное значение §11.2. С
сырым менструальная фаза при `cycleConfidence = 0.12` резала бы недельный объём
на четверть — ровно то, что §11.2 запрещает (сценарий 24b: −3%, а не −25%).
Проверочные случаи ниже даны при полной уверенности, где оба прочтения совпадают.

Без опорной даты планового среза нет: 1.0 — это предел той же формулы при
`cycleConfidence → 0`, как и для `checkinScale`. Разгрузочный цикл 3+1 режима без
фаз сюда не переносится намеренно: иначе первая же отметка менструации
(уверенность 0.30) переводила бы её с цикла 3+1 на почти ровный объём, то есть
данные, внесённые в приложение, отнимали бы у неё разгрузочные недели.

`0.85` — не новая константа: это тот же множитель, что у «Разгрузочного» блока
поздней лютеиновой фазы (§11.2), применённый к тому же по названию блоку в
режиме без фаз. Числа для трёх недель накопления и одной разгрузочной не
привязаны к фазе, поэтому берётся готовое значение, а не изобретается новое.

Ветвление, а не просто `min`: наивный `min(plannedFactor, fatigueFactor)` при
ранней лютеиновой (×1.15) и восстановленной мышце (×1.0) вернул бы 1.0 и убил бы
фазовую надбавку. Проверочные случаи: свежая + ранняя лютеиновая → 1.15;
свежая + менструальная → 0.75; утомлённая + менструальная → 0.70;
утомлённая + ранняя лютеиновая → 0.70; частично утомлённая (0.9) + менструальная
→ 0.75; разгрузочная неделя + свежая мышца → 0.85; разгрузочная неделя + сильно
утомлённая → 0.70; разгрузочная неделя + частично утомлённая (0.9) → 0.85; опорной даты нет + свежая
мышца → 1.0.

**Предельный случай.** Новичок с базой 8 подходов на мышцу в неделю (§7.4),
менструальная фаза при полной уверенности и невосстановленная мышца:
`min(0.75, 0.70) = 0.70` → 5.6 подхода в неделю, минус 1 на сессии при
`readiness < 0.9` → около 4.6. Порядок применения: недельный фактор в цели сессии
(§7.3), затем ±1 подход на конкретной сессии —
с ограничением ниже: +1 на утомлённую мышцу не ложится. Без правила «сильнейший»
произведение 0.75 × 0.70 = 0.525 дало бы 4.2 подхода и молча пробило бы
обещанный в §8.2 пол 0.7.

То же в режиме без фаз: разгрузочная неделя (0.85) с той же невосстановленной
мышцей даёт `min(0.85, 0.70) = 0.70` — пол удержан. Произведение
0.85 × 0.70 = 0.595 пробило бы его так же, как в фазовом случае, хотя формула,
написанная только через `phaseFactor` (как было до этой правки), для режима
`no_phases` попросту не определена — `phaseFactor` в нём не существует.

**±1 подход — на сессию целиком, не на упражнение и не на мышцу.** При
`readiness < 0.9` из сессии снимается один подход, при `readiness > 1.05`
добавляется один; границы строгие, 0.9 и 1.05 сами поправки не дают.

Единица «на сессию» — единственная, при которой сила поправки не зависит от
числа упражнений. На упражнение та же готовность 1.06 давала бы +4 подхода в
сессии из четырёх упражнений и +7 в сессии из семи (§7.3), а один `push` при
нейтральном чек-ине — готовность 1.0 + 0.08 = 1.08 — прибавлял бы по подходу к
каждому упражнению, от четверти до трети объёма, в каждый такой день. На мышцу
поправка неисполнима напрямую: подход назначается упражнению
(`workout_exercises.target_sets`), мышце достаётся лишь дробная доля по
`muscle_contributions` (§7.4). Слабой поправка на сессию не выходит: объём — не
единственный рычаг готовности, в тот же день вес уже ×`readiness` (§9.6), а RIR
+1 ниже 0.85.

Куда ложится подход:
- **+1** — только на упражнение, ни одна из нагруженных мышц которого не срезана
  утомлением (`fatigueFactor < 1.0` — то же условие, что включает ветку `min` в
  `volumeFactor`). Если такого упражнения в сессии нет, +1 не даётся вовсе.
- **−1** — с упражнения, нагружающего самую утомлённую мышцу; если утомлённых
  нет — с последнего по порядку сессии (изоляция, §7.3). До нуля подходов
  упражнение не сокращается: если снять нечего, поправка пропускается.

**Готовность считается первой, утомление и боль — после неё.** Поэтому `push` не
может поднять то, что уже срезала защита утомления: готовность сдвигает число, а
утомление накладывается на результат — режет объём (не ниже ×0.7) и поднимает
RIR на +1 (§8.2). Готовность может срезать сверх утомления, но не вернуть
срезанное: +1 подход не ложится на утомлённую мышцу, надбавка RIR от утомления
прибавляется сверх потолка фазы и готовности, а `volumeFactor` уже несёт `min` с
`fatigueFactor`. Это и есть гарантия сценария 25 (§18).

**Вес следует порогу RIR, подходы — порогу объёма.** Вес — рычаг интенсивности,
как RIR, поэтому и защищён тем же порогом: на упражнении, где хотя бы одна
нагруженная мышца получила от утомления надбавку RIR (§8.2, `fatigue > 1.8`),
готовность для веса ограничена сверху 1.0 — день может снизить вес, но не
поднять. При частичном утомлении (0.8–1.8) надбавка к весу остаётся, как
остаётся и RIR +0: §8.2 разводит объём (режется непрерывно с 0.8) и
интенсивность (защищается только за 1.8), и подходы с весом идут за ними же.
Предикаты у +1 подхода и у веса разные намеренно.

```
weightReadiness = fatigueRIRBump > 0 хотя бы у одной нагруженной мышцы
    ? min(readiness, 1.0)
    : readiness
displayedWeight = roundToAchievable(baseline_kg × weightReadiness)      // §9.6
```

`push` с нейтральным чек-ином (готовность 1.08): на невосстановленной мышце вес
остаётся базовым, на частично утомлённой и на свежей — ×1.08. В день с
готовностью 0.9 — ×0.9 на всех: срез только сверху. Демпфирование §9.6 это не
задевает — срез не опускает готовность ниже 1.0, а демпфирование включается
ниже 0.95.

Утомление ничего не отсекает — §8.2 прямо говорит «не блокирует»: оно режет
числа, а не варианты. Варианты отсекает только флаг боли (§8.4): упражнение
прекращается и исключается из подбора, и никакое значение готовности этого не
отменяет.

---

## 11. Цикл

### 11.1 Фазы

Модель делит цикл на пять сегментов (лютеиновая разбита надвое — именно там
разница реальна):

| Фаза | Границы (при цикле 28 дней) | Характер |
|---|---|---|
| Менструальная | день 1 – конец кровотечения (обычно 1–5) | Возможен спад, боли |
| Фолликулярная | конец менструации – день 12 | Рост эстрогена, хорошая переносимость нагрузки |
| Овуляторная | день 13–16 | Пик эстрогена, пик силы |
| Ранняя лютеиновая | день 17–23 | Стабильно, хорошая переносимость объёма |
| Поздняя лютеиновая | день 24 – начало менструации | ПМС, терморегуляция, утомляемость |

Границы масштабируются под личную длину цикла: лютеиновая фаза относительно
стабильна (12–14 дней), поэтому вариативность длины цикла относим на
фолликулярную. Отсюда счёт ведётся не от дня 1, а от овуляции:

```
ovulationDay  = expectedLength − 14          // §11.3, прогноз длины
expectedLength = среднее по измеренным циклам (§11.3), если есть хотя бы один;
                иначе cycle_profiles.typical_cycle_length_days;
                иначе 28
menstrualEnd  = период по событию 'period_end', если оно есть;
                иначе cycle_profiles.typical_period_length_days;
                иначе 5

менструальная       1                 .. menstrualEnd
фолликулярная       menstrualEnd + 1  .. ovulationDay − 2
овуляторная         ovulationDay − 1  .. ovulationDay + 2
ранняя лютеиновая   ovulationDay + 3  .. ovulationDay + 9
поздняя лютеиновая  ovulationDay + 10 .. expectedLength
```

При `expectedLength = 28` формула даёт ровно таблицу выше (1–5 / 6–12 / 13–16 /
17–23 / 24–28).

**Дата `period_end` — последний день кровотечения, а не первый чистый.** Отсюда
`menstrualEnd = (period_end − period_start) + 1`, то есть длительность
менструации в днях включительно. Оговорено явно, потому что обратное прочтение
(«отметила, когда закончилось» = первый день без кровотечения) сдвинуло бы все
последующие границы фаз ровно на день, а по самому полю это не отличить.
Инклюзивная трактовка совпадает с тем, как ту же величину даёт импорт из
HealthKit (§15, `menstrualFlow`): последний день с ненулевым потоком.

**Коллизии на коротких циклах.** Границы разрешаются в порядке объявления, и
фаза не может начаться раньше, чем закончилась предыдущая: менструальная
выигрывает всегда, фолликулярная схлопывается первой. При цикле 21 день
(ovulationDay = 7) менструальная занимает 1–5, фолликулярной не остаётся ни
одного дня, овуляторная идёт 6–9. Пустая фаза — допустимый результат, а не
ошибка; покрытие дней при этом остаётся сплошным и без пересечений.

### 11.2 Фазовая периодизация

Выбран **сильный** вариант: фаза меняет не только объём, но и тип тренировки.

| Фаза | Тип блока | Объём | Целевой RIR | Приоритет |
|---|---|---|---|---|
| Менструальная | Восстановительный | −25% | +1 | Мобильность, лёгкое кардио, изоляция. Силовая доступна, если самочувствие ок |
| Фолликулярная | Силовой | +10% | −1 (ближе к отказу) | Многосуставная база, нижние диапазоны повторов, прогрессия весом |
| Овуляторная | Пиковый | базовый | −1 | Окно для попыток личных рекордов. **Ограничение:** избегаем максимальной плиометрии и прыжковых приземлений (см. ниже) |
| Ранняя лютеиновая | Объёмный | +15% | базовый | Метаболическая работа, больше подходов, средние диапазоны |
| Поздняя лютеиновая | Разгрузочный | −15% | +1 | Тренажёры и изоляция вместо технически сложной базы, диапазоны 10–15 |

Диапазоны повторов в столбце «Приоритет» («нижние», «средние», «10–15») пока не
применяются: `target_rep_min`/`target_rep_max` назначаются только по цели (§9.1).
Они вернутся вместе с полным закрытием §9.5, «Не реализовано (1 из 3)».

`defaultAdjustment[P]` для формулы готовности (§10): менструальная −0.10,
фолликулярная +0.05, овуляторная +0.05, ранняя лютеиновая 0.00, поздняя
лютеиновая −0.07. Личный профиль (§11.4) сдвигает эти значения, давая
`effectivePhaseAdjustment`.

**Таблица масштабируется уверенностью — так же, как поправка готовности.** Иначе
получалось бы, что при `cycleConfidence = 0.12` фаза даёт в готовность
пренебрежимые −0.012 и не показывается в интерфейсе, но планировщик всё равно
режет недельный объём на четверть. Категорическое вмешательство на сигнале,
которому мы сами не доверяем, — ровно то, что запрещает §11.3.

```
effectiveVolumeShift = volumeShift[P] × cycleConfidence
effectiveRIRShift    = round(rirShift[P] × cycleConfidence)
```

Округление — **к ближайшему, при ровной половине от нуля** (`.rounded()` в Swift,
не «банковское»). Названо явно, потому что режим по умолчанию зависит от языка:
банковское округление на `cycleConfidence = 0.5` дало бы 0 вместо ±1, то есть
фазовая поправка к RIR пропадала бы ровно на середине шкалы. Практический смысл
правила: поправка к RIR включается при `|rirShift × cycleConfidence| ≥ 0.5` и
одинаково для обоих знаков.

**Тип блока и приоритет упражнений — категории, их умножить не на что.** Они
меняются только при `cycleConfidence ≥ 0.3`; ниже порога блок нейтральный. Это
тот же порог, который разрешает интерфейсу назвать фазу (§11.3, §14.6), и то же
правило: расчёт может опираться на слабый сигнал, а категорическое утверждение о
пользовательнице — нет.

**Осторожность в овуляторную фазу.** Есть данные о повышенной слабости связок
на пике эстрогена и связи с травмами ПКС. Мы не делаем медицинских
утверждений, но планировщик в этой фазе снижает приоритет упражнений с
`impact = high` (§6.3).

Это **мягкий штраф в целевую функцию подбора, а не фильтр**: упражнение может
попасть в тренировку, если альтернатив нет. Жёсткие исключения остаются только
за травмами, инвентарём и флагами боли — фаза никогда не убирает упражнение
совсем.

Пользователю это не объясняется медицинскими терминами. Но и молча менять
подбор нельзя: §7.1 и §13.2 требуют объяснять каждое изменение рекомендации.
Разрешение — объяснять **действие, а не физиологию**: «В эти дни предлагаем
меньше прыжковых упражнений» с возможностью раскрыть подробнее. Скрывается
медицинская интерпретация, а не сам факт, что подбор изменился.

### 11.3 Предсказание и уверенность

Уверенность — число `0..1`, определяющее, насколько сильно фаза влияет:

```
cycleConfidence =
    dataFactor          // сколько циклов измерено
  × regularityFactor    // разброс длины
  × recencyFactor       // насколько мы в пределах ожидаемого окна

dataFactor:        0 циклов → 0.3
                   1 цикл  → 0.5
                   2 цикла → 0.7
                   3+      → 1.0

regularityFactor:  измерено ≥ 2 длин:  σ ≤ 2 дня        → 1.0
                                       2 < σ ≤ 5 дней   → 0.7
                                       σ > 5 дней        → 0.4
                   иначе по declared_regularity:  'regular'   → 1.0
                                                  'variable'  → 0.7
                                                  'irregular' → 0.4
                   если регулярность не заявлена → 1.0
                   ПОТОЛОК: если σ по НЕотфильтрованному окну > 2 дней → не выше 0.7

recencyFactor:     день ≤ ожидаемая длина                → 1.0
                   +1..+3 дня сверх ожидаемой            → 0.6
                   +4..+7 дней                           → 0.3
                   > +7 дней                             → 0.0
```

**Область подсчёта.** Три величины формулы оперируют разными по ширине
множествами измеренных циклов, и это не оговорка, а осознанное разделение:

- `dataFactor` считает **все** измеренные циклы за всё время (за вычетом
  перерывов длиннее 90 дней, см. ниже) — он отвечает на вопрос «сколько всего
  истории накоплено», а не «какой сейчас цикл ожидается», поэтому не привязан
  к окну LengthEstimator.
- `regularityFactor` (ветка σ) и `expectedLength` (среднее, см. §11.1) — обе
  считаются по **одному и тому же** отфильтрованному окну: последние 6 циклов
  за вычетом выбросов дальше 1.5 IQR (§11.3 ниже, «Скользящее среднее»).
  Иначе выброс, отброшенный из среднего, продолжал бы искусственно занижать
  регулярность — а обе величины описывают один и тот же прогноз, и должны
  быть согласованы. На выборке 28, 29, 27, 45, 28 (см. пример квартилей ниже)
  это даёт σ по {27, 28, 28, 29} — малое, `regularityFactor = 1.0`.

**Цикл — это интервал, а не событие.** Измеренный цикл — расстояние между двумя
соседними `period_start`; n событий дают n−1 циклов. Одна отметка начала
менструации — это ноль измеренных циклов, а не один: длину по ней вычислить
нельзя. Разница существенна ровно на холодном старте, где и живут все ошибки
этого модуля.

**Заявленное на онбординге работает, пока нет измеренного.** Длина цикла и
длительность менструации из `cycle_profiles` служат приором для §11.1, а
заявленная регулярность — источником `regularityFactor`, пока не набралось двух
измеренных длин (на одной длине σ не существует). Как только измерений
достаточно, заявленное перестаёт использоваться: наблюдение всегда сильнее
анкеты.

Отсюда холодный старт: `0.3 × 1.0 × 1.0 = 0.30` для заявившей регулярный цикл и
`0.3 × 0.4 × 1.0 = 0.12` для заявившей очень нерегулярный. Второй случай — это и
есть правильный ответ: фазовые рекомендации ей пока почти ничего не добавляют, и
показывать их с уверенным видом мы не будем.

**Опорной даты нет вовсе.** Отдельное состояние, не путать с нулём циклов: дата
последней менструации не введена (шаг онбординга пропущен, ответ «не сейчас»
либо онбординг прерван). День цикла неизвестен, фаза не вычисляется,
`cycleConfidence` не определён, `phaseTerm = 0`, `workouts.cycle_phase = null`.
Интерфейс показывает приглашение отметить начало менструации. Это не режим без
фаз (§11.5): режим остаётся `phases`, и одна отметка выводит из состояния.

**Влияние фазы непрерывно, порог — только про интерфейс.** Фазовая поправка
всегда умножается на `cycleConfidence` и никогда не обнуляется скачком:
при уверенности 0.12 менструальная фаза даёт −0.012, что и так пренебрежимо.
Разрыв в этой точке был бы хуже плавного затухания — он двигал бы
рекомендованный вес на ровном месте, при том что различие между «поправка
−0.03» и «поправка 0» пользователь не замечает, а скачок числа замечает сразу.

Порог `0.3` управляет **отображением**, а не расчётом. При
`cycleConfidence < 0.3` интерфейс показывает не фазу, а вопрос: «Месячные ещё не
начались? Отметьте, когда начнутся» — с кнопкой и с возможностью закрыть. Вес
чек-ина при этом растёт сам собой через `checkinScale` (§10).

Приложение **никогда не показывает фазу с уверенным видом, если не уверено**.
Это принцип, а не деталь. Пользователь, которому три цикла подряд говорили
неверную фазу, приложение удалит.

**Скользящее среднее.** Прогноз длины считается по последним 6 циклам с
отбрасыванием выбросов — значения дальше 1.5 IQR от квартилей.

Квартили считаются линейной интерполяцией по порядковым статистикам (метод,
принятый по умолчанию в R и NumPy). Метод указан явно, потому что на коротких
выборках разные определения квартилей дают разные границы, а решение «отбросить
или оставить» от них зависит: на выборке 27, 28, 28, 29, 45 получается
Q1 = 28, Q3 = 29, границы [26.5, 30.5], и 45 отбрасывается, а 27 остаётся.

**Полоса отбрасывания не уже, чем медиана ± 2 дня.** На вырожденных выборках
1.5 IQR схлопывается: если из шести циклов четыре одинаковы, IQR = 0, полоса
вырождается в точку, и всё, что не равно медиане, объявляется выбросом. У
пользовательницы с циклами 28, 28, 29, 27, 28, 28 так отбрасывались бы и 27, и
29 — при том что разброс в один день это ровно то, что таблица выше называет
регулярным. Поэтому полоса расширяется до медианы ± 2 дня. Это СВОЙ порог, а не
тот же, что «σ ≤ 2 дня → регулярно» из таблицы: там σ — разброс всего набора,
здесь — расстояние одного значения от медианы. Величины разные, совпадение
численное, и менять их следует независимо. На примере с квартилями выше
(27, 28, 28, 29, 45) это ничего не меняет по существу — границы становятся
[26, 30.5] вместо [26.5, 30.5], 45 по-прежнему отбрасывается, 27 остаётся.

**Фильтр улучшает прогноз, но не делает разброс регулярным.** σ считается по
отфильтрованному окну (см. «Область подсчёта»), и для ПРОГНОЗА это правильно:
выброс не должен портить среднее. Но у σ после фильтра есть свойство, которое
легко упустить — выброшенное значение делает остаток ТЕСНЕЕ обычного, поэтому σ
выходит не просто низкой, а близкой к нулю. У истории 28, 28, 28, 28, 28, 40
после отбрасывания 40 остаются пять одинаковых циклов и σ = 0.00: арифметический
максимум регулярности, неотличимый от той, у кого цикл не сдвигался ни на день.
Через `cycleConfidence` это идёт в силу фазовой поправки и в право интерфейса
назвать фазу — то есть приложение говорило бы уверенно ровно после того, как
промахнулось на двенадцать дней.

Поэтому `regularityFactor` ограничен сверху значением 0.7, когда σ по
НЕОТФИЛЬТРОВАННОМУ окну выходит за границу регулярного. Потолок меряет тем же,
чем меряет сама таблица — разбросом всего набора, — и потому не срабатывает там,
где таблица назвала бы историю регулярной: у 28, 28, 28, 28, 28, 31
неотфильтрованная σ = 1.12, потолка нет, хотя 31 из окна и выбывает. Ключевать
потолок на самом факте исключения нельзя: единственный цикл, отклонившийся на
3–5 дней, полосой исключается, но по σ всего набора история остаётся регулярной.

Потолок останавливается на 0.7 и не идёт следом за неотфильтрованной σ до 0.4:
на примере 27, 28, 28, 29, 45 она равна 6.83, то есть нижний разряд — тот же,
что у цикла, скачущего 45 / 20 / 44 / 21 / 46 / 19. Четыре ровных цикла и один
сбой — не то же самое. Фильтр своё дело делает, а потолок лишь запрещает верхнюю
ступень.

**Про независимость множителей.** На по-настоящему разбросанной истории потолок и
`predictionMissFactor` (§11.5) отвечают на один и тот же аномальный цикл: он и
снижает промах, и уводит σ набора за границу регулярного. Это принято
сознательно. В прежней версии, где потолок срабатывал на факт исключения, он
дотягивался и до одиночного отклонения в 3 дня: у дрейфующей
28, 28, 28, 32, 33, 34 набиралась серия §11.5 и режим фаз выключался на цикл.
Потолок по σ набора туда не дотягивается.

Цикл длиннее **90 дней** считается перерывом в записях, а не циклом: такой
интервал в среднее не входит и в `dataFactor` не засчитывается. Это отсекает
случай «не пользовалась приложением полгода, потом отметила начало» — иначе один
такой интервал испортил бы прогноз на месяцы вперёд.

### 11.4 Ручной оверрайд

Три кнопки на экране «Сегодня»: «Чувствую себя отлично» (`push`),
«Тяжёлый день» (`ease`), «Не сегодня» (`rest`).

**Семантика:**

- Оверрайд **полностью заменяет** фазовую поправку на этот день (§10,
  `phaseTerm`). Пользователь главнее модели — всегда.
- Оверрайд действует **один день** и сбрасывается в полночь.
- `push` не снимает ограничения безопасности: остаточное утомление (§8) и флаги
  боли (§8.4) продолжают действовать. Оверрайд управляет нагрузкой, а не
  безопасностью, и это гарантируется устройством конвейера (§10): готовность
  считается раньше, срезы утомления и флаги боли накладываются на её
  результат позже.
- Оверрайд доступен и в режиме без фаз, и когда опорной даты нет: на готовность
  он действует всегда. В обучение такой оверрайд не идёт — фазы, к которой его
  отнести, не существует.

**Обучение.** Система запоминает паттерн и корректирует личный профиль фазовой
реакции:

```
В полночь, по итоговому значению override за день, если фаза P известна:
    delta = override == .push ? +0.02
          : override == .ease ? −0.02
          : nil                              // rest не учится, см. ниже
    if delta != nil:
        profile[P].adjustment = clamp(profile[P].adjustment + delta, −0.15, +0.15)
        profile[P].sampleSize += 1

Применяется, начиная с sampleSize ≥ 3:
    effectivePhaseAdjustment = defaultAdjustment[P] + profile[P].adjustment
```

**Обучение применяется в полночь, а не в момент нажатия.** Иначе смена решения
внутри дня (нажала `push`, через час `ease`) сдвигала бы профиль дважды и в
разные стороны, и потребовался бы откат уже применённого. По итоговому значению
за день откат не нужен: `daily_checkins.override` — одна колонка на дату, и
последнее нажатие и есть ответ.

**`rest` в обучении не участвует.** «Не сегодня» — слишком шумный сигнал о
фазовой реакции: он означает работу, поездку, болезнь и просто нежелание
тренироваться заметно чаще, чем «в этой фазе мне тяжело». Учить по нему профиль
значило бы медленно занижать все фазы у всякой, кто пропускает тренировки по
причинам вне цикла. На готовность в день, когда тренировка всё же начата, `rest`
при этом действует (§10).

Три цикла подряд оверрайдит лютеиновую вверх — приложение перестаёт её резать
именно у неё. При этом об изменении сообщается явно: «Заметили, что в
лютеиновой фазе вы обычно чувствуете себя лучше средней статистики. Настроили
рекомендации под вас». Прозрачность обязательна: молча меняющаяся модель
воспринимается как непредсказуемость.

Сообщение показывается **один раз на фазу**, в момент, когда `sampleSize`
впервые достигает 3 и профиль начинает действовать; факт показа пишется в
`phase_response_profile.notified_at`. Повторять его при каждом следующем
оверрайде нельзя — обязательная прозрачность превращается в назойливость.

### 11.5 Режим «без фаз»

Включается, когда фаз объективно нет. Причина пишется в
`cycle_profiles.no_phase_reason` — от неё зависит, обратим ли режим сам:

| Причина | `no_phase_reason` | Как снимается |
|---|---|---|
| Гормональная контрацепция (КОК, ВМС с гормонами, имплант, инъекции) | `contraception` | Только вручную |
| Аменорея | `amenorrhea` | Только вручную |
| Перименопауза / менопауза | `menopause` | Только вручную |
| Беременность (см. §14.3 — там отдельная логика) | `pregnancy` | Только вручную |
| Пользователь выбрал «не отслеживать» | `user_choice` | Только вручную |
| Отказ отвечать про контрацепцию | `declined` | Только вручную, но можно переспросить позже |
| `cycleConfidence` ниже 0.3 три цикла подряд | `low_confidence` | **Автоматически**, как только цикл закрывается с уверенностью ≥ 0.3 |

Только `low_confidence` снимается сам: это утверждение о качестве наших данных,
и оно перестаёт быть верным, как только данные появились. Остальные — утверждения
о теле или о выборе пользователя, и отменять их за неё приложение не вправе.

Счётчик подряд идущих циклов живёт в `cycle_profiles.low_confidence_streak`:
инкрементируется на закрытии цикла (событие `period_start`, закрывающее интервал)
с уверенностью ниже 0.3, обнуляется на любом цикле с уверенностью ≥ 0.3.
Считается по закрытым циклам, а не по дням — иначе просрочка сама по себе, роняя
`recencyFactor` до нуля, за неделю загоняла бы в режим без фаз кого угодно.

**Каждое закрытие учитывается ровно один раз, и это свойство хранимого
состояния, а не обязанность вызывающего кода.** Рядом со счётчиком живёт
`cycle_profiles.low_confidence_counted_through` — дата `period_start`,
закрывшего последний учтённый цикл. Счётчик двигают только измеренные закрытия
СТРОГО ПОЗЖЕ этой даты, и она передвигается вместе с ним. Отсюда три следствия:

- Повторный вызов не считает ничего второй раз. Это не теоретическая
  осторожность: §4.3 — offline-first, одно и то же событие приходит дважды при
  пересинхронизации, и без отметки «докуда учтено» второй приход удваивал бы
  серию.
- Перерыв длиннее 90 дней не двигает счётчик вообще: это не измеренный цикл
  (§11.3), значит и закрытия, которое можно было бы учесть, в нём нет. Без
  отметки «докуда учтено» возвращение после перерыва пересчитывало бы последний
  ДОперерывный цикл заново — ровно у той пользовательницы, ради которой правило
  90 дней и введено.
- Ручное переключение режима (доступное в любой момент, см. ниже) сдвигает эту
  дату на день переключения и обнуляет счётчик. «Три подряд» после ручного
  включения фаз означает три закрытия ПОСЛЕ переключения: выбор пользовательницы
  не отменяется циклами, которые случились до него.

Задним числом внесённая отметка, разрезающая уже учтённый интервал (цикл 28
дней превращается в 14 + 14), оставляет прежний учёт как есть: отменить его мог
бы только пересчёт всей истории с нуля, а он затирал бы ручные переключения
режима. Осознанный предел точности, а не недосмотр.

**Уверенность на закрытии считается не так, как сегодняшняя.** `dataFactor` и
`regularityFactor` берутся по истории, включая только что закрывшийся цикл, а
третий множитель сравнивает его ФАКТИЧЕСКУЮ длину с той, что предсказывалась
ДО его начала (`expectedLength` по истории без него):

```
confidenceAtClose(цикл i) =
      dataFactor(измерено циклов, включая i)
    × regularityFactor(окно, включая i)
    × predictionMissFactor(|длина i − expectedLength по истории до i|)

predictionMissFactor:  промах 0 дней   → 1.0
                       промах 1–3 дня  → 0.6
                       промах 4–7 дней → 0.3
                       промах > 7 дней → 0.0
```

Иначе правило не срабатывает никогда. Если на закрытии считать этот множитель
равным 1 (свежая менструация по определению не просрочена), то с третьего
измеренного цикла `dataFactor` упирается в 1.0, `regularityFactor` не
опускается ниже 0.4, и любое закрытие даёт ≥ 0.40 — счётчик обнуляется на
каждом третьем шаге и до трёх не доходит. Проверено численно: максимум
достижимой серии в этом варианте — 2 (0.20 и 0.28 на первых двух закрытиях).

**Промах считается по модулю, в обе стороны.** Цикл, пришедший на две недели
раньше прогноза, говорит о непредсказуемости ровно то же, что и задержавшийся
на две недели: в обоих случаях мы предсказали неверно. Это тот же принцип, по
которому `regularityFactor` меряет σ, а не среднее отклонение вверх.

Односторонняя мера (только перебор) вдобавок вела себя неустойчиво на тех, ради
кого правило и существует: у пользовательницы с чередованием 20 / 45 / 20 / 45
короткие закрытия читались как «пришло вовремя» и обнуляли счётчик, поэтому
серия не набиралась никогда, хотя прогноз не сбылся ни разу. Проверено численно:
односторонний вариант на этом наборе до трёх не доходит, по модулю — доходит на
третьем закрытии.

`predictionMissFactor` — отдельная величина, а не `recencyFactor` из §11.3. У
`recencyFactor` направление одно и должно таким остаться: он про ЕЩЁ ОТКРЫТЫЙ
цикл, где «раньше» не наблюдаемо в принципе — день цикла просто ещё не дошёл до
прогноза. Считать там по модулю значило бы, что на пятый день цикла при прогнозе
28 промах равен 23 дням и уверенность падает в ноль почти у всех и почти всегда.
Ступени (0 / 1–3 / 4–7 / > 7) у обеих величин общие.

В этом режиме:

- фазовый блок в UI отсутствует полностью (не «серый», а отсутствует)
- `phaseTerm` считается только по оверрайду; фазовой составляющей нет
- вес готовности целиком переносится на ежедневный чек-ин: `checkinScale = 1.6`,
  диапазон `checkinAdjustment` становится −0.19..+0.19. Это то же значение, к
  которому §10 приходит непрерывно при `cycleConfidence → 0`: режим без фаз —
  предельный случай общей формулы, а не отдельная ветка расчёта
- планировщик использует классическую недельную периодизацию: три недели
  накопления, одна разгрузочная. Какая неделя разгрузочная, сам планировщик не
  считает: признак он получает на вход от вызывающей стороны, как срез
  упражнений (§7.5). Правило счёта — календарный цикл или накопленное
  утомление — открыто (§19.2, п.4).

**Формулировка вопроса про контрацепцию** должна быть нейтральной и объясняющей,
а не выпытывающей:

> «Гормональная контрацепция подавляет естественные колебания цикла — фазы в
> привычном смысле при ней отсутствуют. Чтобы не давать вам неверные
> рекомендации, нам важно это знать.
> [Принимаю гормональную контрацепцию] [Нет] [Не хочу отвечать]»

«Не хочу отвечать» → режим без фаз с `no_phase_reason = 'declined'`. Отказ
отвечать не должен приводить к худшему продукту. Причина хранится отдельно от
`user_choice` именно потому, что это не отказ от фаз, а отказ от вопроса: к нему
допустимо вернуться однократно позже, к явному «не отслеживать» — нет.

Переключение режима доступно в настройках в любой момент, без потери истории.

---

## 12. Растяжка и мобильность

Полноценный раздел (второй таб). Два типа контента:

### 12.1 Динамическая мобильность (разминка)

- 5–8 минут, генерируется под сегодняшнюю тренировку
- Подбор по мышцам и паттернам, которые будут в тренировке
- Предлагается на экране тренировки перед первым упражнением, пропускается
  одним тапом

### 12.2 Статическая растяжка (заминка и самостоятельные сессии)

**Автозаминка:** 3–5 растяжек по фактически проработанным мышцам, предлагается
на экране завершения тренировки.

**Самостоятельные сессии** — готовые шаблоны:

| Шаблон | Длит. | Назначение |
|---|---|---|
| Утренняя мобильность | 7 мин | Общая, после сна |
| Вечерняя расслабляющая | 10 мин | Парасимпатика перед сном |
| Шея и грудной отдел | 8 мин | Для сидячей работы |
| Раскрытие бёдер | 12 мин | Приводящие, сгибатели бедра |
| Поясница и таз | 10 мин | После тяжёлого дня ног |
| Для менструальной фазы | 12 мин | Мягкие позы, без инверсий и глубокого пресса |
| Полная растяжка | 20 мин | Всё тело |

**UX сессии:** одна поза на экран, крупный таймер, автопереход по истечении,
кнопки «+15 сек» и «пропустить», голосовые подсказки о смене стороны
(опционально), экран не гаснет. Никакого ввода данных — растяжка не логируется
подходами.

Растяжка учитывается в стрике активности, но не в недельном объёме нагрузки.

---

## 13. Экраны и UX

### 13.1 Карта экранов

```
Таб-бар: Сегодня | Тренировки | Растяжка | Прогресс | Профиль

Сегодня
  ├── Карточка дня (тип тренировки, фаза, готовность)
  ├── Ежедневный чек-ин (сворачиваемый)
  ├── Кнопки оверрайда
  ├── Кнопка «Начать»
  └── Недельный план (горизонтальная лента 7 дней)

Тренировка (полноэкранный модальный флоу)
  ├── Разминка (пропускаемая)
  ├── Экран упражнения (главный экран продукта)
  ├── Экран отдыха с таймером
  ├── Замена упражнения
  └── Завершение → предложение заминки → сводка

Растяжка
  ├── Шаблоны сессий
  ├── Проигрыватель сессии
  └── История

Прогресс
  ├── Объём по неделям и мышечным группам
  ├── График базовой линии по упражнению
  ├── Календарь активности + стрик
  └── Наложение фаз цикла на графики (если режим с фазами)

Профиль
  ├── Личные данные
  ├── Инвентарь (несколько профилей)
  ├── Ограничения и травмы
  ├── Настройки цикла
  ├── Аккаунт (линковка Apple ID)
  ├── Экспорт данных
  └── Удаление аккаунта
```

### 13.2 Экран упражнения — зафиксированные решения

Это экран, где пользователь проводит 90% времени. Проектируется под потную руку,
одну руку и плохое освещение.

- **Одна главная цифра** — рекомендованный вес, крупно. Повторы — второй по
  величине элемент.
- **Ввод факта:** повторы и вес предзаполнены рекомендацией. Изменение —
  тапами по «−»/«+», не клавиатурой. Шаг «+» = реальный шаг инвентаря.
- **Фидбэк:** четыре крупные кнопки в ряд внизу, зона большого пальца. Минимум
  44×44 pt, по факту — во всю ширину, высота 64 pt.
- **Один тап на подход.** Если веса и повторы совпали с планом, пользователь
  жмёт только кнопку фидбэка. Это должно быть возможно.
- **Флаг боли** — отдельная маленькая кнопка в углу, визуально отличная от
  фидбэка. Никогда не в одном ряду с «тяжело».
- **Изменение рекомендации показывается явно.** Если после фидбэка следующий
  подход стал легче, пользователь видит: «68 кг → 62 кг» с короткой причиной.
  Немотивированное изменение чисел разрушает доверие.
- **Экран не гаснет** во время тренировки.

### 13.3 Таймер отдыха

- Стартует автоматически после логирования подхода
- Длительность — `default_rest_seconds` упражнения × множитель готовности:
  ниже 0.9 — ×1.2, выше 1.05 — ×0.8, иначе ×1.0. Границы строгие, те же, что у
  ±1 подхода на сессию (§10); новых порогов не вводим. Это ровно та величина,
  которую складывает бюджет времени §7.3: таймер и планировщик обязаны читать
  одно правило, иначе тренировка, посчитанная на двадцать минут, идёт двадцать
  четыре
- Фидбэк «тяжело» → +30 сек. В бюджет §7.3 эта надбавка не входит: на момент
  сборки её знать нельзя (§7.3, «внутрисессионные поправки»)
- **Live Activity:** на локскрине и в Dynamic Island. Телефон можно убрать в
  карман. **Только iOS:** на вебе эквивалента нет и он не эмулируется — там
  таймер сигналит звуком и вибрацией и считается от абсолютной метки времени
  (§20.12)
- Виброуведомление за 10 сек и по окончании
- Кнопки «+30 сек» и «Пропустить»
- Таймер не блокирует интерфейс: можно начать следующий подход раньше

### 13.4 Замена упражнения в один тап

Кнопка на экране упражнения. Показывает 3 альтернативы, отсортированные по
близости профиля вклада мышц, с указанием причины пригодности («тот же акцент
на ягодицы, без нагрузки на колено»). Причины замены логируются
(`substitution_reason`) — это ценные данные о том, где библиотека не
соответствует реальности залов.

Прогресс переносится, если упражнения одной `progression_family`, иначе новое
упражнение стартует в калибровке.

Вес при переносе пересчитывается через `family_load_ratio` (§6.3) и
округляется вниз до достижимого:

```
baseline_kg(новое) = roundToAchievable(baseline_kg(старое) × ratio(новое) / ratio(старое), вниз)
```

Вниз — по той же причине, что стартовый ×0.6 калибровки (§9.8): ошибка
пересчёта должна давать недогруз, а не перегруз. Пересчёт определён, только
когда вес есть у обоих упражнений и `family_load_ratio` задан у обоих; иначе вес
не переносится и новое упражнение стартует в калибровке — как при замене вне
семьи. Значения по умолчанию у поля нет: подставленная 1.0 перенесла бы вес
штанги на гантель как есть, а законно поля нет только у семьи из одного
упражнения, где переносить не на что. Если его нет в семье больше чем из одного
упражнения, это ошибка разметки, и ловит её валидатор (§19.1), а не
планировщик.

### 13.5 Тон

- Никакого фитнес-морализаторства, стыда за пропуски, «ты сможешь!» и
  восклицательных знаков.
- Пропущенная тренировка констатируется нейтрально, без счётчика провалов.
- Стрик существует, но его потеря не драматизируется.
- Объяснения решений алгоритма — всегда конкретны: не «сегодня полегче»,
  а «ягодицы ещё не восстановились после вторника».
- Про цикл — фактически и без эвфемизмов, но и без клинического тона.

### 13.6 Уведомления

Минимально. Только: напоминание о запланированной тренировке (время
настраивается, по умолчанию выключено) и напоминание отметить начало
менструации, когда прогноз просрочен на 2+ дня (только если цикл-режим
активен). Никаких мотивационных пушей.

Второе уведомление подчиняется §14.6 наравне с экранными формулировками, и
строже: текст на локскрине виден посторонним, а прогноз, на котором оно
основано, к этому моменту уже потерял уверенность (`recencyFactor` = 0.6 или
ниже). Поэтому оно спрашивает, а не сообщает, и не называет предмет: «Отметить
начало цикла?» — но не «У вас задержка 3 дня». По умолчанию выключено, как и
первое.

---

## 14. Безопасность, приватность, юридика

### 14.1 PAR-Q

Семь стандартных вопросов (PAR-Q+, сокращённая форма) на онбординге. Любое
«да» = красный флаг:

1. Говорил ли врач, что у вас есть заболевание сердца и физическая
   активность допустима только по рекомендации врача?
2. Бывает ли у вас боль в груди при физической нагрузке?
3. Была ли у вас боль в груди в состоянии покоя за последний месяц?
4. Теряете ли вы равновесие из-за головокружения или теряли ли сознание?
5. Есть ли у вас проблемы с костями или суставами, которые могут ухудшиться
   при физической нагрузке?
6. Назначал ли врач лекарства от давления или заболеваний сердца?
7. Знаете ли вы другую причину, по которой вам не следует заниматься?

**При красном флаге:** экран с рекомендацией проконсультироваться с врачом,
явное подтверждение пользователя, и включение консервативного режима —
стартовые веса ×0.7, целевой RIR +1 (сверх потолка §10, как надбавка
утомления), исключение упражнений с
`joint_stress: high`, `skill_level` ограничен уровнем `novice`.

Не блокируем доступ. Блокировка приведёт к тому, что пользователь просто
ответит «нет» на все вопросы.

### 14.2 Дисклеймер

Отдельный экран на онбординге, доступен из профиля. Смысл: приложение не
является медицинским изделием, не заменяет консультацию врача, рекомендации
носят информационный характер, при боли или недомогании следует прекратить
занятие. Требуется явное подтверждение (не чекбокс мелким шрифтом).

Формулировка согласовывается с юристом до сабмита.

### 14.3 Беременность и послеродовой период — out of scope

Явно и честно. Если пользователь отмечает беременность:

1. Цикл-модуль отключается полностью.
2. Показывается чёткое сообщение: программы приложения не рассчитаны на
   беременность и послеродовой период, рекомендуется программа от специалиста.
3. Приложение остаётся доступным как трекер (можно логировать тренировки), но
   **генератор тренировок отключается** — приложение не предлагает нагрузку.

Это дешевле и безопаснее, чем делать пренатальные программы плохо.

### 14.4 Карта травм

Профиль хранит ограничения по суставам (`avoid` / `careful`). Фильтрация:

- `avoid` → исключаются упражнения с `joint_stress[joint] ∈ {high, medium}`
- `careful` → исключаются только `high`; `medium` и `low` подбираются на общих
  основаниях

У `careful` нет мягкого «пониженного приоритета». Такого слагаемого нет в
целевой функции §7.3, а без веса, проверенного прогоном, приоритет ничего не
значит. Разница между уровнями — в ширине жёсткого исключения: `avoid`
захватывает на одну ступень больше.

Ограничения можно добавлять и снимать в любой момент, в том числе прямо из
диалога флага боли.

### 14.5 Приватность и данные

**Данные о цикле — самая чувствительная категория.** Правила:

- Данные цикла хранятся в отдельных таблицах с RLS, не смешиваются с
  аналитическими полями.
- В аналитику (§16) **никогда не отправляются**: данные цикла, вес тела, рост,
  ответы PAR-Q, ограничения, содержимое чек-инов. Только агрегаты уровня
  «тренировка завершена», «использована замена упражнения».
- Аналитика — самописные события в собственную таблицу Supabase, без сторонних
  SDK. Никакого Facebook SDK, никаких рекламных идентификаторов.
- App Privacy в App Store Connect заполняется честно: категория Health &
  Fitness, данные привязаны к пользователю, не используются для трекинга.

**Обязательные экраны (требования App Store):**

- Политика конфиденциальности (ссылка в приложении и в App Store Connect)
- **Удаление аккаунта из приложения** — обязательно с 2022 года. Реальное
  удаление всех данных, не деактивация. Каскадное удаление через
  `on delete cascade` + вызов Edge Function.
- Экспорт данных в JSON и CSV (требование GDPR, полезно и само по себе)

### 14.6 Формулировки про цикл

Приложение не утверждает медицинских фактов. Разница существенна:

- Плохо: «В лютеиновой фазе снижается сила, поэтому вам нужно снизить вес».
- Хорошо: «Многие отмечают спад в этой фазе. Мы предлагаем работать чуть
  легче — если чувствуете себя иначе, скажите нам».

Доказательная база фазовых эффектов слабая и противоречивая (метаанализы не
находят убедительного эффекта фазы на силовые показатели). Приложение подаёт
фазовую периодизацию как **разумную настройку по умолчанию, которую можно
переопределить**, и активно учится у конкретной пользовательницы (§11.4). Это и
корректнее научно, и безопаснее для ревью.

Правило распространяется на все каналы, а не только на экраны: push-уведомления
(§13.6), сводки, экспорт данных.

**Неопределённость должна быть машиночитаемой.** Мягкость формулировки не может
быть единственной защитой: строка живёт в локализации, её меняет кто угодно и
когда угодно, и ничто в архитектуре не мешает написать утвердительный вариант.
Поэтому `FitCore` отдаёт наружу не готовый текст, а причину с уверенностью:
всякий `ReasonCode` фазового происхождения несёт `cycleConfidence`, при котором
он выдан. Слой представления обязан этим значением воспользоваться — предъявить
рекомендацию как предположение и тем заметнее, чем ниже уверенность.

Отсюда же порог 0.3 из §11.3: он не влияет на расчёт, он определяет, вправе ли
интерфейс вообще назвать фазу. Расчёт может опираться на слабый сигнал, а
утверждение о теле пользователя — нет.

---

## 15. HealthKit (версия 2)

Отложено из MVP, но модель данных подготовлена: у `cycle_events` и
`body_weight_entries` есть поле `source`.

Планируемое чтение:

| Тип | Использование |
|---|---|
| `HKCategoryTypeIdentifier.menstrualFlow` | Автоматическое определение начала и конца менструации |
| `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | `recoveryAdjustment` в формуле готовности |
| `HKCategoryTypeIdentifier.sleepAnalysis` | `recoveryAdjustment` |
| `HKQuantityTypeIdentifier.bodyMass` | Автозаполнение веса тела |
| `HKQuantityTypeIdentifier.restingHeartRate` | Дополнительный сигнал восстановления |

Запись: `HKWorkoutTypeIdentifier.traditionalStrengthTraining` — тренировки
появляются в приложении «Здоровье».

**Требования к реализации:**

- Разрешения запрашиваются точечно, в момент, когда фича нужна, а не на
  онбординге пачкой.
- `menstrualFlow` требует отдельного разрешения и отдельного обоснования в
  `NSHealthShareUsageDescription`.
- Приложение обязано корректно работать при отказе в любом разрешении —
  ручной ввод остаётся всегда.
- HealthKit не сообщает об отказе (для приватности запрос на чтение при
  отсутствии разрешения возвращает пустой результат, а не ошибку). Значит,
  «нет данных» и «нет разрешения» неразличимы — интерфейс должен обрабатывать
  оба случая одинаково мягко.
- Данные HealthKit **не выгружаются на сервер** без отдельного явного согласия.
  Это прямое требование App Store Review Guidelines 5.1.3.

`recoveryAdjustment` в формуле готовности (§10) при появлении данных:

```
recoveryAdjustment =
    hrvDeviationFactor × 0.04     // отклонение от личного 30-дневного базиса
  + sleepDebtFactor    × 0.03
```

С теми же принципами: применяется с коэффициентом уверенности, требует минимум
14 дней данных для установления базиса, деградирует в ноль при разрывах.

---

## 16. Метрики продукта

Что измеряем (агрегаты, без персональных health-данных):

| Метрика | Зачем |
|---|---|
| Завершение онбординга | Экран инвентаря — главный подозреваемый на отвал |
| Доля завершённых тренировок от начатых | Если < 80%, тренировки слишком длинные или тяжёлые |
| Доля подходов с фидбэком | Если < 90%, экран подхода слишком сложный |
| Частота замен упражнений по причинам | `equipment` = дыры в библиотеке, `occupied` = плохой подбор для залов |
| Частота флагов боли по упражнениям | Прямой сигнал о проблемном упражнении в библиотеке |
| Retention D7 / D30 | Основная метрика здоровья продукта |
| Доля оверрайдов по фазам | Проверка гипотезы фазовой периодизации на реальных данных |
| Доля пользователей в режиме без фаз | Оценка размера аудитории на гормональной контрацепции |

Последние две — самые ценные. Через 3 месяца они покажут, работает ли фазовая
периодизация вообще или её надо ослаблять.

---

## 17. Этапы разработки

**Порядок изменён: веб — первая выпускаемая платформа, iOS идёт после** (§20.1).
Прежняя нумерация этапов 0–6 была целиком под iOS; ниже она разведена на общую
часть и два платформенных пути.

### Общая часть

**Этап 1 — Ядро алгоритма.** `Progression` (двойная прогрессия, округление по
инвентарю, расширение диапазонов, детренированность, калибровка), `Recovery`,
`Cycle`, `Readiness`, `Planner`, `Equipment`/`WeightLadder` и **полное тестовое
покрытие edge cases** (§18). От платформы не зависит, и от него зависит всё
остальное.

**Этап 2 — Контент.** Разметка упражнений (JSON + валидатор схемы), таблица
целевых векторов, 7 шаблонов растяжки, изображения. Валидатор проверяет: сумма
вкладов ≈ 1.0, наличие альтернатив, покрытие всех комбинаций (тип дня × акцент ×
уровень инвентаря) минимум тремя упражнениями, правила целевых векторов (§7.3),
обязательность `family_load_ratio` в семье больше чем из одного упражнения.
Объём к запуску веба — срез по §20.11, а не все 60–80.

### Веб-путь

**Этап В0 — Фундамент.** Схема Supabase + миграции + RLS + интеграционный тест
изоляции; каркас `Server/` (Vapor, пул `postgres-nio`, проверка JWT по JWKS,
подстановка claims в транзакцию); каркас `Web/`; дизайн-токены из общего
источника; деплой на VPS с Caddy и раздачей SPA с того же origin.

**Этап В1 — Аккаунт и онбординг.** Анонимный вход, email magic link, обязательная
линковка до первой тренировки; все экраны онбординга, включая PAR-Q и экран
инвентаря; профиль, инвентарь, ограничения, настройки цикла.

**Этап В2 — План и тренировка.** Генерация недельного плана и пересборка; сборка
тренировки; экран «Сегодня», чек-ин, оверрайды; экран тренировки, таймер отдыха
с Wake Lock, замена упражнения, флаг боли, дерево решений §20.9.

**Этап В3 — Растяжка и прогресс.** Раздел растяжки, проигрыватель сессий,
автозаминка; экраны прогресса и графики, включая наложение фаз цикла.

**Этап В4 — Готовность к запуску.** Экспорт и удаление данных; политика
конфиденциальности, дисклеймеры; полевое тестирование в реальном зале
(обязательно — экран тренировки нельзя проверить за столом); доступность:
контраст, масштабируемый текст, скринридер на экране тренировки.

### iOS-путь (после веба)

**Этап I0 — FitData.** SwiftData-модели, репозитории, слой синхронизации §4.3,
офлайн-режим. Это то, ради чего iOS-версия и существует отдельно от веба.

**Этап I1 — Экраны.** Перенос экранов §13, Live Activity, уведомления §13.6.

**Этап I2 — Релиз.** Экспорт и удаление в интерфейсе приложения, App Privacy в
App Store Connect, TestFlight, ревью.

### Отложено на после MVP

- HealthKit (§15)
- Видео-демонстрации упражнений
- Монетизация: StoreKit 2, подписка, paywall, пробный период
- Английская локализация и фунты
- watchOS-приложение
- Android
- Web Push и уведомления §13.6 на вебе
- Широкая десктопная вёрстка (§20.12)
- Перезаказ единого набора иллюстраций (§6.5, §20.11)

---

## 18. Обязательные тесты edge cases

Список сценариев, которые `FitCore` обязан обрабатывать. Каждый — отдельный
тест.

**Прогрессия:**

1. Гантели 2/4/6/8 кг, пользователь на 6 кг выполняет верх диапазона →
   расширение диапазона, не прыжок на 8
2. Расширение исчерпано (rep_extension = 4) → прыжок на 8 кг с сбросом повторов
3. Максимальная гантель достигнута, верх диапазона выполнен → рост повторами,
   затем подходами, затем предложение сложного варианта
4. Упражнение с собственным весом, 30 повторов легко → переход на вариант
   потяжелее
5. Два `failed` подряд → досрочное завершение упражнения: оставшиеся подходы
   помечены `sets.skipped = true`, `target_sets` остальных упражнений
   тренировки не меняются, объём никуда не переносится (§9.3)
6. `failed` в первом подходе → корректные веса для оставшихся трёх
7. Перерыв 3 дня / 15 дней / 30 дней / 60 дней → корректные множители
8. Три сессии застоя → deload; шесть → предложение замены
9. Фидбэк «легко» при повторах ниже `rep_min` (пользователь сам снизил вес) →
   не повышаем
10. Пользователь ввёл вес выше рекомендованного и «нормально» → базовая линия
    поднимается
11. Пользователь ввёл вес ниже рекомендованного и «тяжело» → базовая линия
    понижается, но с учётом того, что вес уже был снижен
12. Readiness 0.8, фидбэк «тяжело» → демпфирование обновления базовой линии
13. Отрицательный или нулевой вес на входе → не крешится, возвращает минимум
14. Пустой инвентарь (нет ничего) → подбор упражнений с собственным весом

**Цикл:**

15. Ноль измеренных циклов, заявлена регулярность `regular` → `confidence = 0.30`,
    фаза показывается; заявлена `irregular` → `confidence = 0.12`, фаза не
    показывается, но поправка не обнуляется, а масштабируется
16. Задержка 3 дня → `confidence` падает, поправки ослабевают непрерывно
17. Задержка 10 дней → `recencyFactor = 0`, фаза не показывается, предложение
    отметить начало
18. Цикл 21 день / 45 дней → корректные границы фаз
19. Записи циклов: 28, 29, 27, 45, 28 → выброс отброшен из среднего
20. Переключение с режима фаз на режим без фаз и обратно → история сохранена
21. Начало менструации отмечено задним числом → фазы пересчитаны, недельный план
    пересобран
22. Две записи `period_start` в один день → идемпотентность
23. Оверрайд `push` в менструальную фазу → фазовая поправка полностью заменена,
    а не сложена с ней
24. Три оверрайда `push` в лютеиновой → профиль сдвинулся, уведомление показано
    один раз
25. Оверрайд `push` при переутомлении мышцы → защита утомления НЕ снята
26. Беременность отмечена → генератор отключён, цикл-модуль отключён

Добавлены при правке §10/§11 (буквенные номера, чтобы не сдвигать ссылки на
15–26):

- 15a. Опорной даты нет вовсе (шаг онбординга пропущен) → фаза не вычисляется,
  `phaseTerm = 0`, режим остаётся `phases`, одна отметка выводит из состояния
- 15b. Один `period_start` → это ноль измеренных циклов, не один
- 18a. Цикл 21 день → фолликулярная схлопывается в ноль дней, фазы не
  пересекаются, покрытие дней сплошное
- 19a. Интервал 120 дней → перерыв, не цикл: в среднее не входит, в `dataFactor`
  не засчитывается
- 23a. Оверрайд в режиме без фаз и при отсутствии опорной даты → на готовность
  действует, в обучение не идёт
- 23b. `push`, затем `ease` в тот же день → профиль сдвинут один раз, по
  итоговому значению
- 23c. `rest` в любой фазе → профиль не сдвинут, `sampleSize` не вырос
- 24a. `checkinScale`: при `confidence = 1.0` → ×1.0, при 0 → ×1.6, в режиме без
  фаз → ×1.6 (непрерывная стыковка с §11.5)
- 24b. `cycleConfidence = 0.12`, менструальная фаза → объём режется на 3%, а не
  на 25%; тип блока нейтральный, фаза в интерфейсе не названа
- 24c. `cycleConfidence = 0.5`, `rirShift = ±1` → поправка к RIR равна ±1
  (округление от нуля), а не 0
- 25a. Поздняя лютеиновая (RIR +1) при `readiness < 0.85` (ещё +1) → суммарная
  надбавка к RIR не больше +1; та же связка при невосстановленной мышце (§8.2) →
  надбавка утомления добавляется сверх
- 25b. Композиция объёма на восьми случаях §10, включая режим без фаз: свежая +
  ранняя лютеиновая → 1.15; свежая + менструальная → 0.75; утомлённая +
  менструальная → 0.70; утомлённая + ранняя лютеиновая → 0.70; частично
  утомлённая + менструальная → 0.75; разгрузочная неделя + свежая мышца → 0.85;
  разгрузочная неделя + сильно утомлённая мышца → 0.70 (не 0.595); разгрузочная
  неделя + частично утомлённая → 0.85
- 25c. Опорной даты нет → `checkinScale = 1.6`, готовность вычислима

**Планировщик:**

27. Ягодицы 5 дней подряд → объём режется, паттерны меняются, не блокируется
28. Инвентарь только резинки, акцент ягодицы → непустая тренировка
29. `session_minutes = 20` → тренировка укладывается, 3–4 упражнения
30. Все упражнения на квадрицепс исключены травмой колена → тренировка низа
    собирается из шарнирных движений
31. Смена фазы посреди недели → пересобраны только будущие дни
32. Пропуск двух тренировок подряд → оставшиеся дни пересобраны, объём не
    «догоняется» компенсаторно: `S_эфф` оставшихся сессий не вырос, недельный
    итог равен сумме запланированных долей выполненных сессий (§7.3)
33. Начатая тренировка + триггер пересборки → тренировка не тронута

**Синхронизация:**

34. Полностью офлайн-тренировка → всё сохранено, выгружено при появлении сети
35. Конфликт `exercise_states` → пересчёт из истории подходов
36. Линковка Apple ID к анонимному аккаунту → `auth.uid()` не изменился, данные
    на месте
37. Два устройства, одна тренировка на каждом → обе сохранены, состояния сошлись

Добавлены при закрытии §7.3/§7.4 (буквенные номера, чтобы не сдвигать ссылки на
27–37):

- 27a. Пять дней ягодиц подряд → недельный эффективный объём `glute_max` не выше
  потолка §7.4, состав меняется день ко дню, ни один день не пустой
- 30a. Доступно меньше трёх паттернов (травма колена в день низа) → требование
  ослаблено до доступного числа с причиной; ограничения безопасности не тронуты
- 31a. Равномерная плановая поправка объёма (фаза, разгрузочная неделя) → состав
  упражнений тот же, меняются только `target_sets`; смена типа блока состав
  менять вправе
- 33a. Детерминизм: тот же вход и тот же seed → та же тренировка; перестановка
  упражнений во входном срезе результата не меняет

Добавлены при закрытии формулы времени (§7.3):

- 29a. Бюджета не хватает на три паттерна (`session_minutes = 14`) → требование
  ослаблено ПО ВРЕМЕНИ, с `ReasonCode`, отличимым от ослабления по доступности
  (сценарий 30a); бюджет не превышен, тренировка не пуста. При 8 минутах —
  одно упражнение
- 29b. Односторонние упражнения → подход стоит вдвое дороже по работе, чем
  двусторонний с тем же `setup_seconds` и тем же `default_rest_seconds`, и в
  тот же бюджет их помещается меньше; учёт объёма §7.4 при этом не меняется

Добавлены при закрытии перебалансировки по пропуску (§7.1, §7.3):

- 32a. Пропущен день другого типа (день верха в неделе низ/верх/низ) → у дней
  низа не изменился ни один `target_sets`, строка «План обновлён» не показана,
  строки статуса недели по ягодичным тоже нет: потеря равна нулю
- 32b. Пропущен последний день недели → пересобирать нечего, `S_эфф` оставшихся
  не пересчитывается, «План обновлён» не показан; строка статуса недели показана
- 32c. Пропуск в последний день недели W → `S_эфф` недели W+1 не изменился: долг
  через границу недели не переносится, в отличие от утомления (§8.1) и
  детренированности (§9.7), которые переносятся по истории
- 32d. Тип и акцент оставшихся дней после пропуска не изменились: пропущенный
  день низа не превращает запланированный день верха в день низа
- 32e. Пересборка после пропуска, вызванная трижды подряд с неизменившимся
  входом → тот же план и та же `неделя[m]`; идемпотентность по построению, без
  отметки учёта (прямой аналог §11.5)

Добавлены при закрытии целевых векторов и покрытия (§7.1, §7.3):

- 27b. Плоский вектор full body (десять мышц по 0.10), 2 дня × 45 минут → ни
  одна мышца вектора не остаётся за неделю без эффективного подхода
- 27c. День «низ с акцентом на ягодицы», 60, 45 и 30 минут → недельный
  `glute_max` тот же, что без слагаемого w11: взвешенное кубом доли, оно не
  забирает акцентный день ради мышц с долей 0.06
- 27d. Неделя верх / низ с акцентом / full body → при 30 минутах в дне низа с
  акцентом не появляется упражнение, взятое ради икр (доля 0.06); при 60 и 45
  минутах мышц вектора без единого эффективного подхода за неделю не больше, чем
  без w11
- 27e. Неделя верх / низ с акцентом / full body, вектор full body плоский →
  `S_эфф` дня full body не зависит от порядка мышц в векторе (20.0, ведёт
  `glute_max`); неделя «низ с акцентом + низ без акцента» даёт 13.69 эффективного
  подхода на `glute_max` за неделю
- 29c. `session_minutes` ограничивает сборку → строка статуса недели называет
  недобор по времени отдельно от пропуска; при бюджете, который сборку не
  ограничивает, строки нет

Добавлены при закрытии повторов, RIR и сетки (§7.2, §9.1):

- 27f. Цель `hypertrophy` без поправок: новичок → `target_rir = 2`, средний → 1;
  `rep_extension = 2` → `target_rep_max = 14`; цель `general` → 10–15, RIR как у
  тонуса; консервативный режим при поздней лютеиновой и `readiness < 0.85` →
  надбавка +2 к базе, а не +1
- 27g. Сетка: 3 дня — новичок full body ×3, средний верх / низ / full body;
  5 дней — верх / низ / верх / низ / full body; 6 дней — пуш / пул / ноги /
  верх / низ + растяжка; 7 дней — пуш / пул / ноги ×2 + растяжка; растяжка —
  последний выбранный день; у всех дней `accent_muscle` пустой

Добавлены при закрытии будущих дней и колонки §7.4 (§7.1, §7.3, §7.4):

- 27h. Колонка §7.4 по сессии: неделя «низ с акцентом + низ без акцента», средний
  уровень → `S_эфф` дня с акцентом 24.62 (норма 16), дня без акцента 15.38 (ведёт
  `glute_max` с нормой 10); потолок `glute_max` в дне с акцентом — 20, в дне без
  акцента — 16, оба против недельной суммы
- 31b. Будущий день от замороженного состояния → предпросмотр завтрашнего дня не
  учитывает утомление сегодняшней тренировки, пока она не выполнена; check-in и
  оверрайд сегодняшнего дня предпросмотр завтрашнего не меняют; фаза и плановый
  срез завтрашнего дня — по его дате
- 31c. Выполненная тренировка → оставшиеся дни пересобраны от нового состояния;
  «План обновлён» — только если у них изменился состав или объём; `S_эфф` тот же

Добавлены при закрытии курсора pull и порядка применения (§3.1, §3.3, §4.3):

- 34a. Строка, записанная устройством с отстающими часами, доезжает до второй
  реплики: курсор по `sync_seq` её отдаёт, курсор по клиентскому `updated_at` —
  нет, потому что она приходит с отметкой ниже уже достигнутого курсора
- 35a. Один и тот же журнал, все перестановки порядка доставки → одно и то же
  `exercise_states` на обеих репликах; сравнивается полное состояние, включая
  `muscle_fatigue`
- 37a. Две тренировки одного упражнения в один календарный день, по одной на
  устройство → одинаковое состояние на обеих репликах при любом порядке
  доставки; сортировки по дню для этого недостаточно
- 37b. Тот же пакет доставлен дважды и разбит на пакеты разной длины → состояние
  не изменилось
- 37c. Изменён подход уже выгруженной тренировки → `sync_seq` родительской
  строки `workouts` сдвинут, и инкрементальный pull видит изменение
- 37d. Две версии одной строки с РАВНЫМИ `updated_at` с двух устройств → обе
  реплики оставляют одну и ту же версию (тай-брейк по `sync_seq`)

---

## 19. Известные риски и открытые вопросы

### 19.1 Риски

| Риск | Оценка | Смягчение |
|---|---|---|
| **Фазовая периодизация не работает** — доказательная база слабая, эффект может оказаться нулевым | Высокая вероятность, среднее влияние | Персонализация по оверрайдам (§11.4) делает систему самокорректирующейся. Метрика «доля оверрайдов по фазам» покажет правду за 3 месяца |
| **Ревью App Store** может придраться к health-функциям | Средняя | Осторожные формулировки (§14.6), явные дисклеймеры, отсутствие медицинских утверждений |
| **Качество разметки библиотеки** — алгоритм не лучше данных | Высокая | Валидатор схемы, приёмка разметки специалистом, метрика частоты замен |
| **Экран тренировки неудобен в реальном зале** | Средняя, высокое влияние | Обязательное полевое тестирование на этапе 6, не за столом |
| **Пересборка недельного плана воспринимается как баг** | Средняя | Обязательное объяснение каждой пересборки (§7.1) |
| **Потеря данных до линковки аккаунта** | Низкая, высокое влияние | iCloud Keychain sync токена, промпт после 3-й тренировки, экспорт |
| **Объём контента недооценён** — 60–80 упражнений с глубокой разметкой это недели работы | Высокая | Вынесено в отдельный этап 2, разметка параллельна разработке; к запуску веба идёт срез под правило покрытия (§20.11) |
| **Веб непригоден в зале с плохой связью** — офлайна нет по решению §20.10 | Средняя вероятность, высокое влияние | Дерево решений §20.9 снимает латентность, но не обрыв. Подвальный сценарий закрывает iOS-версия. Метрика — доля сессий, прерванных обрывом |
| **Латентность до Postgres на критическом пути каждого подхода** (§20.13) | Средняя | Регион VPS под регион Supabase, одно соединение и одна транзакция на запрос, замер p95 логирования подхода |
| **Потеря веб-аккаунта до линковки** — очистка данных сайта, инкогнито, ITP | Средняя, высокое влияние | Линковка обязательна до первой тренировки (§20.5), то есть незалинкованного аккаунта с историей не существует |

### 19.2 Открытые вопросы

1. **Иллюстрации:** заказывать у иллюстратора или искать лицензионный набор?
   Влияет на сроки этапа 2 и на бюджет. **Частично закрыт для веба:** к запуску
   идут изображения из проверенного открытого датасета с пофайловой проверкой
   лицензии (§6.5, §20.11), заказ единого набора остаётся планом и запуск больше
   не блокирует. Окончательно решается до перезаказа.
2. **Разметка вкладов мышц:** нужен ли специалист (тренер, кинезиолог) для
   приёмки? Ошибка в весах вклада ломает всю логику акцентов незаметно.
3. **Дефолтная длина отдыха** между подходами — **закрыт: 90 секунд** (§7.3,
   «Расчётное время»; §13.3). Это дефолт поля `default_rest_seconds` (§6.2):
   разметка поднимает его там, где есть причина — тяжёлая штанговая база 120,
   как в примере §6.2, — и опускает на изоляции. Номер пункта сохранён, чтобы не
   сдвигать ссылки на 4–13. Опасение «влияет сильнее, чем кажется»
   подтвердилось, но только на коротких сессиях: при 60 минутах сборка
   ограничена объёмом, а не временем, и 90 против 120 не меняет ничего; при 20
   минутах 90 даёт четыре упражнения и 8–9 подходов, 120 — три и семь (прогон на
   синтетике).
4. **Разгрузочная неделя в режиме без фаз** — каждые 4 недели или по накопленному
   утомлению? Второе технически честнее, но непредсказуемо для пользователя.
   Пока вопрос открыт, планировщик принимает признак разгрузочной недели на вход
   и сам его не считает (§11.5).
5. **Юрист** для проверки дисклеймера и политики конфиденциальности — когда
   подключаем? До этапа 6.
6. **Название приложения и бренд** — `fittrack-app` это рабочее имя каталога.
7. **Где живёт счётчик добавленных подходов** (`extraSetsAdded`, §9.5, шаг 2) —
   **закрыт: `exercise_states.extra_sets_added`** (§3.1, §9.5), часть состояния
   прогрессии, как `rep_extension`, и сбрасывается на тех же событиях. Не у
   планировщика: у него нет хранилища, из которого счётчик восстанавливался бы, —
   `target_sets` есть итог раскладки, базовое число подходов не записано, а план
   дня переписывается пересборкой (§7.1). Номер пункта сохранён, чтобы не
   сдвигать ссылки на 8–13.
8. **Какой сустав приписывать флагу боли** (§8.4, п.5), когда `joint_stress`
   упражнения содержит несколько суставов одинаковой степени? Сейчас берётся
   сустав с максимальной степенью нагрузки, а ничья разрешается порядком
   объявления из `user_restrictions.joint` (§3.1). Это делает результат
   детерминированным и одинаковым для всех вызывающих сторон, но клинического
   обоснования у такого приоритета нет: канонический пример §6.2
   (`hip_thrust_barbell`) даёт ровно такую ничью — `lower_back` и `hip` оба
   `medium`, — и выбор `lower_back` там ничем не лучше `hip`. Само упорядочение
   степеней (`low` < `medium` < `high`) в спеке тоже нигде не объявлено и
   выведено из §6.3/§14.4. Варианты: (а) объявить клинический приоритет
   суставов явным списком; (б) хранить у события боли все задействованные
   суставы, а не один, и считать п.5 по пересечению множеств; (в) спрашивать
   сустав у пользователя в диалоге флага боли (§14.4 уже допускает добавление
   ограничения оттуда). Отдельно требует решения по схеме: колонки под сустав
   события боли в §3.1 нет вовсе — ни в `sets`, ни отдельной таблицей.
9. **Затухание личного профиля фазовой реакции** (§11.4). Сейчас `sample_size`
   только растёт, а `adjustment` не возвращается к нулю: три оверрайда `push` в
   лютеиновой полгода назад сдвигают рекомендации навсегда, даже если с тех пор
   пользовательница ни разу не оверрайдила. Модель, которая учится, но не
   разучивается, со временем расходится с человеком. Варианты: (а) окно
   последних N оверрайдов вместо накопления; (б) экспоненциальное затухание
   `adjustment` по времени с момента последнего оверрайда; (в) сброс профиля при
   смене режима цикла. Отложено сознательно: до реальных данных неизвестно, с
   какой скоростью профиль должен забывать, а угаданная константа здесь хуже её
   отсутствия. Метрика «доля оверрайдов по фазам» (§16) — тот сигнал, по
   которому это решается.
10. **Разметка `impact`** (§6.3) по всей библиотеке. Поле введено ради
    овуляторного ограничения §11.2, но заполнять его нужно на всех 60–80
    упражнениях, и граница между `low` и `high` для неочевидных случаев (бёрпи,
    запрыгивания на тумбу, скакалка) требует того же специалиста, что и п.2.
    Решать вместе с приёмкой разметки на этапе 2.
11. **Словарь инвентаря упражнения** (§6.2, §7.5) — **закрыт: закрытый словарь
    требований с предикатами над колонками `equipment_profiles`** (§6.6). Веса в
    словарь не входят, их проверяет лестница (§9.5). Профиль остаётся колонками,
    а не тем же словарём: колонки весов нужны лестнице типизированными. Вход
    планировщика — два значения, `EquipmentProfile` и `EquipmentAvailability`, с
    контрактом «флаг главнее своего набора весов» (§7.5). Номер пункта сохранён,
    чтобы не сдвигать ссылки на 12–13.
12. **Целевые векторы для остальных типов дня** (§7.3) — **закрыт: вектор —
    вход планировщика.** Таблица (тип дня, акцент) → вектор живёт в `FitContent`
    и размечается на этапе 2; SPEC задаёт правила, которым обязан любой вектор, и
    слагаемое w11 против недельного обнуления мышц на широком векторе, которое
    нашёл прогон (§7.3). Правила «акцент преобразует вектор» нет: опубликованная
    пара им не воспроизводится. Числа векторов принимает тот же специалист, что и
    вклады (п.2). Номер пункта сохранён, чтобы не сдвигать ссылку на 13.
13. **С какой скоростью недельная норма растёт внутри диапазона §7.4?** Стартовая
    норма — нижняя граница, потолок — верхняя, но правила подъёма между ними нет.
    Классическое накопление (три недели вверх, одна разгрузочная) уже описано для
    режима без фаз (§11.5), в фазовом режиме роль разгрузки играет поздняя
    лютеиновая. Варианты: (а) шаг вверх за неделю без пропусков и без застоя
    (§9.4); (б) шаг по факту переносимости — средний фидбэк за неделю; (в) не
    поднимать вовсе до появления данных. Угаданная константа здесь хуже её
    отсутствия — та же логика, что в п.9.
14. **«Более сложный вариант» и «на поддержании»** (§9.5, пп.3–4). В
    `progression_family` не задано, что делает вариант сложнее: `skill_level`,
    `family_load_ratio` или отдельная разметка. Флаг «на поддержании» можно
    каждый раз выводить из состояния прогрессии и среза §7.5 либо хранить
    колонкой `exercise_states`. Пока вопрос открыт, слагаемое w10 (§7.3) равно
    нулю. Решать вместе с разметкой семей на этапе 2.
15. **Различать ли источник перерыва в §9.7?** Мягкая ступень детренированности
    (11–21 день, `baseline_kg × 0.92`) применяется по одному признаку — сколько
    дней прошло с последней сессии ЭТОГО упражнения. `rebuildStates` не знает,
    почему их не было: пользователь не тренировался вовсе или тренировался
    регулярно, а планировщик всё это время ставил на ту же мышцу другие
    упражнения (§7.3: состав меняется от утомления, слагаемого w6 и фазы —
    ротация внутри группы мышц штатная).

    Наблюдение из прогона, а не гипотеза: в шестинедельной симуляции
    пятидневной недели с акцентом на ягодицы упражнение с гантелями попадало в
    сборку примерно раз в две недели, и каждый возврат пересекал порог 11 дней.
    Базовая линия ушла с 8.0 до 6.6 кг за шесть недель при синтетическом
    фидбэке «нормально»: §9.4 поднимает вес на «легко», а «нормально» его только
    удерживает, и подъёма, который компенсировал бы ×0.92, не случалось ни разу.
    На живом пользователе спираль слабее — «легко» рано или поздно приходит, —
    но направление то же, и виновата в нём не длина перерыва, а частота ротации.

    Варианты: (а) оставить как есть — правило простое, а «мышца не получала
    нагрузки» и «упражнение не выполнялось» в §9.7 сознательно не различаются;
    (б) считать перерыв по мышце, а не по упражнению: ротация внутри группы
    перерывом не считается, и ступень включается только когда мышца простаивала;
    (в) считать по упражнению, но не применять срез, если в эти дни были
    выполненные тренировки, нагружавшие ту же мышцу не меньше какого-то порога.
    Вариант (б) ближе всего к смыслу §9.7 («перерыв в тренировках»), но меняет
    вход `rebuildStates`: сейчас свёртка видит только журнал одного упражнения.
    Решать вместе с п.13: оба про то, как состояние движется между сессиями, и
    оба требуют прогона на многонедельной синтетике (implement-feature §5а).
16. **Курсор и инкрементальный pull для таблиц без `updated_at`.** Механизм §4.3
    определён для `profiles`, `cycle_profiles` и тренировки целиком; у остальных
    тринадцати таблиц нет колонки, по которой разрешался бы конфликт, и давать
    им отметку курсора раньше, чем решено, чем этот конфликт разрешается, значит
    доставлять строки, с которыми нечего делать. Вдобавок инкрементальный pull
    переносит удаление только там, где есть `deleted_at`, а он есть у одной
    таблицы (§3.1, §3.3). Решается вместе с правилом конфликта и правилами soft
    delete; после этого распространение курсора механическое.
17. **Момент вызова `applyingClosedCycles` при синхронизации** (§11.5). Функция
    двигает счётчик и отметку учёта, а §4.3 не говорит, вызывается ли она после
    применения входящих `cycle_events` и что происходит, если события пришли не
    по порядку. Порядок применения (§4.3) этого не закрывает: счётчик зависит от
    момента вызова, а не от порядка входа.
18. **Регион VPS относительно проекта Supabase** (§20.13). Латентность до
    Postgres теперь на критическом пути каждого логируемого подхода, и
    межконтинентальный разрыв виден пользовательнице внутри тренировки. Решить
    до этапа В0, вместе с выбором региона самого проекта Supabase.
19. **Предел размера дерева решений** (§20.9). Дерево обрезается по глубине при
    превышении предела узлов, но само число не выбрано: оно зависит от реальных
    лестниц весов (§9.5), а их даёт только живой инвентарь. Замерить на первом
    срезе контента и зафиксировать до этапа В2.
20. **Округление вверх при неизменённом весе** (§9.3). Ветки `.ok` и `.hard` в
    диапазоне оставляют `raw = current`, но направление округления при этом всё
    равно `.up`, поэтому вес, введённый пользователем вручную и не лежащий на
    лестнице, растёт до ближайшей ступени вопреки «вес не трогаем» — рост в
    пределах одной ступени, правило «не больше одного достижимого шага»
    формально не нарушено, но желаемое ли это поведение, стоит решить явно.
21. **Нужен ли ограничитель ступеней предписанию по готовности** (§9.6).
    `displayedWeight = roundToAchievable(baseline_kg × readiness)` округляется
    вверх без счёта пройденных ступеней, поэтому при readiness 1.10 на плотной
    лестнице предписание может встать на две ступени выше базовой линии и
    больше — §9.6 ограничителя не требует, в отличие от §9.3, где он есть, но
    стоит решить явно, нужен ли он и здесь.

---

## 20. Веб-версия

### 20.1 Что это

Полноценная замена телефону, а не компаньон: онбординг, план, тренировка,
цикл, растяжка, прогресс, профиль, экспорт и удаление — всё то же, что §13.1
описывает для iOS. Различие ровно одно и оно принципиальное: **офлайна нет**.

Это не оговорка к §4.3, а другая область действия. §4.3 говорит «приложение
обязано работать в подвале без сети — это не деградация, а нормальный режим»;
для веба это неверно и не станет верным. Требование офлайна сохраняется за
iOS-версией и за пакетом `FitData`, который её обслуживает. Веб без сети не
работает — см. §20.10.

Система состоит из трёх частей:

| Часть | Что делает | Язык |
|---|---|---|
| Веб-фронтенд | Экраны, ввод, кеш контента | TypeScript, React (Vite, SPA) |
| Swift-сервер | Собирает вход FitCore, зовёт его, пишет домен | Swift, Vapor |
| Supabase | Postgres + Auth + RLS | — |

**FitCore не переписывается и в браузер не компилируется.** Ни целиком, ни
частично, ни «маленьким куском §9.3». Причина не в чистоте: §18 покрывает
Swift-реализацию, и вторая реализация на TypeScript расходилась бы с ней не
падением, а тихо неверными весами.

### 20.2 Раскладка репозитория

Правит §2.1. Два новых каталога верхнего уровня:

```
fittrack-app/
├── App/                         # iOS-клиент (SwiftUI)
├── Server/                      # Vapor-приложение, зависит от Packages/FitCore
│   ├── Package.swift
│   ├── Sources/FitServer/
│   │   ├── Auth/                # проверка JWT, JWKS-кеш
│   │   ├── DB/                  # пул postgres-nio, подстановка claims
│   │   ├── Mapping/             # схема §3.1 → типы FitCore
│   │   ├── Routes/
│   │   └── Content/             # раздача FitContent
│   └── Tests/
├── Web/                         # SPA (Vite + React + TypeScript)
├── Packages/                    # общий Swift-код: FitCore, FitContent, FitData
├── Supabase/                    # миграции, RLS, edge functions
├── Tools/
└── Tests/
```

Категория каталога отражает роль: `App/` и `Server/` — клиенты, `Packages/` —
то, что они делят. `Web/` отдельно, потому что это единственная часть репозитория
не на Swift, со своим менеджером пакетов и своим жизненным циклом сборки.

**`Mapping/` — единственное место, где схема §3.1 превращается в типы FitCore.**
Оно на Swift сознательно: когда появится iOS-версия, она линкует тот же модуль,
а не пишет второе соответствие. Фронтенд формы типов FitCore не знает вообще —
он видит только то, что отдают эндпоинты §20.3.

### 20.3 Граница API

**Вход FitCore собирает сервер, не фронтенд.** `SessionInput` (§7.3) — это
библиотека упражнений, инвентарь, безопасность, утомление по мышцам, недельный
сделанный объём, `exercise_states`, состояние цикла и готовность. Фронтенд
присылает `{дата, зона, id дня}`, остальное сервер читает сам.

Это распространяется и на генерацию недели: **конкретные дни недели
`POST /v1/week-plans` в теле не принимает**, сервер берёт их из
`profiles.training_weekdays` (§3.1, §7.2). Довод тот же, по которому §20.8
вывел `userSeed` из `user_id`, а не завёл поле: плановый выбор, сделанный на
онбординге, обязан принадлежать аккаунту, иначе второй клиент (iOS) не узнает
его вовсе, а очистка данных сайта унесла бы его вместе с сессией. Меняются дни
через профиль, и это триггер пересборки будущих недель (§7.1).

**Стиль — гибридный.** Сервер делает две разные вещи, и один стиль на обе
натягивается плохо:

- **Ресурсы §3.1 — REST.** `GET`/`POST`/`PATCH` над сущностями, которые в
  схеме есть.
- **Вызовы FitCore, у которых нет ресурса, — явные действия с глаголом в пути.**
  Пересборка недели, замена упражнения, предпросмотр дня не создают строку и
  ресурсом не притворяются.

Граница между стилями проходит по одному признаку: **если у операции есть
строка в §3.1, она REST; если нет — действие.** Новый эндпоинт вне этого
правила не добавляется.

Версия в пути (`/v1`) обязательна с первого дня: у API будет второй клиент
(iOS), и он будет обновляться не синхронно с вебом.

#### Эндпоинты v1

Чтение (`GET`):

| Путь | Отдаёт |
|---|---|
| `/v1/today?date=&tz=` | Карточка дня §13.1: готовность (§10), фаза и уверенность (§11.3), тип дня, причины |
| `/v1/week-plans/{week_start}` | План недели: дни, статусы, строки статуса §7.1 |
| `/v1/week-plans/{week_start}/preview?date=` | Предпросмотр дня от замороженного состояния (§18, 31b) |
| `/v1/workouts/{id}` | Тренировка с упражнениями и подходами |
| `/v1/workouts/{id}/exercises/{we_id}/alternatives` | Три альтернативы замены §13.4 с причинами пригодности |
| `/v1/content/exercises` | Библиотека §6, с `ETag` |
| `/v1/content/stretches` | Шаблоны §12, с `ETag` |

Запись в ресурсы (`POST`, `PATCH`):

| Путь | Делает |
|---|---|
| `POST /v1/week-plans` | Генерирует неделю §7.2 |
| `POST /v1/workouts` | Начинает тренировку из `planned_day`, собирает состав §7.3 |
| `POST /v1/workouts/{id}/exercises/{we_id}/sets` | Логирует подход, отдаёт следующий и новое дерево §20.9. Тело обязано нести `id` подхода, сгенерированный клиентом до отправки (§20.6) |

Действия (`POST` с глаголом):

| Путь | Делает |
|---|---|
| `POST /v1/week-plans/{week_start}/rebuild` | Пересборка §7.1 с причиной; ответ содержит `ReasonCode` для «План обновлён» |
| `POST /v1/workouts/{id}/finish` | Закрывает тренировку, пересчитывает производные §20.6 |
| `POST /v1/workouts/{id}/exercises/{we_id}/substitute` | Замена §13.4, включая перенос веса по `family_load_ratio` |

Ошибка — всегда `{"error": {"code": "...", "message": "...", "details": {...}}}`,
где `code` из закрытого словаря. Формулировки, которые видит пользовательница,
подчиняются §13.5 и §14.6 наравне с экранными.

### 20.4 Доступ к данным и изоляция

Сервер держит пул соединений `postgres-nio` к Postgres проекта Supabase. На
каждый запрос, в одной транзакции и до первого чтения:

```sql
set local role authenticated;
set local request.jwt.claims = '<проверенный JWT как json>';
```

После этого политики §3.2 действуют буквально: `auth.uid()` возвращает того же
пользователя, что и для запроса из браузера, и сервер физически не может
прочитать чужую строку. Никакой второй модели доступа не заводится.

**`service_role` на сервере не живёт.** Единственная операция, которой нужны
права выше пользовательских, — удаление аккаунта, и она вынесена в Supabase
Edge Function (§20.13). Ключ не покидает Supabase.

**Тест изоляции §3.2 обязателен и для этого пути.** Существующего теста «два
анонимных пользователя, второй не видит строки первого» недостаточно: он
проверяет PostgREST, а сервер ходит другим путём. Тот же сценарий прогоняется
через HTTP-эндпоинты с двумя разными JWT, плюс отдельно — запрос с подделанной
подписью и запрос с истёкшим токеном.

Чтение всего входа `SessionInput` идёт **одной транзакцией**. Иначе вход —
несогласованный срез: утомление посчитано до записи тренировки, `exercise_states`
после.

### 20.5 Аутентификация

Supabase Auth используется как есть, JWT пробрасывается в `Authorization: Bearer`.

**Анонимный вход с первого экрана** (§4.1, без изменений): онбординг и PAR-Q
проходятся анонимно, `auth.uid()` настоящий, RLS работает, барьера на входе нет.

**Линковка обязательна до первой тренировки**, а не после третьей. §4.2 закрывал
риск потери анонимного аккаунта тремя мерами, и в браузере не работает ни одна:
Keychain с iCloud-синхронизацией отсутствует как понятие, refresh-токен лежит в
`localStorage`, а его сносит очистка данных сайта, режим инкогнито и ITP Safari.
Поэтому кнопка «Начать тренировку» требует привязанного аккаунта. Это
расхождение с §4.1 по платформам, и оно намеренное: цена барьера — часть
конверсии, цена его отсутствия — молча потерянная история тренировок.

**Вход один на обеих платформах — email magic link.** Sign in with Apple
добавляется позже и только как `linkIdentity` к существующему аккаунту, но
никогда как самостоятельный способ его завести. Причина строгая: два способа
завести аккаунт дают одному человеку два `auth.uid()`, а слияния двух
заполненных аккаунтов схема §3.1 не предусматривает и дешёвым оно не станет
никогда. §4.1 гордится тем, что миграции данных нет вообще; отдельный
Apple-вход завёл бы её с чёрного хода.

**Проверка подписи — асимметричные ключи через JWKS.** Сервер тянет публичные
ключи проекта, кеширует и обновляет по истечении. Приватного ключа у сервера
нет вовсе: компрометация VPS не даёт возможности выписать токен от чужого
имени, и ротация ключей проходит без деплоя. Общий секрет HS256 этого свойства
не даёт и в Supabase сворачивается.

### 20.6 Кто что пишет

| Таблицы | Пишет | Почему |
|---|---|---|
| `week_plans`, `planned_days`, `workouts`, `workout_exercises`, `sets`, `exercise_states`, `muscle_fatigue`, `phase_response_profile`, `stretch_sessions` | Только сервер | Инварианты §4.3 и производность — в одном месте |
| `profiles`, `cycle_profiles` | Только сервер | Единственные таблицы с `updated_at` в области §4.3: их метку обязаны ставить доверенные часы |
| `equipment_profiles`, `user_restrictions`, `parq_responses`, `cycle_events`, `daily_checkins`, `body_weight_entries` | Фронтенд напрямую | `updated_at` у них нет, в область §4.3 не входят, конфликтовать нечем |

Правило для `profiles` и `cycle_profiles` — следствие, а не отдельное решение:
их `updated_at` разрешает конфликт по LWW (§4.3), а браузерные часы для этого
не годятся ровно по той же причине, по которой §4.3 отказался вести по
`updated_at` курсор.

**`updated_at` доменных строк ставит сервер своими часами.** Это заметно
усиливает §4.3: всё, что приходит с веба, несёт метку одного надёжного
источника. Для iOS правило §3.3 остаётся прежним — строку пишет устройство, —
поэтому LWW и тай-брейк по `sync_seq` никуда не деваются.

**`sets` иммутабельны после `completed_at`** (§4.3) — проверяет сервер,
отклоняя изменение завершённого подхода.

**Идентификатор подхода выдаёт клиент.** UUID строки `sets` генерируется во
фронтенде до отправки `POST /v1/workouts/{id}/exercises/{we_id}/sets` и едет в
теле запроса; сервер принимает его как первичный ключ и применяет строку
**upsert по `id`, а не `insert`**. Это и есть механизм идемпотентности, которого
требует сценарий 20e (§20.15): ретрай после таймаута приходит с тем же `id`,
попадает в ту же строку, второй не создаёт, и пересчёт производных идёт от того
же журнала, а не от удвоенного.

Правило «доменные строки пишет только сервер» этим не нарушается. Оно про то,
**что** записать и **когда**: решение о записи, проверка инвариантов §4.3,
отметка `updated_at` и пересчёт `exercise_states` и `muscle_fatigue` остаются
целиком на сервере. Клиент лишь **называет** строку — ровно для того, чтобы
повтор одного и того же запроса был отличим от нового подхода. Без имени,
данного до отправки, сервер этих двух случаев различить не может в принципе:
после таймаута клиент не знает, дошёл ли первый запрос, а сервер не знает, что
пришедший запрос — тот же самый.

**Производные пересчитываются, а не мержатся** (§4.3): `exercise_states` и
`muscle_fatigue` сервер пересчитывает из истории подходов через
`Progression.rebuildStates` и свёртки §8.1, а не правит инкрементально.

**Триггеры `sync_seq` (§3.1) работают сами.** Запись с веба двигает курсор так
же, как запись с устройства, поэтому будущий iOS-клиент увидит веб-тренировки
инкрементальным pull без единой правки §4.3.

**`input_digest` пишет сервер в момент генерации.** Это полный снимок входа
генерации с номером версии (`{"v": 1, ...}`). Его назначение — отладка,
поддержка и воспроизводимость: «какой именно вход дал этот план». Причину
пересборки он не определяет и определять не может — строку «План обновлён» §7.1
даёт `Planner.rebuildNotice`, а она сравнивает два выхода планировщика и
дайджеста не читает.

### 20.7 Время и день

FitCore времени не знает: `CalendarDay` и `Timestamp` передаются снаружи (§2.1).
Сервер живёт в UTC, пользовательница — нет.

**Клиент присылает локальную дату и IANA-зону в каждом запросе, где день имеет
значение.** Сервер их валидирует: вычисляет дату из своих часов в присланной
зоне и отклоняет запрос, если присланная отличается больше чем на сутки.
Допуск в сутки нужен для полуночи и для записи вчерашней тренировки; больший
разрыв — сбитые часы, и молча считать по ним нельзя.

**Сервер не берёт день из своих часов.** Момент оценки дня (12:00, §7.1) и
контракт `evaluationMoment` считаются в зоне клиента.

Открытая цена решения: сбитые на несколько часов часы телефона сдвигают день
тренировки в пределах допуска. Альтернатива — хранить зону в `profiles` — не
выбрана, чтобы не заводить колонку и не ломать поездки в другой пояс.

### 20.8 Seed планировщика

`Planner.daySeed(userSeed:day:)` требует `userSeed`, а §3.1 такой колонки не
имеет и SPEC про её место молчал. Без seed нет ни детерминизма (§18, 33a), ни
повторяемой пересборки §7.1.

**Seed выводится из `user_id`, не хранится:**

```
userSeed = первые 8 байт SHA-256(канонический uuid пользователя,
           36 символов, нижний регистр, UTF-8), big-endian → UInt64
```

Ни миграции, ни поля, ни расхождения между платформами: обе стороны получают
одно и то же из того, что уже есть. Цена принимается явно: **сменить seed
невозможно**, и функция становится частью контракта — её нельзя поменять
никогда, иначе у всех существующих пользователей разом изменится подбор
упражнений без единой видимой причины.

### 20.9 Экран тренировки: дерево решений

§9.3 — реакция на фидбэк внутри сессии — это ключевое отличие продукта (§1.3).
На iOS это локальный вызов; на вебе он был бы запросом на каждый тап по кнопке
фидбэка.

**Сервер отдаёт дерево решений вперёд**, вместе с составом упражнения. Фронтенд
применяет ветку мгновенно и отправляет факт подхода отдельным запросом.
Обоснование — **только латентность**: §13.2 требует «один тап на подход», и
спиннер между подходами разрушает доверие ровно так же, как немотивированное
изменение чисел. Устойчивостью к обрыву сети дерево не является — см. §20.10.

**Форма дерева следует из `Progression.nextSet`.** Состояние узла — пара
(вес по лестнице достижимых, был ли предыдущий фидбэк `failed`). Переходов из
узла шесть, а не четыре, потому что фактические повторы входят в решение
предикатами, а не значением:

| Ветка | Следующий вес |
|---|---|
| `failed`, предыдущий тоже `failed` | упражнение завершается досрочно |
| `failed` | ×0.90 |
| `hard`, повторов меньше `rep_min` | ×0.95 |
| `hard`, повторов не меньше `rep_min` | без изменения |
| `ok` | без изменения |
| `easy`, повторов не меньше `rep_max` | ×1.05, в калибровке ×1.15 |
| `easy`, повторов меньше `rep_max` | без изменения |

Веса округляются к лестнице достижимых (§9.5), поэтому ветки сходятся: число
различимых состояний растёт много медленнее, чем 4 в степени числа подходов, и
дерево остаётся небольшим. Если для длинного упражнения оно всё же превышает
заданный предел узлов, дерево обрезается по глубине, и на обрезанной глубине
фронтенд идёт на сервер.

**Что в дерево не входит и требует запроса:** флаг боли (§8.4), ручная правка
веса или повторов за пределы предикатов выше, замена упражнения (§13.4),
пропуск подхода. Любой такой ввод уводит состояние с дерева, и фронтенд обязан
спросить сервер, а не угадывать.

**Обязательный тест:** для каждой ветки отданного дерева результат совпадает с
прямым вызовом `Progression.nextSet` на том же состоянии. Дерево — кеш ответа
FitCore, и расхождение кеша с источником обязано ловиться тестом, а не
пользовательницей.

### 20.10 Сеть обязательна

Решение принято явно: **без сети экран тренировки не работает.** Незаписанных
подходов не существует — очереди, ни в памяти, ни в `localStorage`, нет.
Обрыв связи показывается прямо и немедленно, а не прячется за оптимистичным UI.

Причина отказа от локальной очереди: это и есть начало `FitData`, только на
TypeScript, с собственной идемпотентностью и собственным разрешением
конфликтов. Половина §4.3, написанная второй раз на другом языке, — худший из
возможных способов получить офлайн.

**Цена признаётся, а не скрывается.** В зале с плохой связью продуктом
пользоваться нельзя; это заносится в §19.1 как риск с высоким влиянием. Веб —
первая платформа, а не единственная, и подвальный сценарий закрывает
iOS-версия, для которой §4.3 остаётся в силе целиком.

### 20.11 Контент

**FitContent линкуется в Swift-сервер** и раздаётся им: `GET /v1/content/exercises`
и `/v1/content/stretches`, с `ETag` и долгим кешем на клиенте.

Один источник правды по построению: планировщик получает библиотеку как вход из
того же пакета, из которого экран упражнения берёт названия, cues и ошибки.
Расхождение версий между тем, что подобрал планировщик, и тем, что умеет
показать фронтенд, становится невозможным — а именно оно даёт худший из багов:
выданный слаг, которого фронт не знает, и пустой экран посреди тренировки.
Цена: правка одной опечатки в cue требует деплоя сервера.

**Объём к запуску веба** — не весь этап 2 из §17, а срез:

- столько упражнений, сколько нужно, чтобы валидатор (§19.1, Tools/content-validator)
  прошёл правило покрытия «минимум три упражнения на каждую комбинацию
  тип дня × акцент × уровень инвентаря»;
- полная разметка по §6.2 для каждого из них, включая `impact` и
  `family_load_ratio` — планировщик и §13.4 без них не работают;
- изображения из проверенного открытого датасета, лицензия проверяется
  пофайлово.

Это временно закрывает §19.2 п.1: заказ единого набора у иллюстратора остаётся
планом, но перестаёт блокировать запуск. Визуальный разнобой принимается как
цена; перезаказ — отдельная работа после первых живых пользователей.

**Валидатор — гейт CI.** Библиотека, не прошедшая §6.2, §6.6 и правило
покрытия, не попадает в сборку сервера.

### 20.12 UI и UX

Всё, что §13 фиксирует про тон (§13.5), экран упражнения (§13.2) и формулировки
про цикл (§14.6), действует на вебе без изменений. Веб-специфичное:

- **Мобильный макет — основной.** Проектируем от телефона (375–430 px); десктоп
  получает тот же макет в колонке ограниченной ширины. Отдельной широкой
  вёрстки в MVP нет: экран тренировки всё равно проектируется под потную руку и
  один палец, а второй набор компоновок удваивает работу ради сценария «за
  столом», который и в колонке читается.
- **Требования §13.2 переносятся буквально:** одна главная цифра, ввод тапами
  по «−»/«+», четыре кнопки фидбэка во всю ширину высотой 64 pt, флаг боли —
  отдельно и никогда в одном ряду с «тяжело».
- **Экран не гаснет** — Screen Wake Lock API, запрашивается на входе в
  тренировку и отпускается на выходе.
- **Live Activity (§13.3) — iOS-only и на вебе не эмулируется.** Таймер отдыха
  сигналит звуком и вибрацией; длительность и множители §13.3 те же.
- **Таймер считается от абсолютной метки времени, а не тиками.** Свёрнутая
  вкладка в iOS Safari замораживает таймеры, и счётчик по тикам после
  разворачивания отстанет ровно на время в кармане.
- **Дизайн-токены — общий источник.** Цвета, типографика и размеры лежат в одном
  файле, из которого генерируются и CSS-переменные для веба, и Swift-расширение
  для `App/FitTrack/DesignSystem`. Две платформы не расходятся визуально по
  недосмотру.
- **PWA-манифест без service worker.** Иконки и манифест нужны, чтобы ставить на
  домашний экран и запускать без адресной строки — в зале это заметно удобнее.
  Service worker и офлайн-кеш не добавляются: решение §20.10 нарушать нечем.
- **Уведомления §13.6 на вебе не реализуются** в первой версии. Оба они
  выключены по умолчанию и требуют Web Push с отдельным разрешением; напоминание
  про цикл вдобавок подчиняется §14.6 строже всего.

### 20.13 Хостинг и эксплуатация

- **Свой VPS, Docker Compose, Caddy для TLS.** Серверлесс исключён выбранным
  пулом соединений: холодный старт и разрыв пула на каждом вызове стоят дороже
  всего, что серверлесс даёт.
- **SPA раздаётся с того же origin**, что и API. Следствие: CORS не нужен вовсе,
  и токен не путешествует между источниками.
- **Регион VPS выбирается под регион проекта Supabase.** Латентность до Postgres
  теперь на критическом пути каждого логируемого подхода, и межконтинентальный
  разрыв здесь виден пользовательнице. Конкретный регион — открытый вопрос
  (§19.2).
- **Экспорт и удаление аккаунта.** Удаление остаётся в Supabase Edge Function
  (`Supabase/functions/delete-account`): оно требует `service_role`, необратимо,
  и ключ не должен попадать на VPS. Экспорт (§4.2) идёт оттуда же, чтобы обе
  кнопки профиля жили в одном месте с одной моделью прав.

### 20.14 Чего веб не делает

- Офлайн (§20.10), HealthKit (§15), Live Activity (§13.3), Web Push (§13.6).
- Не пишет `sets` иначе как через сервер и не считает §9.3 сам — кроме
  применения дерева §20.9.

### 20.15 Обязательные тесты веба

По образцу §18, но это тесты сервера и фронтенда, а не FitCore:

- 20a. Два пользователя, два JWT → эндпоинты не отдают чужие строки ни на одном
  пути (повторяет §3.2 через HTTP).
- 20b. Подделанная подпись, истёкший токен, токен другого проекта → 401, до БД
  запрос не доходит.
- 20c. Каждая ветка отданного дерева §20.9 совпадает с прямым вызовом
  `Progression.nextSet`. **Отдельно — сам диапазон повторов:** границы, с
  которыми построено дерево, совпадают с `workout_exercises.target_rep_min`/
  `target_rep_max` этого упражнения и с `exercise_states.current_rep_min`/
  `current_rep_max`, потому что все три берутся из одного вызова
  `Planner.repRange` (§9.1). Без этой половины 20c к выбору диапазона слеп по
  построению: он передаёт дереву и `nextSet` один и тот же диапазон и потому
  проходит зелёным при любом. Случай с перерывом (§9.7, сброс `rep_extension`
  внутри сборки) входит в тест отдельной веткой.
- 20d. Присланная дата расходится с серверной больше чем на сутки → 422.
- 20e. Повторная отправка того же подхода (ретрай после таймаута) несёт тот же
  клиентский `id` и применяется upsert'ом в ту же строку: второй строки не
  появляется, а `exercise_states` и `muscle_fatigue` после повтора равны тем,
  что получились бы от одиночной отправки (§20.6). Отдельно — запрос без `id`
  в теле отклоняется, а не получает `id` от сервера: сгенерированный сервером
  ключ снял бы саму возможность отличить ретрай от нового подхода.
- 20f. Изменение подхода с непустым `completed_at` → отказ (§4.3).
- 20g. Запись с веба двигает `sync_seq` родительской тренировки (§3.1) — тот же
  сценарий, что 37c, но через HTTP.
- 20h. `userSeed`, вычисленный по §20.8, совпадает со значением, вычисленным
  независимой реализацией на другом языке (защита контракта хеша).

---

## Приложение A. Соответствие решений интервью

| Область | Решение |
|---|---|
| Платформы | Веб первый, нативный iOS после |
| Стек iOS | Нативный iOS, SwiftUI |
| Стек веба | Vite + React (SPA) и Vapor-сервер поверх FitCore, без переписывания логики |
| Граница API | Сервер читает Supabase под JWT пользователя; доменные строки пишет только сервер |
| Офлайн | Требование iOS-версии; на вебе сеть обязательна |
| Бэкенд | Supabase (Postgres + Auth + RLS) |
| Авторизация | Анонимная с первого запуска; вход — email magic link на обеих платформах, Apple позже только как linkIdentity |
| MVP: отложено | HealthKit, видео-демонстрации, монетизация |
| MVP: включено | Растяжка (сессии + мобильность как разминка) |
| Прогрессия | Двойная прогрессия + RIR-модуляция |
| Фидбэк | Факт (повторы, вес) + 4-кнопочная шкала |
| Память алгоритма | Двухуровневая: внутри сессии + история 2–3 сессий |
| Недостижимый вес | Инвентарь пользователя + прогрессия по повторам |
| Нет цикла (КОК и др.) | Явный вопрос в онбординге + режим «без фаз» |
| Сила фазового эффекта | Сильная: разные типы блоков по фазам |
| Ошибка предсказания | Непрерывное затухание влияния фазы по уверенности |
| Оверрайд | Пользователь главнее, на один день, система учится |
| Планировщик | Недельный план с пересборкой |
| Акцент | Граф вклада мышц с весами |
| Переутомление | Разрешаем, меняем наполнение |
| Холодный старт | Калибровочная неделя |
| Аудитория | Women-first, мужской режим работает |
| Экран тренировки | Автотаймер, замена в один тап, флаг боли; Live Activity и офлайн — только iOS |
| Безопасность | PAR-Q, беременность out of scope, карта травм, дисклеймер + экспорт/удаление |
| Библиотека | 60–80 упражнений, глубокая разметка |
| Язык и единицы | Только русский, кг |
