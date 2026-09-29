//  Журнал подходов, утомление и выполненные тренировки
//  (SPEC §3.1, §7.3, §8.1, §9.8, §20.6, §20.7).
//
//  Здесь сосредоточено шесть обязанностей §20.6 из пятнадцати, и все шесть
//  одного рода: величина, которую слой обязан ПОСЧИТАТЬ, а не переложить.
//
//    2.  FatigueSet.muscleLoad = contribution[m] × fatigue_cost
//    6.  утомление ДО распада против утомления ПОСЛЕ
//    7.  exerciseHistory — сырой журнал, а не готовые состояния
//    8.  weightReadiness — из workout_exercises, не из workouts
//    9.  калибровочные подходы вне утомления и вне неделя[m]
//    12. performedAt — из finished_at, и это не нарушение §20.7
//
//  ── Про два утомления, которых легко перепутать ───────────────────────────
//
//  `WeekContext.fatigue` — состояние ДО распада: `planRemainingDays` декает его
//  сам, до 12:00 каждого дня. `SessionInput.fatigue` — уже ПОСЛЕ. Один и тот же
//  словарь мышц означает в них разное, и продеканное значение, положенное в
//  `WeekContext`, применит распад дважды. Поэтому отсюда наружу отдаётся только
//  состояние (`FatigueState` с меткой), а декать его — дело того, кто знает
//  момент: планировщик для будущих дней, `PrescriptionInput` для старта.
//
//  ── Про `weightReadiness`, которую §20.6 называет самой лёгкой подменой ───
//
//  `workout_exercises.weight_readiness` и `workouts.readiness` обе `numeric`,
//  обе называются «готовность». Первая применена к весу ЭТОГО упражнения
//  (§7.6), вторая — дневная (§10). Демпфирование §9.6 читает только первую, и
//  на второй базовая линия поедет — не упадёт, а именно поедет, потому что обе
//  величины в одном диапазоне и обе правдоподобны.

import FitCore
import FitContent

extension Mapping {

    // MARK: - Утомление по мышцам

    /// Строка `muscle_fatigue` (§3.1).
    public struct FatigueRow: Sendable, Equatable {
        public var muscle: String
        public var value: Double
        /// Значение шкалы FitCore: колонка `timestamp` БЕЗ зоны (§20.7),
        /// поэтому перевод здесь не нужен и был бы ошибкой.
        public var updatedAt: Timestamp

