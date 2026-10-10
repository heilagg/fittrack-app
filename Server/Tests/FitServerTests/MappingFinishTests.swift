//  Выбор статуса дня и причины пересборки на `/finish` (SPEC §7.1, §20.3).
//
//  Юнит-тестом, а не через HTTP: причина видна в ответе только внутри строки
//  «План обновлён», а её на неделе из одного дня по §7.1 нет вовсе — уход дня
//  по факту исполнения изменением плана не считается. Живой тест зависел бы
//  от того, в какой день недели он запущен.

import Testing
import FitCore
@testable import FitServer

@Suite("Mapping.finishOutcome: чем закрывается день")
struct MappingFinishTests {

    private let day = CalendarDay(dayNumber: 20_000)

    private func row(feedback: String? = "ok", reps: Int? = 10, skipped: Bool = false,
                     calibration: Bool = false) -> Mapping.SetRow {
        Mapping.SetRow(exerciseSlug: "x", actualReps: reps, feedback: feedback, skipped: skipped,
                       isCalibration: calibration, performedOn: day)
    }

    @Test("выполненный подход — done и workoutCompleted")
    func performedSetMeansDone() {
        let outcome = Mapping.finishOutcome([row(skipped: true), row()])
        #expect(outcome.status == .done)
        #expect(outcome.cause == .workoutCompleted)
    }

    @Test("калибровочный подход тоже выполнен")
    func calibrationSetCounts() {
        #expect(Mapping.finishOutcome([row(calibration: true)]).status == .done)
    }

    @Test("пропуски, подходы без фидбэка или повторов и пустой журнал — skipped и workoutSkipped")
    func nothingPerformedMeansSkipped() {
        for sets in [[], [row(skipped: true)], [row(feedback: nil)], [row(reps: nil)]] {
            let outcome = Mapping.finishOutcome(sets)
            #expect(outcome.status == .skipped)
            #expect(outcome.cause == .workoutSkipped)
        }
    }
}
