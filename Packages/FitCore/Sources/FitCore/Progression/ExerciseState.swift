//  Типы данных Progression: срез `exercise_states` (SPEC §3.1) плюс то, что
//  нужно, чтобы восстановить его из журнала подходов.
//
//  Схема хранит `current_rep_min`/`current_rep_max`, но `ExerciseState` их не
//  дублирует: диапазон определяется целью (Goal) и передаётся в функции
//  модуля как `baseRange` — сам он не меняется в ходе прогрессии, меняется
//  только `repExtension` поверх него (SPEC §9.1, §9.5).

/// Состояние прогрессии одного упражнения — срез `exercise_states`,
/// восстанавливаемый `rebuildStates(from:)`.
public struct ExerciseState: Sendable, Equatable {
    /// Базовый рабочий вес. `nil` — упражнение ещё ни разу не выполнялось
    /// (нет журнала, из которого можно было бы его вывести) либо упражнение
    /// без веса (`LoadType.bodyweight`/`.band`).
    public var baselineKg: Double?
    /// Расширение верхней границы диапазона повторов, 0...4 (SPEC §9.5).
    public var repExtension: Int
    /// Добавленные рабочие подходы, 0...2 (SPEC §9.5, п.2;
    /// `exercise_states.extra_sets_added`). Planner прибавляет их к
    /// `target_sets` (SPEC §7.3). Записывает решение каскада, а не число
    /// выполненных подходов: базовое число подходов в журнале не наблюдаемо.
    public var extraSetsAdded: Int
    /// Счётчик застоя (SPEC §9.4).
    public var stallCount: Int
    public var lastPerformedAt: CalendarDay?
    public var isInCalibration: Bool

    public init(
        baselineKg: Double? = nil,
        repExtension: Int = 0,
        extraSetsAdded: Int = 0,
        stallCount: Int = 0,
        lastPerformedAt: CalendarDay? = nil,
        isInCalibration: Bool = true
    ) {
        self.baselineKg = baselineKg
        self.repExtension = repExtension
        self.extraSetsAdded = extraSetsAdded
        self.stallCount = stallCount
        self.lastPerformedAt = lastPerformedAt
        self.isInCalibration = isInCalibration
    }
}

/// Один выполненный рабочий подход — срез `sets` (SPEC §3.1), необходимый
/// для прогрессии. `skipped`/`rest_seconds`/`pain_flag` сюда не входят: они
/// влияют на Planner/Recovery, не на baseline_kg.
public struct SetResult: Sendable, Equatable {
    /// Вес, который был показан пользователю на этот подход, кг
    /// (`sets.prescribed_kg`). Для открывающего подхода это
    /// `baseline_kg × weightReadiness` после округления (SPEC §9.6, §10), для
    /// последующих — то, что назначила внутрисессионная реакция (SPEC §9.3).
    ///
    /// Нужен, чтобы отличить «пользователь сам изменил вес» от «алгоритм
    /// изменил вес»: сравнение `actualKg` с `baseline_kg` для этого не
    /// годится, потому что предписание уже промодулировано готовностью, и
    /// принятое как есть предписание при `weightReadiness` ≠ 1.0 выглядело бы
    /// оверрайдом в обе стороны. Код-ревью feature/progression, 2026-09-07.
    ///
    /// `nil` — вес не предписывался (упражнение без веса) либо не записан;
    /// тогда оверрайд не определяется и считается отсутствующим.
    public var prescribedKg: Double?
    /// Фактический вес, кг. `nil` — упражнение без веса.
    public var actualKg: Double?
    public var actualReps: Int
    public var feedback: Feedback

    public init(prescribedKg: Double?, actualKg: Double?, actualReps: Int, feedback: Feedback) {
        self.prescribedKg = prescribedKg
        self.actualKg = actualKg
        self.actualReps = actualReps
        self.feedback = feedback
    }
}

/// Рабочие подходы одного упражнения в рамках одной тренировки — единица
/// свёртки в `rebuildStates(from:)`. Порядок сессий в передаваемом массиве
/// обязан быть хронологическим (от старой к новой) — свёртка не сортирует.
public struct ExerciseSession: Sendable, Equatable {
    public var performedAt: CalendarDay
    /// Готовность, применённая к весу этого упражнения в этой сессии —
    /// `Readiness.weightReadiness` (SPEC §9.6, §10), а не дневное
    /// `Readiness.value()`. Из журнала — `workout_exercises.weight_readiness`
    /// (SPEC §7.6), дневное `workouts.readiness` не подставляется. Читается
    /// только демпфированием §9.6.
    public var weightReadiness: Double
    /// Пометка «калибровочная» из журнала (`workouts.is_calibration`,
    /// SPEC §3.1) — флаг для UI и аналитики.
    ///
    /// Режимом калибровки он НЕ управляет и свёрткой `rebuildStates` не
    /// читается вовсе: источник истины — `ExerciseState.isInCalibration`,
    /// который та же свёртка и вычисляет по условию выхода §9.8. Почему не
    /// `session.isCalibration || state.isInCalibration` — см. комментарий у
    /// `inCalibrationRegime` в RebuildStates: приложение, продолжающее слать
    /// флаг, держало бы режим открытым вечно и отменяло условия завершения.
    public var isCalibration: Bool
    public var sets: [SetResult]

    public init(performedAt: CalendarDay, weightReadiness: Double, isCalibration: Bool, sets: [SetResult]) {
        self.performedAt = performedAt
        self.weightReadiness = weightReadiness
        self.isCalibration = isCalibration
        self.sets = sets
    }
}