        public init(muscle: String, value: Double, updatedAt: Timestamp) {
            self.muscle = muscle
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    /// Состояние утомления — ДО распада (§20.6, обязанность 6).
    public static func fatigue(from rows: [FatigueRow]) -> [MuscleSlug: FatigueState] {
        var result: [MuscleSlug: FatigueState] = [:]
        for row in rows {
            guard let muscle = MuscleSlug(rawValue: row.muscle) else { continue }
            result[muscle] = FatigueState(value: row.value, updatedAt: row.updatedAt)
        }
        return result
    }

    /// То же состояние, продеканное до момента (§8.1) — вход `SessionInput`.
    ///
    /// Отдельной функцией, чтобы у двух смыслов было два имени: положить
    /// результат этой функции в `WeekContext` — значит применить распад дважды.
    public static func decayedFatigue(_ states: [MuscleSlug: FatigueState],
                                      to moment: Timestamp) -> [MuscleSlug: Double] {
        states.reduce(into: [:]) { result, pair in
            result[pair.key] = Recovery.decayed(pair.value, to: moment, muscle: pair.key)
        }
    }

    // MARK: - Подход и его вклад в утомление

    /// Подход журнала — срез `sets` ⋈ `workout_exercises` ⋈ `workouts` (§3.1).
    public struct SetRow: Sendable, Equatable {
        public var exerciseSlug: String
        /// Порядок подхода внутри упражнения (§3.1). Нужен корню дерева §20.9:
        /// «последний записанный» — это максимальный индекс, а не последняя
        /// строка выборки.
        public var setIndex: Int
        public var prescribedKg: Double?
        public var actualKg: Double?
        public var actualReps: Int?
        public var feedback: String?
        public var skipped: Bool
        /// Флаг боли (§8.4). Состояние дерева он не двигает (§20.9): у него
        /// своя ветка — замена или исключение упражнения, — и засчитывать его
        /// ещё и шагом прогрессии значит применить к одному событию два правила.
        public var painFlag: Bool
        /// Снимок `exercise_states.in_calibration` на момент старта — по строке
        /// УПРАЖНЕНИЯ, а не тренировки (§9.8, миграция `0007`).
        public var isCalibration: Bool
        /// §7.6: готовность, применённая к весу ЭТОГО упражнения.
        public var weightReadiness: Double
        /// День шкалы FitCore, переведённый из `workouts.started_at` один раз
        /// при чтении, в зоне запроса (§20.7).
        public var performedOn: CalendarDay

        public init(exerciseSlug: String, setIndex: Int = 1, prescribedKg: Double? = nil,
                    actualKg: Double? = nil, actualReps: Int? = nil, feedback: String? = nil,
                    skipped: Bool = false, painFlag: Bool = false,
                    isCalibration: Bool = false, weightReadiness: Double = 1.0,
                    performedOn: CalendarDay) {
            self.exerciseSlug = exerciseSlug
            self.setIndex = setIndex
            self.painFlag = painFlag
            self.prescribedKg = prescribedKg
            self.actualKg = actualKg
            self.actualReps = actualReps
            self.feedback = feedback
            self.skipped = skipped
            self.isCalibration = isCalibration
            self.weightReadiness = weightReadiness
            self.performedOn = performedOn
        }

        /// Выполненный рабочий подход: не пропущен и несёт фидбэк с повторами.
        /// Пропущенный подход §9.3 помечает `skipped`, и прогрессии он не
        /// принадлежит — как и подход без фидбэка, которого свёртке нечем
        /// обработать.
        var isPerformed: Bool { !skipped && feedback != nil && actualReps != nil }
    }

    /// Вклад подхода в утомление (§8.1, §20.6 обязанность 2).
    ///
    /// `muscleLoad` — это УЖЕ произведение вклада мышцы на стоимость утомления
    /// упражнения, и перемножает их слой, а не `Recovery`: doc `FatigueSet`
    /// говорит прямо, что данные приходят из FitContent, и ядро от него не
    /// зависит. Сырые вклады, а не эффективные: §8.1 считает по ним, §7.4 — по
    /// эффективным, и смешивать их нельзя.
    ///
    /// `nil` — подход не идёт в утомление: пропущен, без фидбэка либо
    /// калибровочный (§9.8, обязанность 9). Фильтр стоит здесь, потому что ни
    /// `Recovery.applying`, ни `Planner.weekDoneVolume` не фильтруют — они
    /// берут то, что им дали.
    public static func fatigueSet(from row: SetRow, candidate: ExerciseCandidate) -> FatigueSet? {
        guard row.isPerformed, !row.isCalibration,
              let feedback = Feedback(rawValue: row.feedback ?? "")
        else { return nil }
        let load = candidate.muscleContributions.mapValues { $0 * candidate.fatigueCost }
        return FatigueSet(muscleLoad: load, feedback: feedback)
    }

    // MARK: - Журнал упражнений

    /// Сырой журнал для `WeekContext.exerciseHistory` (§20.6, обязанность 7).
    ///
    /// Именно журнал, а не готовые `exercise_states`: состояние могло быть
    /// посчитано с ДРУГОЙ лестницей весов — инвентарь меняется (§7.1), — и
    /// предписание разошлось бы с ним. Свёртку делает планировщик сам, с
    /// лестницей текущего инвентаря (`Planner.exerciseStates`).
    ///
    /// Сортировка не делается: `Planner.exerciseStates` зовёт `chronological`
    /// внутри себя, и вторая сортировка здесь была бы вторым правилом порядка.
    ///
    /// Калибровочные подходы отсюда НЕ исключаются, и это не оплошность:
    /// §9.8 выводит из калибровки по журналу калибровочных же подходов, и без
    /// них свёртка не узнает, что калибровка кончилась. Исключаются они только
    /// из утомления и из `неделя[m]` (обязанность 9).
    public static func exerciseHistory(from rows: [SetRow]) -> [String: [ExerciseSession]] {
        // Ключ сессии — (упражнение, день): одна строка `workout_exercises` на
        // тренировку, а тренировок в день может быть несколько.
        struct Key: Hashable { let slug: String; let day: CalendarDay; let calibration: Bool
                               let readiness: Double }
        var grouped: [Key: [SetResult]] = [:]
        var order: [Key] = []
        for row in rows where row.isPerformed {
            guard let feedback = Feedback(rawValue: row.feedback ?? ""), let reps = row.actualReps
            else { continue }
            let key = Key(slug: row.exerciseSlug, day: row.performedOn,
                          calibration: row.isCalibration, readiness: row.weightReadiness)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(
                SetResult(prescribedKg: row.prescribedKg, actualKg: row.actualKg,
                          actualReps: reps, feedback: feedback))
        }

        var result: [String: [ExerciseSession]] = [:]
        for key in order {
            result[key.slug, default: []].append(
                ExerciseSession(performedAt: key.day,
                                // §20.6, обязанность 8: из workout_exercises,
                                // не из workouts.readiness.
                                weightReadiness: key.readiness,
                                isCalibration: key.calibration,
                                sets: grouped[key] ?? []))
        }
        return result
    }

    // MARK: - Выполненные тренировки

    /// Строка `workouts` с непустым `finished_at` (§3.1).
    public struct CompletedWorkoutRow: Sendable, Equatable {
        public var id: String
        public var plannedDayID: String?
        /// День шкалы FitCore (§20.7).
        public var date: CalendarDay
        /// §20.6, обязанность 12: строится из `workouts.finished_at`, колонки
        /// «настоящих моментов». Это НЕ нарушение §20.7 — значение служит
        /// только упорядочиванию (слагаемое w6, §7.3), а порядок не меняется от
        /// общего сдвига шкалы. Условие — все значения из одной колонки.
        public var performedAt: Timestamp

        public init(id: String, plannedDayID: String?, date: CalendarDay, performedAt: Timestamp) {
            self.id = id
            self.plannedDayID = plannedDayID
            self.date = date
            self.performedAt = performedAt
        }
    }

    /// Выполненные тренировки для `WeekContext.completed` (§7.3).
    ///
    /// `setsBySlug` считает только те подходы, которые идут в `неделя[m]`:
    /// выполненные и НЕ калибровочные (§9.8, обязанность 9). `weekDoneVolume`
    /// не фильтрует — «выполненные подходы» в его doc означает ровно то, что
    /// ему дали.
    public static func completedWorkouts(
        rows: [CompletedWorkoutRow], sets: [String: [SetRow]]
    ) -> [CompletedWorkout] {
        rows.map { row in
            var counts: [String: Int] = [:]
            for set in sets[row.id] ?? [] where set.isPerformed && !set.isCalibration {
                counts[set.exerciseSlug, default: 0] += 1
            }
            return CompletedWorkout(id: row.id, plannedDayID: row.plannedDayID, date: row.date,
                                    performedAt: row.performedAt, setsBySlug: counts)
        }
    }
}
