//  Прогресс (SPEC §13.7): группы мышц, норма группы и ряд базовой линии.
//
//  Объём по неделям — это `Planner.weekDoneVolume`, та же свёртка `неделя[m]`,
//  что у планировщика (§7.3), и второй реализации здесь нет: этот файл только
//  сворачивает мышцы в группы и считает их норму. Базовая линия — та же
//  `Progression.rebuildStates`, что у сборки и сервера, по префиксам журнала:
//  хранить её историю не нужно, она восстанавливается.

/// Группа мышц экрана прогресса (§13.7). Каждая мышца §6.4 — ровно в одной.
public enum MuscleGroup: String, Sendable, Equatable, Hashable, CaseIterable {
    case legsGlutes = "legs_glutes"
    case back
    case chest
    case shoulders
    case arms
    case core

    /// Таблица §13.7.
    public var muscles: [MuscleSlug] {
        switch self {
        case .legsGlutes: return [.gluteMax, .gluteMed, .quads, .hamstrings, .adductors, .calves]
        case .back: return [.lats, .trapsMid, .trapsUpper, .erectors]
        case .chest: return [.pecs]
        case .shoulders: return [.frontDelts, .sideDelts, .rearDelts]
        case .arms: return [.biceps, .triceps, .forearms]
        case .core: return [.abs, .obliques]
        }
    }

    public static func of(_ muscle: MuscleSlug) -> MuscleGroup {
        allCases.first { $0.muscles.contains(muscle) }!
    }
}

/// Точка базовой линии: день сессии и `baseline_kg` после неё.
public struct BaselinePoint: Sendable, Equatable {
    public var date: CalendarDay
    public var kg: Double

    public init(date: CalendarDay, kg: Double) {
        self.date = date
        self.kg = kg
    }
}

public enum Progress {

    /// Объём недели по группам: сумма эффективных подходов её мышц (§13.7).
    public static func groupVolume(_ volume: [MuscleSlug: Double]) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for group in MuscleGroup.allCases {
            result[group] = group.muscles.reduce(0) { $0 + (volume[$1] ?? 0) }
        }
        return result
    }

    /// Норма и потолок группы (§13.7): суммы нижних и верхних границ базовой
    /// колонки §7.4 её мышц. Акцентная колонка не используется — она относится
    /// к сессии (§7.3), а не к неделе.
    public static func groupNorm(_ group: MuscleGroup, level: ExperienceLevel) -> (norm: Double, ceiling: Double) {
        let range = Planner.weeklyRange(level: level, accented: false)
        let count = Double(group.muscles.count)
        return (range.lowerBound * count, range.upperBound * count)
    }

    /// Ряд базовой линии упражнения (§13.7): точка на каждую сессию —
    /// `baseline_kg` после неё по журналу до неё включительно. Сессии без веса
    /// точки не дают; у упражнения без лестницы ряда нет вовсе.
    public static func baselineSeries(
        sessions: [ExerciseSession],
        baseRange: ClosedRange<Int>,
        ladder: WeightLadder
    ) -> [BaselinePoint] {
        guard ladder != .none else { return [] }
        let ordered = sessions.sorted { $0.performedAt < $1.performedAt }
        var points: [BaselinePoint] = []
        for index in ordered.indices {
            let state = Progression.rebuildStates(from: Array(ordered[...index]),
                                                  baseRange: baseRange, ladder: ladder)
            if let kg = state.baselineKg {
                points.append(BaselinePoint(date: ordered[index].performedAt, kg: kg))
            }
        }
        return points
    }

    /// Стрик (§13.7): число ISO-недель подряд, в каждой хотя бы одна
    /// активность. Текущая неделя без активности серию не рвёт, пока не
    /// кончилась: тогда считаются недели до неё. `activeDays` — дни любой
    /// активности (силовая, растяжка, кардио).
    public static func streakWeeks(activeDays: Set<CalendarDay>, today: CalendarDay) -> Int {
        let activeWeeks = Set(activeDays.map(\.mondayOfWeek))
        var week = today.mondayOfWeek
        if !activeWeeks.contains(week) { week = week.adding(days: -7) }
        var count = 0
        while activeWeeks.contains(week) {
            count += 1
            week = week.adding(days: -7)
        }
        return count
    }
}
