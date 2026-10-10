//  Правило разгрузочной недели в режиме без фаз (SPEC §11.5, §19.2 п.4).
//
//  Планировщик признак не считает, а получает на вход (§7.5); считает его
//  вызывающая сторона — сервер на вебе, клиент на iOS — этой функцией, один раз
//  в момент генерации недели, и сохраняет в `week_plans.is_deload`.
//
//  Правило: три выполненные недели накопления, затем разгрузочная. Считаются
//  только недели, в которых была хотя бы одна завершённая тренировка, поэтому
//  отпуск и болезнь ритм не сбивают. Перерыв в 22 дня и больше (граница §9.7)
//  счёт обнуляет: детренированность уже снижает нагрузку после возвращения.

extension Cycle {

    /// Сколько выполненных недель накопления идёт перед разгрузочной.
    public static let accumulationWeeksBeforeDeload = 3

    /// Разгрузочная ли неделя `weekStart`, если её генерируют в день `today`.
    ///
    /// - `workoutDays` — дни завершённых тренировок (`workouts.finished_at` не
    ///   `null`; день — самая ранняя `sets.performed_on`, SPEC §20.7). Порядок и
    ///   повторы не важны. Растяжка без силовой сюда не входит.
    /// - `deloadWeekStarts` — понедельники недель, для которых записано
    ///   `week_plans.is_deload = true`. Неделя в этом множестве, в которой не
    ///   было ни одной тренировки, не потрачена: счёт её не видит.
    /// - Недели, начавшиеся не раньше `weekStart`, в счёт не входят.
    ///
    /// В фазовом режиме всегда `false`: объём там задаёт периодизация (§11.2).
    public static func isDeloadWeek(
        weekStart: CalendarDay,
        today: CalendarDay,
        phaseMode: PhaseMode,
        workoutDays: [CalendarDay],
        deloadWeekStarts: Set<CalendarDay>
    ) -> Bool {
        guard phaseMode == .noPhases else { return false }

        let executed = Dictionary(
            grouping: Set(workoutDays).filter { $0.mondayOfWeek < weekStart },
            by: \.mondayOfWeek)

        var accumulated = 0
        var previousWorkout: CalendarDay?
        for monday in executed.keys.sorted() {
            let days = executed[monday]!.sorted()
            if let previousWorkout, isBreak(from: previousWorkout, to: days[0]) {
                accumulated = 0
            }
            // Выполненная разгрузочная неделя обнуляет счёт; любая другая
            // выполненная — добавляет единицу.
            accumulated = deloadWeekStarts.contains(monday) ? 0 : accumulated + 1
            previousWorkout = days[days.count - 1]
        }

        if let previousWorkout, isBreak(from: previousWorkout, to: today) { return false }
        return accumulated >= accumulationWeeksBeforeDeload
    }

    /// Перерыв — граница «22–45 дней» §9.7, чтобы число жило в одном месте.
    private static func isBreak(from last: CalendarDay, to next: CalendarDay) -> Bool {
        Progression.detrainingAdjustment(daysSinceLastPerformed: last.days(until: next))
            .resetsProgressionCounters
    }
}
