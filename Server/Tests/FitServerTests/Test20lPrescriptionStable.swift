//  Тест 20l (§20.15): пересобранный `PrescriptionInput` даёт те же числа, что
//  дала сборка.
//
//  §20.3 развёл момент оценки по роли числа: состав считается на 12:00, а
//  `target_rir`, `weight_readiness` и `prescribed_kg` — на фактический момент
//  старта, вторым вызовом `Planner.prescribe` поверх готовой сессии. Узкий
//  входной тип защищает от чтения лишнего поля, но не от того, что вызывающая
//  сторона посчитает девять оставшихся ИНАЧЕ, чем считала сборка: готовность не
//  на ту дату, состояние цикла без профилей реакции, состояния упражнений с
//  другой лестницей.
//
//  Поэтому тест фиксирует УТОМЛЕНИЕ, а не время: `prescribe` зовётся на
//  утомлении, продеканном до ТОГО ЖЕ момента 12:00, из которого собиралась
//  сессия, и ни одно из трёх чисел не обязано измениться. Дважды предписанный
//  день расхождением не является и в тест не входит — разница между карточкой и
//  стартом есть контракт §20.3, а не дрейф.
//
//  Расхождение здесь не падает и не видно в ответе: оно проявляется весом,
//  отличным от показанного на карточке дня. Поэтому утверждение ставится на
//  числа, а не на статус.
//
//  ── Утомление сеется, и это не обход границы ──────────────────────────────
//
//  Без него распад — тождество, и тест проверял бы только восемь остальных
//  полей. `muscle_fatigue` пишет сервер (§20.6), но делает это `/finish`,
//  которого ещё нет; значения на шкале FitCore (§20.7) кладутся прямо, как их
//  положит он. Читает их тот же `Mapping.readFatigue`, что и продакшен-путь.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitContent
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20l: предписание на том же утомлении не двигает числа (§20.15)",
       .enabled(if: Live.enabled), .serialized)
struct Test20lPrescriptionStable {

    private let zone = TimeZone(identifier: "Europe/Moscow")!

