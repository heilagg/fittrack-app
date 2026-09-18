//  Недельный объём (SPEC §7.3 «Объём сессии», §7.4). Всё — в эффективных
//  подходах. `S_эфф` нигде не хранится: чистая функция от сетки недели, уровня
//  и нормы ведущей мышцы, поэтому пропуск (меняет `status`, а не состав строк)
//  его не двигает.

/// Выполненная тренировка — вход свёртки `неделя[m]` и «предыдущей тренировки»
/// w6. Ключ — `id` тренировки (§7.3): повторная доставка события и записи с
/// двух устройств не дают одну сессию дважды.
public struct CompletedWorkout: Sendable, Equatable {
    public var id: String
    public var plannedDayID: String?
    public var date: CalendarDay
    public var performedAt: Timestamp
    /// Выполненные подходы по упражнениям.
    public var setsBySlug: [String: Int]

    public init(id: String, plannedDayID: String?, date: CalendarDay, performedAt: Timestamp, setsBySlug: [String: Int]) {
        self.id = id
        self.plannedDayID = plannedDayID
        self.date = date
        self.performedAt = performedAt
        self.setsBySlug = setsBySlug
    }
}

extension Planner {

    // MARK: - Нормы §7.4

    /// Диапазон недельных подходов: базовая или акцентная колонка.
    public static func weeklyRange(level: ExperienceLevel, accented: Bool) -> ClosedRange<Double> {
        switch (level, accented) {
        case (.novice, false): return 8...10
        case (.novice, true): return 10...14
        case (.intermediate, false): return 10...16
        case (.intermediate, true): return 16...20
        case (.advanced, false): return 12...20
        case (.advanced, true): return 20...24
        }
    }

    // Расхождение со SPEC §7.4, не исправленное в спеке: «17.5 за пять дней
    // ягодиц подряд» — число раннего прототипа; текущий алгоритм на калибровочной
    // библиотеке без утомления даёт 16.7 (см. test_scenario27a).

    /// Колонка §7.4 — по сессии (§7.3): акцентная только у акцента этой сессии.
    static func startNorm(_ muscle: MuscleSlug, in day: PlannedDay, level: ExperienceLevel) -> Double {
        weeklyRange(level: level, accented: day.accent == muscle).lowerBound
    }

    static func ceiling(_ muscle: MuscleSlug, in day: PlannedDay, level: ExperienceLevel) -> Double {
        weeklyRange(level: level, accented: day.accent == muscle).upperBound
    }

    // MARK: - S_эфф

    /// Ведущая мышца дня и `S_эфф` (§7.3). Знаменатель — ВСЕ силовые сессии
    /// недели любого статуса: пропуск и оверрайд `rest` его не меняют.
    public static func sessionScale(
        dayIndex: Int,
        week: [PlannedDay],
        level: ExperienceLevel
    ) -> (leadingMuscle: MuscleSlug, scale: Double)? {
        let day = week[dayIndex]
        guard day.isStrength else { return nil }
        func weekShare(_ m: MuscleSlug) -> Double {
            week.filter(\.isStrength).reduce(0) { $0 + ($1.vector[m] ?? 0) }
        }
        if let accent = day.accent, let share = day.vector[accent], share > 0 {
            return (accent, startNorm(accent, in: day, level: level) / weekShare(accent))
        }
        // Без акцента — наименьший масштаб; равные значения дают один масштаб,
        // и выбор слага среди них на числа не влияет (порядок MuscleSlug).
        var best: (MuscleSlug, Double)?
        for m in MuscleSlug.allCases {
            guard let share = day.vector[m], share > 0 else { continue }
            let scale = startNorm(m, in: day, level: level) / weekShare(m)
            if best == nil || scale < best!.1 - 1e-12 { best = (m, scale) }
        }
        return best.map { (leadingMuscle: $0.0, scale: $0.1) }
    }

    // MARK: - неделя[m]

    /// Свёртка по выполненным подходам тренировок недели (§7.3), по ключу
    /// тренировки. Собранный, но не выполненный план сюда не входит.
    public static func weekDoneVolume(
        completed: [CompletedWorkout],
        weekStart: CalendarDay,
        library: [String: ExerciseCandidate]
    ) -> [MuscleSlug: Double] {
        var seen = Set<String>()
        var volume: [MuscleSlug: Double] = [:]
        for workout in completed.sorted(by: { $0.id < $1.id }) {
            let offset = weekStart.days(until: workout.date)
            guard offset >= 0, offset < 7, seen.insert(workout.id).inserted else { continue }
            for (slug, sets) in workout.setsBySlug {
                guard let candidate = library[slug] else { continue }
                for (m, share) in candidate.effectiveContributions {
                    volume[m, default: 0] += Double(sets) * share
                }
            }
        }
        return volume
    }

    /// Эффективный объём набора упражнений с подходами.
    static func effectiveVolume(_ items: [(ExerciseCandidate, Int)]) -> [MuscleSlug: Double] {
        var volume: [MuscleSlug: Double] = [:]
        for (candidate, sets) in items {
            for (m, share) in candidate.effectiveContributions {
                volume[m, default: 0] += Double(sets) * share
            }
        }
        return volume
    }

    // MARK: - Статус недели §7.1

    /// `потеря[m] = Σ по дням с потерянным объёмом (S_эфф × доля[m])`,
    /// округлённая до целого; нули не печатаются. Какие дни теряют объём,
    /// решает `DayOutcome.losesPlannedVolume` (DayOutcome.swift), а не проверка
    /// статуса здесь: пропуск, оверрайд `rest` и замена теряют его одинаково.
    public static func weekLostVolume(
        outcomes: [String: DayOutcome],
        week: [PlannedDay],
        level: ExperienceLevel
    ) -> [ReasonCode] {
        var loss: [MuscleSlug: Double] = [:]
        var causes: [MuscleSlug: DayOutcome.Cause] = [:]
        var biggest: [MuscleSlug: Double] = [:]
        for (i, day) in week.enumerated() where day.isStrength && (outcomes[day.id]?.losesPlannedVolume ?? false) {
            guard let scale = sessionScale(dayIndex: i, week: week, level: level)?.scale else { continue }
            for (m, share) in day.vector {
                let lost = scale * share
                loss[m, default: 0] += lost
                // Строка называет ОДИН день («вторник пропущен» / «сегодня вы
                // выбрали отдых»), поэтому причина берётся от дня, который унёс
                // у этой мышцы больше всех. Ничья остаётся за более ранним днём:
                // недели просматриваются по порядку, и результат детерминирован.
                if lost > (biggest[m] ?? -1) {
                    biggest[m] = lost
                    causes[m] = outcomes[day.id]?.cause
                }
            }
        }
        return MuscleSlug.allCases.compactMap { m in
            let sets = Int((loss[m] ?? 0).rounded())
            guard sets > 0 else { return nil }
            return .weekLossFromSkips(muscle: m, sets: sets, cause: causes[m] ?? .skipped)
        }
    }
}
