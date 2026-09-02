//  SyncEngine — actor. Офлайн-first, устройство источник правды (SPEC §4.3).
//
//  Push: выборка по syncState == .pendingUpload, батчи в порядке зависимостей
//        (workouts → workout_exercises → sets).
//  Pull: инкрементальный по updated_at > lastCursor на таблицу.
//
//  Конфликты — last-write-wins по updated_at, с двумя исключениями:
//    sets после completed_at иммутабельны, конфликта не бывает конструктивно;
//    exercise_states и muscle_fatigue не мержатся, а пересчитываются через
//    FitCore.rebuildStates(from:) — производные данные всегда сходятся.
