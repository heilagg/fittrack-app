//  Правило разгрузочной недели (SPEC §11.5, §19.2 п.4).
//
//  XCTest, как весь пакет. Каждая проверка ставится на одно положение правила,
//  чтобы сломанная версия роняла ровно свой тест.

import XCTest
@testable import FitCore

final class DeloadWeekTests: XCTestCase {

    /// 2026-01-05 — понедельник.
    private let week0 = CalendarDay(year: 2026, month: 1, day: 5)

    private func monday(_ n: Int) -> CalendarDay { week0.adding(days: 7 * n) }
    /// Среда недели `n` — тренировочный день.
    private func workout(_ n: Int, dayOffset: Int = 2) -> CalendarDay { monday(n).adding(days: dayOffset) }

    private func isDeload(_ target: Int, workouts: [CalendarDay], deloads: [Int] = [],
                          today: CalendarDay? = nil,
                          mode: PhaseMode = .noPhases) -> Bool {
        Cycle.isDeloadWeek(
            weekStart: monday(target), today: today ?? monday(target),
            phaseMode: mode, workoutDays: workouts,
            deloadWeekStarts: Set(deloads.map(monday)))
    }

    func test_fourthExecutedWeekIsDeload() {
        let history = [0, 1, 2].map { workout($0) }
        XCTAssertTrue(isDeload(3, workouts: history))
        XCTAssertFalse(isDeload(2, workouts: [0, 1].map { workout($0) }), "после двух недель рано")
    }

    func test_emptyWeeksAreNotCounted() {
        // Недели 0, 1, [пусто: 2, 3], 4: три выполненные, и неделя 5 — разгрузочная,
        // хотя по календарю прошло шесть недель.
        let history = [0, 1, 4].map { workout($0) }
        XCTAssertTrue(isDeload(5, workouts: history))
        // А две выполненные и две пустые — всё ещё накопление.
        XCTAssertFalse(isDeload(4, workouts: [0, 3].map { workout($0) }))
    }

    func test_executedDeloadWeekResetsTheCount() {
        let history = [0, 1, 2, 3].map { workout($0) }
        XCTAssertFalse(isDeload(4, workouts: history, deloads: [3]),
                       "неделя 3 была разгрузочной и выполнена — счёт с нуля")
        let more = history + [workout(4), workout(5), workout(6)]
        XCTAssertTrue(isDeload(7, workouts: more, deloads: [3]))
    }

    func test_emptyDeloadWeekIsNotSpent() {
        // Неделя 3 сгенерирована разгрузочной, тренировок в ней не было.
        let history = [0, 1, 2].map { workout($0) }
        XCTAssertTrue(isDeload(4, workouts: history, deloads: [3]),
                      "пустая разгрузочная не потрачена: следующая снова разгрузочная")
    }

    func test_breakOf22DaysResetsTheCount() {
        // Недели 0, 1, 2, затем тренировка ровно через 22 дня после последней
        // (четверг недели 5): перерыв §9.7, счёт заново.
        let history = [workout(0), workout(1), workout(2), workout(2).adding(days: 22)]
        XCTAssertFalse(isDeload(6, workouts: history),
                       "после перерыва выполнена одна неделя, а не четыре")
    }

    func test_gapOf21DaysDoesNotReset() {
        let history = [workout(0), workout(1), workout(2).adding(days: 0), workout(2).adding(days: 21)]
        // Недели 0, 1, 2 и неделя с днём +21 (то есть 5): четыре выполненные.
        XCTAssertTrue(isDeload(6, workouts: history),
                      "21 день — ещё не перерыв §9.7")
    }

    func test_trailingBreakUntilGenerationDay() {
        let history = [0, 1, 2].map { workout($0) }
        let late = workout(2).adding(days: 22)
        XCTAssertFalse(isDeload(4, workouts: history, today: late),
                       "последняя тренировка 22 дня назад — возвращение, не разгрузка")
        XCTAssertTrue(isDeload(4, workouts: history, today: workout(2).adding(days: 21)))
    }

    func test_phasesModeNeverDeloads() {
        let history = [0, 1, 2].map { workout($0) }
        XCTAssertFalse(isDeload(3, workouts: history, mode: .phases))
    }

    func test_weeksFromTheTargetWeekOnAreIgnored() {
        // Тренировка в самой генерируемой неделе и в следующей в счёт не идёт.
        let history = [0, 1].map { workout($0) } + [workout(2), workout(3)]
        XCTAssertFalse(isDeload(2, workouts: history),
                       "неделя 2 — сама генерируемая, до неё выполнено две")
    }

    func test_historyOfAnotherModeCountsAndThresholdIsAtLeastThree() {
        // Десять выполненных недель (прожитых в фазовом режиме, где признак
        // false): при переходе разгрузка наступает сразу.
        let history = (0..<10).map { workout($0) }
        XCTAssertTrue(isDeload(10, workouts: history))
    }

    func test_mondayOfWeek() {
        XCTAssertEqual(workout(0, dayOffset: 6).mondayOfWeek, monday(0), "воскресенье — к понедельнику той же недели")
        XCTAssertEqual(monday(1).mondayOfWeek, monday(1))
    }
}