    private var today: CalendarDay { Mapping.LocalTime.day(of: Date(), in: zone) }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: zone.identifier)
    }

    @Test("ни target_rir, ни weight_readiness, ни prescribed_kg не сдвинулись")
    func test20l_prescriptionMatchesTheBuild() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20l")
        let library = try Content.loadBundled()

        try await Live.withServer("test.20l") { app, database in
            try await Live.seed(app, user, logger: logger, weekdays: [self.todayISOWeekday])

            // Утомление подбирается так, чтобы сдвиг момента ПЕРЕСЕКАЛ порог
            // §8.2, а не просто менял число. Пороги — полосы (0.8 и 1.8), и на
            // 1.4 десять часов распада дают 0.99: та же полоса, те же RIR и
            // `weight_readiness`, то есть проба «а двигается ли хоть что-то»
            // отвечала бы «нет» — и тест проходил бы, даже если бы
            // `prescribe` утомление не читал вовсе. Так он однажды и был
            // написан, и это поймала именно проба, а не прогон.
            //
            // Метка ставится РОВНО на момент оценки: тогда распад до 12:00 —
            // ноль, и 1.9 это значение, которое видит сборка. Через десять
            // часов (полураспад 20 ч) остаётся 1.34, то есть 1.8 перейдено.
            let moment = Planner.evaluationMoment(for: self.today)
            try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> Void in
                for muscle in MuscleSlug.allCases {
                    try await tx.query("""
                        insert into muscle_fatigue (user_id, muscle, value, updated_at)
                        values (\(user.id), \(muscle.rawValue), 1.9,
                                (to_timestamp(\(moment.hoursSinceEpoch * 3600))
                                 at time zone 'UTC'))
                        """)
                }
            }

            let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(self.weekStart),
                                               day: self.day)
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .created,
                        Comment(rawValue: String(buffer: response.body)))
            }

            try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> Void in
                let requestDay = try RequestDay.validated(date: self.day.date, tz: self.day.tz)
                let inputs = try await WeekPlanRoutes.inputs(tx, on: requestDay)
                #expect(!inputs.fatigue.isEmpty, "утомление посеяно и прочитано")

                let plan = try await Mapping.readWeekPlan(tx, weekStart: self.weekStart)
                let weekPlan = try #require(plan)
                let rows = try await Mapping.readPlannedDays(tx, weekPlanID: weekPlan.id)
                let context = WeekPlanRoutes.context(
                    inputs, weekStart: self.weekStart, today: requestDay.date, days: rows,
                    isDeload: weekPlan.isDeload, library: library,
                    userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))

                // Сборка — ровно та, что показала карточка дня.
                let built = Planner.planRemainingDays(context)
                let outcome = try #require(built.days.values.first { $0.session != nil })
                let session = try #require(outcome.session)
                #expect(!session.exercises.isEmpty)

                let plannedDay = try #require(
                    Mapping.plannedDays(from: rows, vectors: library.vectors)
                        .first { $0.id == outcome.dayID })

                // Предписание на ТОМ ЖЕ моменте — 12:00 дня сессии.
                let sessionMoment = Planner.evaluationMoment(for: plannedDay.date)
                let prescribed = try #require(Planner.prescribe(
                    session,
                    on: Mapping.prescriptionInput(
                        day: plannedDay, startMoment: sessionMoment, library: library.candidates,
                        profile: inputs.complete, equipment: inputs.equipment,
                        safety: inputs.safety, cycle: inputs.cycle, checkin: inputs.checkin,
                        override: inputs.override, fatigue: inputs.fatigue,
                        journal: inputs.journal)),
                    "сессия собрана не на этом входе — девять полей разошлись")

                #expect(prescribed.exercises.map(\.slug) == session.exercises.map(\.slug),
                        "состав предписание не меняет")
                for (after, before) in zip(prescribed.exercises, session.exercises) {
                    #expect(after.targetRIR == before.targetRIR,
                            Comment(rawValue: "target_rir сдвинулся на \(before.slug)"))
                    #expect(after.weightReadiness == before.weightReadiness,
                            Comment(rawValue: "weight_readiness сдвинулся на \(before.slug)"))
                    #expect(after.prescribedKg == before.prescribedKg,
                            Comment(rawValue: "prescribed_kg сдвинулся на \(before.slug)"))
                    // И то, что предписание не трогает вовсе (§20.3).
                    #expect(after.targetSets == before.targetSets)
                    #expect(after.targetRepMin == before.targetRepMin)
                    #expect(after.targetRepMax == before.targetRepMax)
                }

                let later = try #require(Planner.prescribe(
                    session,
                    on: Mapping.prescriptionInput(
                        day: plannedDay, startMoment: sessionMoment.adding(hours: 10),
                        library: library.candidates, profile: inputs.complete,
                        equipment: inputs.equipment, safety: inputs.safety, cycle: inputs.cycle,
                        checkin: inputs.checkin, override: inputs.override,
                        fatigue: inputs.fatigue, journal: inputs.journal)))
                let moved = zip(later.exercises, session.exercises).contains {
                    $0.targetRIR != $1.targetRIR || $0.weightReadiness != $1.weightReadiness
                        || $0.prescribedKg != $1.prescribedKg
                }
                // **Утверждение о неслепоте самого теста.** Без него 20l
                // проходил бы и в том случае, если бы `prescribe` утомление не
                // читал вовсе: совпадение чисел на двух моментах было бы
                // тождеством, а не свойством. Проверено на первой же версии
                // этого файла — с утомлением 1.4 сдвиг на десять часов не
                // двигал ничего, потому что обе величины лежали в одной полосе
                // порогов §8.2, и зелёный ничего не значил.
                #expect(moved, """
                    сдвиг момента не меняет ни одного из трёх чисел — значит и \
                    совпадение на одном моменте ничего не доказывает
                    """)
            }
        }
    }
}
