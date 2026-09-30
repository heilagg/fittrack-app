//  `GET` и `PATCH /v1/profile` через HTTP (SPEC §4.1, §5, §20.3, §20.6).
//
//  Пути, без которых онбординг §5 пройти было нечем. Проверяется то, ради чего
//  они устроены именно так: пошаговая запись, три состояния поля, неполный
//  профиль как законное состояние и переход к полному.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("Профиль через HTTP (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveProfileTests {

    private func patch(_ app: Application, _ user: Live.User,
                       _ body: PatchProfileRequest) async throws -> (Int, ProfileDTO?) {
        var captured: (Int, ProfileDTO?) = (0, nil)
        try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code),
                        try? JSONDecoder().decode(ProfileDTO.self, from: Data(buffer: response.body)))
        }
        return captured
    }

    private func get(_ app: Application, _ user: Live.User) async throws -> (Int, ProfileDTO?) {
        var captured: (Int, ProfileDTO?) = (0, nil)
        try await app.testing().test(.GET, "/v1/profile", headers: user.headers) { response in
            captured = (Int(response.status.code),
                        try? JSONDecoder().decode(ProfileDTO.self, from: Data(buffer: response.body)))
        }
        return captured
    }

    // MARK: - Пошаговый онбординг

    @Test("профиль заполняется по шагам, и до шага 6 он законно неполон (§5)")
    func stepwiseOnboarding() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.steps") { app in
            // Шага не было вовсе — строки нет.
            let (before, _) = try await self.get(app, user)
            #expect(before == 404, "онбординг не начинали — профиля нет")

            // Шаг 3: пол, год, рост. Строка появляется НЕПОЛНОЙ.
            let (s3, afterStep3) = try await self.patch(app, user, PatchProfileRequest(
                sexAtBirth: .some("female"), birthYear: .some(1994), heightCm: .some(168)))
            #expect(s3 == 200)
            #expect(afterStep3?.isComplete == false)
            #expect(afterStep3?.sexAtBirth == "female")
            #expect(afterStep3?.experienceLevel == nil, "шага 4 ещё не было")
            #expect(afterStep3?.sessionMinutes == 45, "умолчание схемы")
            #expect(afterStep3?.cycleTracking == .off)

            // Шаг 4 и 5 по одному полю — предыдущие не трогаются.
            _ = try await self.patch(app, user, PatchProfileRequest(experienceLevel: .some(.novice)))
            let (_, afterStep5) = try await self.patch(app, user,
                                                       PatchProfileRequest(goal: .some(.strength)))
            #expect(afterStep5?.sexAtBirth == "female", "шаг 3 пережил шаги 4 и 5")
            #expect(afterStep5?.experienceLevel == .novice)
            #expect(afterStep5?.goal == .strength)
            #expect(afterStep5?.isComplete == false, "дней ещё нет")

            // Шаг 6 — профиль становится полным.
            let (_, afterStep6) = try await self.patch(app, user, PatchProfileRequest(
                trainingWeekdays: .some([5, 1, 3]), sessionMinutes: 60))
            #expect(afterStep6?.isComplete == true)
            #expect(afterStep6?.trainingWeekdays == [1, 3, 5], "набор канонизируется сервером")
            #expect(afterStep6?.daysPerWeek == 3, "число выводится из набора")
            #expect(afterStep6?.sessionMinutes == 60)

            // И GET видит то же самое.
            let (status, fetched) = try await self.get(app, user)
            #expect(status == 200)
            #expect(fetched == afterStep6)
        }
    }

    // MARK: - Три состояния поля (§20.3)

    @Test("отсутствие ключа не трогает поле, явный null снимает значение")
    func absentVersusNull() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.tristate") { app in
            _ = try await self.patch(app, user, PatchProfileRequest(
                sexAtBirth: .some("female"), birthYear: .some(1994),
                experienceLevel: .some(.advanced)))

            // Ключа нет — поле на месте.
            let (_, untouched) = try await self.patch(app, user,
                                                      PatchProfileRequest(goal: .some(.toning)))
            #expect(untouched?.birthYear == 1994, "год рождения не присылали — он остался")

            // Явный null — поле снято.
            let (_, cleared) = try await self.patch(app, user,
                                                    PatchProfileRequest(birthYear: .some(nil)))
            #expect(cleared?.birthYear == nil, "явный null снимает значение")
            #expect(cleared?.sexAtBirth == "female", "соседнее поле не тронуто")
        }
    }

    // MARK: - Настройки цикла вложенным объектом

    @Test("шаг 9 пишет обе таблицы одним запросом (§20.3)")
    func cycleTravelsNested() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.cycle") { app in
            let (_, before) = try await self.patch(app, user,
                                                   PatchProfileRequest(goal: .some(.general)))
            #expect(before?.cycle == nil, "строки cycle_profiles ещё нет — законное состояние")

            // Контрацепция: режим без фаз с причиной (§5 шаг 9, §11.5).
            let (status, after) = try await self.patch(app, user, PatchProfileRequest(
                cycleTracking: .manual,
                cycle: CycleProfileDTO(typicalCycleLengthDays: 30, typicalPeriodLengthDays: 5,
                                       declaredRegularity: .variable, phaseMode: .noPhases,
                                       noPhaseReason: .contraception)))
            #expect(status == 200)
            #expect(after?.cycleTracking == .manual)
            #expect(after?.cycle?.phaseMode == .noPhases)
            #expect(after?.cycle?.noPhaseReason == .contraception)
            #expect(after?.cycle?.typicalCycleLengthDays == 30)
            #expect(after?.cycle?.declaredRegularity == .variable)

            // Повторная правка цикла перезаписывает поля объекта целиком.
            let (_, switched) = try await self.patch(app, user, PatchProfileRequest(
                cycle: CycleProfileDTO(typicalCycleLengthDays: 28, phaseMode: .phases)))
            #expect(switched?.cycle?.phaseMode == .phases)
            #expect(switched?.cycle?.noPhaseReason == nil, "причина снята вместе с режимом")
            #expect(switched?.cycle?.typicalCycleLengthDays == 28)
        }
    }

    // MARK: - Отказы

    @Test("набор дней с повтором или вне 1..7 отклоняется (§7.2)")
    func weekdaysAreValidated() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.weekdays") { app in
            for bad in [[2, 2, 4], [0, 3], [1, 8], []] {
                let (status, _) = try await self.patch(app, user,
                                                       PatchProfileRequest(trainingWeekdays: .some(bad)))
                #expect(status == 422, "набор \(bad) обязан отклоняться")
            }
            // Дубликаты `weekGrid` схлопывает МОЛЧА, и {2,2,4} дал бы два дня
            // вместо трёх — поэтому отказ, а не канонизация.
            let (ok, profile) = try await self.patch(app, user,
                                                     PatchProfileRequest(trainingWeekdays: .some([2, 4, 6])))
            #expect(ok == 200)
            #expect(profile?.daysPerWeek == 3)
        }
    }

    @Test("days_per_week — контрольная сумма: расхождение с набором отклоняется")
    func daysPerWeekIsAChecksum() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.checksum") { app in
            let (bad, _) = try await self.patch(app, user, PatchProfileRequest(
                daysPerWeek: 4, trainingWeekdays: .some([1, 3, 5])))
            #expect(bad == 422, "четыре против трёх — расхождение")

            let (good, profile) = try await self.patch(app, user, PatchProfileRequest(
                daysPerWeek: 3, trainingWeekdays: .some([1, 3, 5])))
            #expect(good == 200)
            #expect(profile?.daysPerWeek == 3)

            let (orphan, _) = try await self.patch(app, user, PatchProfileRequest(daysPerWeek: 3))
            #expect(orphan == 422, "число без набора: пара пишется целиком (§3.1)")
        }
    }

    @Test("неполный профиль не даёт сгенерировать неделю (§20.6)")
    func incompleteProfileBlocksGeneration() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.incomplete") { app in
            _ = try await self.patch(app, user, PatchProfileRequest(goal: .some(.hypertrophy)))

            let today = Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
            let body = GenerateWeekPlanRequest(
                weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)),
                day: DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow"))
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .conflict)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                        from: Data(buffer: response.body))
                #expect(envelope.error.code == .profileIncomplete)
                let missing = envelope.error.details?["missing"]
                #expect(missing == .string("experience_level,training_weekdays"))
            }
        }
    }

    @Test("профиль анонимного пользователя доступен: онбординг идёт до линковки (§4.1)")
    func anonymousMayWriteProfile() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.profile.anon") { app in
            let (status, _) = try await self.patch(app, user,
                                                   PatchProfileRequest(goal: .some(.endurance)))
            #expect(status == 200, "гейт линковки стоит на POST /v1/workouts, а не здесь")
        }
    }

    @Test("без токена профиль не отдаётся и не пишется")
    func tokenIsRequired() async throws {
        try await Live.withServer("live.profile.notoken") { app in
            try await app.testing().test(.GET, "/v1/profile") { response in
                #expect(response.status == .unauthorized)
            }
            try await app.testing().test(.PATCH, "/v1/profile") { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
