-- 0012: снимок упражнения на подходе — слаг, калибровка, готовность
-- (SPEC §3.1, §13.4, §20.3, §20.6).
--
-- Замена упражнения (POST …/substitute) меняет строку workout_exercises на
-- месте: новый слаг, своя калибровка, своя готовность. Подходы, сделанные до
-- замены, — факт о ПРЕЖНЕМ упражнении, и читатели журнала обязаны видеть их
-- такими: свёртка §9 по прежнему слагу, утомление §8.1 и неделя[m] с прежней
-- калибровкой (§20.6, обязанность 9), демпфирование §9.6 с прежней
-- готовностью (обязанность 8). Читай они эти три значения из строки
-- упражнения, после замены все три были бы чужими.
--
-- Заполнение — из строки упражнения, к которой подход принадлежит сейчас. До
-- этой миграции замены не существовало (путь появляется после неё), значит
-- строка всё ещё описывает то упражнение, на котором подход был сделан, и
-- снимок верен для каждой существующей строки.
--
-- Колонки сначала nullable, потом not null: значения по умолчанию нет
-- намеренно — подход, записанный без снимка, должен падать, а не получать
-- выдуманную калибровку.
--
-- Заполнение — настоящий update, и триггер sync_seq_bump_parent_upd (0003)
-- сдвинет курсор каждой тренировки с подходами один раз. Не отключается:
-- клиента, тянущего по курсору (iOS, §4.3), ещё нет, а отключённый на время
-- миграции триггер — это ещё одно место, где курсор может разойтись с данными.

alter table sets
  add column exercise_slug    text,
  add column is_calibration   boolean,
  add column weight_readiness numeric(4,3);

update sets s
   set exercise_slug    = we.exercise_slug,
       is_calibration   = we.is_calibration,
       weight_readiness = we.weight_readiness
  from workout_exercises we
 where we.id = s.workout_exercise_id;

alter table sets
  alter column exercise_slug    set not null,
  alter column is_calibration   set not null,
  alter column weight_readiness set not null;

comment on column sets.exercise_slug is
  'Слаг упражнения на момент подхода (§3.1): после замены строка workout_exercises '
  'описывает новое упражнение, а подход остаётся фактом о прежнем.';
comment on column sets.is_calibration is
  'Снимок workout_exercises.is_calibration на момент подхода (§20.6, обязанность 9).';
comment on column sets.weight_readiness is
  'Снимок workout_exercises.weight_readiness на момент подхода (§20.6, обязанность 8).';
