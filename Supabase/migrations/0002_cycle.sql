-- 0002: cycle_events, cycle_profiles, phase_response_profile.
-- Таблицы и их колонки — из §3.1 SPEC.md; см. README этой папки.

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

create trigger sync_seq_bump before insert or update on cycle_profiles
  for each row execute function bump_sync_seq();

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
