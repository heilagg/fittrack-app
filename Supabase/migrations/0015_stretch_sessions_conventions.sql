-- 0015: stretch_sessions — колонки этапа В3 и общие соглашения таблиц
-- (SPEC §3.1, §12.2, §20.6, §20.7).
--
-- Почему сейчас: до В3 таблицу не писал никто, и её форма из 0003 так и не
-- встретилась с данными. Этап В3 начинает её писать (`POST /v1/stretch-sessions`),
-- и решения по ней приняты в SPEC до кода (content-domain §1, server-domain §3).
--
-- 1. `template_slug` становится nullable: у автозаминки (§12.2) шаблона нет —
--    состав собирает FitCore из подходов тренировки.
-- 2. `performed_on` — местный день сессии, фиксируется при записи из присланных
--    `date`/`tz` (§20.7), как `sets.performed_on` (миграция 0013). Без него стрик
--    и календарь §13.7 считали бы день по `started_at` в зоне читающего запроса
--    и переезжали бы через полночь. Существующие строки (их нет: таблицу никто
--    не писал) получили бы день `started_at` в UTC.
-- 3. `kind` закрыт check'ом. `mobility_warmup` в словаре остаётся: разминка
--    §12.1 открыта (§19.2 п.33), но значение уже объявлено в §3.1.
-- 4. `updated_at`, `deleted_at`, `sync_seq` и индекс `(user_id, updated_at)` —
--    соглашения README для каждой таблицы, которых у этой не было. Пишет
--    таблицу только сервер (§20.6), поэтому метку ставят его часы.

alter table stretch_sessions
  alter column template_slug drop not null,
  add column performed_on date,
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz,
  add column sync_seq bigint not null default nextval('sync_seq_all');

update stretch_sessions
   set performed_on = (started_at at time zone 'UTC')::date
 where performed_on is null;

alter table stretch_sessions
  alter column performed_on set not null,
  add constraint stretch_sessions_kind
    check (kind in ('mobility_warmup', 'static_cooldown', 'standalone'));

create index stretch_sessions_user_updated on stretch_sessions (user_id, updated_at);

create trigger sync_seq_bump before insert or update on stretch_sessions
  for each row execute function bump_sync_seq();
