//  Тело `GET /v1/progress` (SPEC §13.7, §20.3) — чистая функция от прочитанного.
//
//  Ни одной своей формулы: объём — `Planner.weekDoneVolume` (§7.3), группы и
//  нормы — `Progress`, базовая линия — `Progress.baselineSeries` поверх
//  `rebuildStates`, фаза — `Cycle.state`, стрик — `Progress.streakWeeks`.

import FitAPI
import FitCore

extension Mapping {

    /// Всё, что путь прочитал из базы.
    public struct ProgressInputs: Sendable {
        public var from: CalendarDay
        public var to: CalendarDay
        public var today: CalendarDay
        public var level: ExperienceLevel
        public var goal: Goal
        public var equipment: EquipmentProfile
        public var library: [String: ExerciseCandidate]
        /// Завершённые тренировки окна — с понедельника недели `from` (§20.3):
        /// объём недель считается по ним.
        public var completed: [CompletedWorkout]
        /// Дни силовых за всю историю — календарь и стрик (§13.7). Отдельно от
        /// `completed`: серия недель окном не ограничена, а журнал ей не нужен.
        public var strengthDays: Set<CalendarDay>
        /// Журнал подходов, сгруппированный в сессии по упражнениям (§9).
        public var history: [String: [ExerciseSession]]
        public var stretchDays: Set<CalendarDay>
        public var skippedDays: Set<CalendarDay>
        public var cycle: CycleInputs

        public init(from: CalendarDay, to: CalendarDay, today: CalendarDay, level: ExperienceLevel,
                    goal: Goal, equipment: EquipmentProfile, library: [String: ExerciseCandidate],
                    completed: [CompletedWorkout], strengthDays: Set<CalendarDay>,
                    history: [String: [ExerciseSession]],
                    stretchDays: Set<CalendarDay>, skippedDays: Set<CalendarDay>, cycle: CycleInputs) {
            self.from = from
            self.to = to
            self.today = today
            self.level = level
            self.goal = goal
            self.equipment = equipment
            self.library = library
            self.completed = completed
            self.strengthDays = strengthDays
            self.history = history
            self.stretchDays = stretchDays
            self.skippedDays = skippedDays
            self.cycle = cycle
        }
    }

    public static func progress(_ input: ProgressInputs) -> ProgressDTO {
        let iso = LocalTime.iso
        var weeks: [ProgressWeekDTO] = []
        var weekStart = input.from.mondayOfWeek
        while weekStart <= input.to {
            let volume = Planner.weekDoneVolume(completed: input.completed, weekStart: weekStart,
                                                library: input.library)
            let groups = Progress.groupVolume(volume)
            weeks.append(ProgressWeekDTO(
                weekStart: iso(weekStart), partial: weekStart == input.today.mondayOfWeek,
                groups: Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value) })))
            weekStart = weekStart.adding(days: 7)
        }

        // Только упражнения с весом (лестница не пуста) и с точками в окне.
        let baseRange = Planner.baseRepRange(goal: input.goal)
        var baselines: [BaselineSeriesDTO] = []
        for slug in input.history.keys.sorted() {
            guard let candidate = input.library[slug] else { continue }
            let ladder = WeightLadder.build(loadType: candidate.loadType, profile: input.equipment)
            let points = Progress.baselineSeries(sessions: input.history[slug] ?? [],
                                                 baseRange: baseRange, ladder: ladder)
                .filter { $0.date >= input.from && $0.date <= input.to }
            guard !points.isEmpty else { continue }
            baselines.append(BaselineSeriesDTO(
                slug: slug, points: points.map { BaselinePointDTO(date: iso($0.date), kg: $0.kg) }))
        }

        let strengthDays = input.strengthDays
        var days: [ProgressDayDTO] = []
        var day = input.from
        while day <= input.to {
            days.append(ProgressDayDTO(
                date: iso(day), strength: strengthDays.contains(day), stretch: input.stretchDays.contains(day),
                skipped: input.skippedDays.contains(day), phase: phaseAsKnown(on: day, cycle: input.cycle)))
            day = day.adding(days: 1)
        }

        return ProgressDTO(
            from: iso(input.from), to: iso(input.to), weeks: weeks,
            groupNorms: MuscleGroup.allCases.map { GroupNormDTO(group: $0, level: input.level) },
            baselines: baselines, days: days,
            streakWeeks: Progress.streakWeeks(activeDays: strengthDays.union(input.stretchDays), today: input.today))
    }

    /// Фаза дня, как её знали в тот день (§13.7): события с `occurred_on` не
    /// позже дня — других отметок времени у `cycle_events` нет. Показывается при
    /// уверенности не ниже порога §11.3, в режиме без фаз — никогда. Экранная
    /// (§11.6): ранняя и поздняя лютеиновая — одна.
    static func phaseAsKnown(on day: CalendarDay, cycle: CycleInputs) -> DisplayPhase? {
        guard cycle.profile.phaseMode == .phases else { return nil }
        let state = Cycle.state(events: cycle.events.filter { $0.occurredOn <= day }, profile: cycle.profile,
                                responseProfiles: cycle.responseProfiles, asOf: day)
        guard let phase = state.phase, let confidence = state.cycleConfidence,
              confidence >= Cycle.categoricalConfidenceThreshold else { return nil }
        return phase.displayPhase
    }
}
