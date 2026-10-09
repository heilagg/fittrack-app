//  Тела ЗАПРОСОВ `/v1` против таблицы §20.3.
//
//  Файл заведён потому, что его не было, и отсутствие стоило расхождения.
//  `ContractTests` проверяет тела ответов и только их; у `LogSetRequest` во всём
//  репозитории не было ни одного конструктора, кроме собственного объявления, и
//  лишнее поле `prescribed_reps` прожило в нём от коммита `5221ed6` до этого,
//  противореча §20.3 всё это время. Расхождение, которое ничем не проверяется,
//  живёт ровно столько, сколько его никто не читает.
//
//  Проверяется здесь одно: имена и наличие полей на проводе. Смысл полей —
//  дело §20.3 и тестов сервера; сюда не попадает ничего, что требовало бы
//  живой базы или роута.

import XCTest
@testable import FitAPI
import FitCore

final class RequestContractTests: XCTestCase {

    private let day = DayContext(date: "2026-09-29", tz: "Europe/Moscow")

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - POST /v1/workouts/{id}/exercises/{we_id}/sets

    /// §20.3: «`prescribed_kg` в теле подхода приходит от клиента,
    /// `prescribed_reps` — нет». Отрицательное утверждение, и проверять его
    /// нужно именно так: положительных тут недостаточно, лишнее поле все они
    /// прошли бы зелёными.
    func test_logSetCarriesNoPrescribedReps() throws {
        let body = try json(LogSetRequest(id: "s1", setIndex: 1, prescribedKg: 40,
                                          actualKg: 40, actualReps: 11, feedback: .ok,
                                          completedAt: "2026-09-29T19:04:00+03:00", day: day))
        XCTAssertNil(body["prescribed_reps"],
                     "верх диапазона пишет сервер из target_rep_max (§20.3, §20.6)")
        XCTAssertNotNil(body["prescribed_kg"], "вес назначило дерево во фронтенде — он едет")
    }

    /// Таблица §20.3 целиком, включая то, что `id` обязателен: без него
    /// ретрай неотличим от нового подхода (§20.6, 20e).
    func test_logSetBodyMatchesTheTable() throws {
        let body = try json(LogSetRequest(id: "s1", setIndex: 1, prescribedKg: 40,
                                          actualKg: 40, actualReps: 11, feedback: .ok,
                                          painFlag: false, restSeconds: 90,
                                          completedAt: "2026-09-29T19:04:00+03:00",
                                          skipped: false, day: day))
        XCTAssertEqual(Set(body.keys),
                       ["id", "set_index", "prescribed_kg", "actual_kg", "actual_reps",
                        "feedback", "pain_flag", "rest_seconds", "completed_at",
                        "skipped", "date", "tz"])
    }

    func test_logSetOmitsAbsentOptionalsRatherThanSendingNull() throws {
        let body = try json(LogSetRequest(id: "s1", setIndex: 1,
                                          completedAt: "2026-09-29T19:04:00+03:00", day: day))
        for key in ["prescribed_kg", "actual_kg", "actual_reps", "feedback", "rest_seconds"] {
            XCTAssertNil(body[key], "\(key): отсутствующее поле не едет как null")
        }
        // Непустые по умолчанию — едут всегда: у клиента нет способа «не знать»,
        // пропущен подход или нет.
        XCTAssertEqual(body["pain_flag"] as? Bool, false)
        XCTAssertEqual(body["skipped"] as? Bool, false)
    }

