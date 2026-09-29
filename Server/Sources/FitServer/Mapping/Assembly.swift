//  Сборка входов FitCore из срезов (SPEC §7.1, §7.3, §20.3, §20.6).
//
//  Срезы независимы друг от друга и читаются по отдельности; здесь они
//  соединяются в то, что принимает ядро: `WeekContext` для плана недели и
//  `PrescriptionInput` для чисел на момент старта.
//
//  ── Почему сборка — отдельный файл, а не по месту в роуте ─────────────────
//
//  Потому что соответствие «срез → поле» и есть та часть контракта, которую
//  §20.2 обещает разделить с iOS. Собранный в роуте `WeekContext` был бы вторым
//  соответствием: iOS линкует `Mapping/`, а не `Routes/`.
//
//  ── Два утомления и один момент ───────────────────────────────────────────
//
//  `WeekContext.fatigue` получает состояние ДО распада: `planRemainingDays`
//  декает его сам, до 12:00 каждого дня (§7.1). `PrescriptionInput.fatigue` —
//  уже продеканное, до ФАКТИЧЕСКОГО момента старта (§20.3). Это единственное
//  поле, которым два входа отличаются по смыслу, и потому единственное, которое
//  здесь считается дважды разными функциями.

import FitCore
import FitContent

extension Mapping {

    /// Вход недельного планировщика (§7.1).
    ///
    /// `isDeloadWeek` приходит из `week_plans.is_deload`, а не выводится:
    /// признак зафиксирован в момент генерации и пересборкой не пересчитывается
    /// (§11.5), а правило счёта открыто (§19.2 п.4) — до его закрытия там всегда
    /// `false`.
    public static func weekContext(
        weekStart: CalendarDay,
        today: CalendarDay,
        days: [PlannedDayRow],
        vectors: DayVectorTable,
        library: [ExerciseCandidate],
        profile: CompleteProfile,
        sessionMinutes: Int,
        equipment: EquipmentSlice,
        safety: SafetyProfile,
        cycle: CycleInputs,
        checkin: DailyCheckin,
        override: Override?,
        fatigue: [MuscleSlug: FatigueState],
        journal: [SetRow],
        completed: [CompletedWorkoutRow],
        completedSets: [String: [SetRow]],
        startedDayIDs: Set<String>,
        isDeloadWeek: Bool,
        userSeed: UInt64
    ) -> WeekContext {
        WeekContext(
            weekStart: weekStart,
            week: plannedDays(from: days, vectors: vectors),
            today: today,
            startedDayIDs: startedDayIDs,
            completed: completedWorkouts(rows: completed, sets: completedSets),
            // ДО распада (§20.6, обязанность 6).
            fatigue: fatigue,
            library: library,
            availability: equipment.availability,
            equipment: equipment.profile,
            safety: safety,
            goal: profile.goal,
            sessionMinutes: sessionMinutes,
            // Сырой журнал, а не состояния (обязанность 7): свёртку планировщик
            // делает сам, с лестницей ТЕКУЩЕГО инвентаря.
            exerciseHistory: exerciseHistory(from: journal),
            cycle: cycle,
            todayCheckin: checkin,
            todayOverride: override,
            isDeloadWeek: isDeloadWeek,
            userSeed: userSeed
        )
    }

    /// Вход пересчёта чисел на момент старта (§20.3).
    ///
    /// Девять полей, и восемь остальных полей `SessionInput` подставлять некуда
    /// — тип их не принимает. Готовность и состояние цикла считаются на дату
    /// ДНЯ теми же публичными функциями, что использовала сборка, иначе числа
    /// разойдутся с показанными на карточке дня (§20.15, 20l).
    ///
    /// `checkin` и `override` передаются только для СЕГОДНЯШНЕГО дня: у
    /// будущего их ещё нет, и §7.1 собирает такие дни от замороженного
    /// состояния. Здесь это тот же вызов с пустыми значениями, а не отдельная
    /// ветка.
    public static func prescriptionInput(
        day: PlannedDay,
        startMoment: Timestamp,
        library: [ExerciseCandidate],
        profile: CompleteProfile,
        equipment: EquipmentSlice,
        safety: SafetyProfile,
        cycle: CycleInputs,
        checkin: DailyCheckin,
        override: Override?,
        fatigue: [MuscleSlug: FatigueState],
        journal: [SetRow]
    ) -> PrescriptionInput {
        let cycleState = Cycle.state(events: cycle.events, profile: cycle.profile,
                                     responseProfiles: cycle.responseProfiles, asOf: day.date)
        return PrescriptionInput(
            day: day,
            library: library,
            // Та же свёртка, что у планировщика: `Planner.exerciseStates`
            // сортирует журнал внутри себя и строит лестницу текущего
            // инвентаря. Собственной свёртки слой не делает.
            exerciseStates: Planner.exerciseStates(history: exerciseHistory(from: journal),
                                                   library: library, goal: profile.goal,
                                                   equipment: equipment.profile),
            equipment: equipment.profile,
            goal: profile.goal,
            safety: safety,
            // ПОСЛЕ распада, до фактического момента старта (§20.3).
            fatigue: decayedFatigue(fatigue, to: startMoment),
            readiness: Readiness.value(cycleState: cycleState, override: override, checkin: checkin),
            cycleState: cycleState
        )
    }

    /// Диапазоны повторов, которые пишутся в `exercise_states` вместе с сессией
    /// (§20.6, обязанность 13).
    ///
    /// Берутся из `PrescribedExercise`, а не своим вызовом `Planner.repRange`:
    /// состояние после сбросов §9.7 накладывает СБОРКА, и повторить его снаружи
    /// нечем. Свой вызов дал бы после тридцати дней перерыва `8...15` там, где
    /// сессия предписала `8...12`, и в колонку легло бы число, которого
    /// пользовательница не видела.
    ///
    /// Для упражнений вне сессии колонки не трогаются — они снимок ПОСЛЕДНЕЙ
    /// сессии, а не текущее значение (§3.1), поэтому словарь несёт только то,
    /// что в сессии есть.
    public static func repRangeUpdates(for session: BuiltSession) -> [String: ClosedRange<Int>] {
        Dictionary(uniqueKeysWithValues: session.exercises.map {
            ($0.slug, $0.targetRepMin...$0.targetRepMax)
        })
    }
}
