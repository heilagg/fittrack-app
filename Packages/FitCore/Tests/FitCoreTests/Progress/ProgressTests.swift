import XCTest
@testable import FitCore

private typealias F = PlannerFixtures

/// Прогресс (SPEC §13.7).
final class ProgressTests: XCTestCase {

    func test_groupsPartitionTheMuscleList() {
        let all = MuscleGroup.allCases.flatMap(\.muscles)
        XCTAssertEqual(all.count, MuscleSlug.allCases.count)
        XCTAssertEqual(Set(all), Set(MuscleSlug.allCases))
        XCTAssertEqual(MuscleGroup.of(.trapsUpper), .back)
        XCTAssertEqual(MuscleGroup.of(.rearDelts), .shoulders)
    }

    func test_groupNormIsSumOfBaseColumn() {
        XCTAssertEqual(Progress.groupNorm(.chest, level: .intermediate).norm, 10)
        XCTAssertEqual(Progress.groupNorm(.chest, level: .intermediate).ceiling, 16)
        XCTAssertEqual(Progress.groupNorm(.legsGlutes, level: .intermediate).norm, 60)
        XCTAssertEqual(Progress.groupNorm(.legsGlutes, level: .intermediate).ceiling, 96)
        XCTAssertEqual(Progress.groupNorm(.core, level: .novice).norm, 16)
        XCTAssertEqual(Progress.groupNorm(.arms, level: .advanced).ceiling, 60)
    }

    func test_groupVolumeSumsMuscles() {
        let volume: [MuscleSlug: Double] = [.gluteMax: 8, .quads: 4, .pecs: 3, .trapsUpper: 1, .rearDelts: 2]
        let groups = Progress.groupVolume(volume)
        XCTAssertEqual(groups[.legsGlutes], 12)
        XCTAssertEqual(groups[.chest], 3)
        XCTAssertEqual(groups[.back], 1)
        XCTAssertEqual(groups[.shoulders], 2)
        XCTAssertEqual(groups[.arms], 0)
        XCTAssertEqual(Set(groups.keys), Set(MuscleGroup.allCases))
    }

    /// Точка на каждую сессию — то же, что `rebuildStates` по префиксу.
    func test_baselineSeriesFollowsRebuildStatesPrefixes() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: F.fullEquipment)
        let set = { (kg: Double) in SetResult(prescribedKg: kg, actualKg: kg, actualReps: 12, feedback: .easy) }
        let sessions = (0..<6).map { i in
            ExerciseSession(performedAt: F.day(i * 3), weightReadiness: 1.0, isCalibration: i == 0,
                            sets: [set(8), set(8), set(8)])
        }
        let range = Planner.baseRepRange(goal: .hypertrophy)
        let series = Progress.baselineSeries(sessions: sessions.reversed(), baseRange: range, ladder: ladder)
        XCTAssertEqual(series.map(\.date), series.map(\.date).sorted(), "по дате, независимо от порядка входа")
        for point in series {
            let prefix = sessions.filter { $0.performedAt <= point.date }
            XCTAssertEqual(point.kg, Progression.rebuildStates(from: prefix, baseRange: range, ladder: ladder).baselineKg)
        }
        XCTAssertFalse(series.isEmpty)
        XCTAssertEqual(Progress.baselineSeries(sessions: sessions, baseRange: range, ladder: .none), [],
                       "без лестницы ряда нет (§20.9)")
    }

    func test_streakWeeks() {
        let monday = CalendarDay(year: 2026, month: 10, day: 19)
        let wednesday = monday.adding(days: 2)
        // Активность в эту неделю и две предыдущие подряд → 3.
        let three: Set<CalendarDay> = [wednesday, monday.adding(days: -3), monday.adding(days: -10)]
        XCTAssertEqual(Progress.streakWeeks(activeDays: three, today: wednesday), 3)
        // Текущая без активности серию не рвёт: считаются прошлые.
        let past: Set<CalendarDay> = [monday.adding(days: -3), monday.adding(days: -10)]
        XCTAssertEqual(Progress.streakWeeks(activeDays: past, today: wednesday), 2)
        // Пробел в неделю рвёт серию.
        let gap: Set<CalendarDay> = [wednesday, monday.adding(days: -10)]
        XCTAssertEqual(Progress.streakWeeks(activeDays: gap, today: wednesday), 1)
        XCTAssertEqual(Progress.streakWeeks(activeDays: [], today: wednesday), 0)
    }

    /// Многонедельная проверка §13.7 (implement-feature §5а): десять недель по
    /// три дня, каждый день собирается от состояния, оставленного предыдущими.
    /// Объём каждой недели из `weekDoneVolume` по ВСЕМУ журналу равен сумме
    /// собранных и выполненных сессий именно этой недели; повтор тренировки в
    /// журнале и тренировки соседних недель в неё не попадают.
    func test_weekDoneVolumeOverTenWeeks() throws {
        let library = Dictionary(uniqueKeysWithValues: F.library.map { ($0.slug, $0) })
        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        var history = F.familiarHistory(for: F.library)
        var expected: [CalendarDay: [MuscleSlug: Double]] = [:]
        var steps = 0
        for week in 0..<10 {
            let weekStart = F.day(week * 7)
            let days = F.week([(.lower, .gluteMax, F.lowerGlutes), (.upper, nil, F.upper),
                               (.fullBody, nil, F.flatFullBody)], offsets: [week * 7, week * 7 + 2, week * 7 + 4])
            for index in days.indices {
                let done = Planner.weekDoneVolume(completed: completed, weekStart: weekStart, library: library)
                var input = F.input(week: days, dayIndex: index, fatigue: [:], weekDone: done)
                input.fatigue = fatigue.mapValues(\.value)
                guard let session = Planner.buildSession(input) else { continue }
                F.perform(session, on: days[index].date, completed: &completed, fatigue: &fatigue, history: &history)
                for (m, v) in session.effectiveVolume { expected[weekStart, default: [:]][m, default: 0] += v }
                steps += 1
            }
        }
        XCTAssertGreaterThanOrEqual(steps, 30)
        completed.append(completed[0])  // повторная доставка той же тренировки
        for week in 0..<10 {
            let weekStart = F.day(week * 7)
            let volume = Planner.weekDoneVolume(completed: completed, weekStart: weekStart, library: library)
            let want = expected[weekStart] ?? [:]
            for m in Set(volume.keys).union(want.keys) {
                XCTAssertEqual(volume[m] ?? 0, want[m] ?? 0, accuracy: 1e-9, "неделя \(week), \(m)")
            }
            let groups = Progress.groupVolume(volume)
            XCTAssertEqual(groups.values.reduce(0, +), volume.values.reduce(0, +), accuracy: 1e-9)
        }
    }
}