    /// §20.3 даёт `completed_at` без `?`: тело без него — не подход, а ошибка
    /// схемы. Раньше поле было необязательным, и сервер писал подход без
    /// момента, который `/finish` не смог бы применить к утомлению §8.1.
    func test_logSetWithoutCompletedAtDoesNotDecode() throws {
        for raw in [#"{"id":"s1","set_index":1,"date":"2026-09-29","tz":"Europe/Moscow"}"#,
                    #"{"id":"s1","set_index":1,"completed_at":null,"date":"2026-09-29","tz":"Europe/Moscow"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(LogSetRequest.self, from: Data(raw.utf8)),
                                 "без completed_at тело разобралось: \(raw)")
        }
    }

    func test_logSetSurvivesRoundTrip() throws {
        let sent = LogSetRequest(id: "s1", setIndex: 2, prescribedKg: 42.5, actualKg: 42.5,
                                 actualReps: 9, feedback: .hard, painFlag: true,
                                 restSeconds: 120, completedAt: "2026-09-29T19:08:00+03:00",
                                 day: day)
        let back = try JSONDecoder().decode(LogSetRequest.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(back, sent)
    }

    // MARK: - Остальные тела §20.3

    func test_generateWeekPlanBody() throws {
        let body = try json(GenerateWeekPlanRequest(weekStart: "2026-09-28", day: day))
        XCTAssertEqual(Set(body.keys), ["week_start", "date", "tz"])
    }

    func test_startWorkoutBody() throws {
        let full = try json(StartWorkoutRequest(plannedDayID: "d1", equipmentProfileID: "e1", day: day))
        XCTAssertEqual(Set(full.keys), ["planned_day_id", "equipment_profile_id", "date", "tz"])

        // Профиль необязателен: без него берётся is_default (§20.3).
        let bare = try json(StartWorkoutRequest(plannedDayID: "d1", day: day))
        XCTAssertNil(bare["equipment_profile_id"])
    }

    func test_rebuildBodyCarriesOnlyTheTwoClientCauses() throws {
        let body = try json(RebuildWeekPlanRequest(cause: .equipmentChanged, day: day))
        XCTAssertEqual(Set(body.keys), ["cause", "date", "tz"])
        XCTAssertEqual(Set(ClientRebuildCause.allCases.map(\.rawValue)),
                       ["equipment_changed", "cycle_event_added"],
                       "остальные триггеры §7.1 сервер наблюдает сам (§20.3)")
    }

    func test_substituteBody() throws {
        let body = try json(SubstituteExerciseRequest(toSlug: "goblet_squat", reason: .pain, day: day))
        XCTAssertEqual(Set(body.keys), ["to_slug", "reason", "date", "tz"])
        XCTAssertEqual(body["reason"] as? String, "pain")
    }

    func test_finishBody() throws {
        XCTAssertEqual(Set(try json(FinishWorkoutRequest(day: day)).keys), ["date", "tz"])
    }

    // MARK: - Правка дня: отсутствие ключа и явный null — разное

    /// §20.3: отсутствие ключа означает «не трогать», явный null — «снять
    /// акцент». Снятие акцента — плановое решение §7.2, и отличать его от «поле
    /// не прислали» обязательно.
    func test_patchDayDistinguishesAbsentFromNullAccent() throws {
        let untouched = try json(PatchPlannedDayRequest(sessionKind: .lower, day: day))
        XCTAssertFalse(untouched.keys.contains("accent_muscle"))

        let cleared = try json(PatchPlannedDayRequest(accentMuscle: .some(nil), day: day))
        XCTAssertTrue(cleared.keys.contains("accent_muscle"))
        XCTAssertTrue(cleared["accent_muscle"] is NSNull)

        let set = try json(PatchPlannedDayRequest(accentMuscle: .some(.gluteMax), day: day))
        XCTAssertEqual(set["accent_muscle"] as? String, "glute_max")
    }

    func test_patchDayRoundTripsAllThreeAccentStates() throws {
        for value in [PatchPlannedDayRequest(sessionKind: .upper, day: day),
                      PatchPlannedDayRequest(accentMuscle: .some(nil), day: day),
                      PatchPlannedDayRequest(accentMuscle: .some(.lats), status: .skipped, day: day)] {
            let back = try JSONDecoder().decode(PatchPlannedDayRequest.self,
                                                from: JSONEncoder().encode(value))
            XCTAssertEqual(back, value)
        }
    }

    // MARK: - purpose у /alternatives (§20.3)

    func test_alternativesPurposeIsAClosedPairOnTheWire() {
        XCTAssertEqual(Set(AlternativesPurpose.allCases.map(\.rawValue)), ["user_choice", "pain"])
    }
}
