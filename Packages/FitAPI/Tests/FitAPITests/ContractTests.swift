import XCTest
import Foundation
@testable import FitAPI
@testable import FitCore

/// Защита формы границы `/v1` (SPEC §20.3, §20.8).
final class ContractTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Все случаи `ReasonCode`, включая вложенные причины пересборки. Список
    /// ручной намеренно: `ReasonCode` не `CaseIterable` (у случаев есть
    /// ассоциированные значения), и новый случай обязан быть добавлен сюда
    /// руками — иначе он уедет наружу непроверенным.
    private var allReasons: [ReasonCode] {
        var reasons: [ReasonCode] = [
            .phasePeriodization(phase: .lateLuteal, cycleConfidence: 0.62),
            .phasePeriodization(phase: .menstrual, cycleConfidence: 0.10),
            .ovulatoryImpactCaution(cycleConfidence: 0.55),
            .ovulatoryImpactCaution(cycleConfidence: 0.12),
            .patternMinimumRelaxedUnavailable(available: 2),
            .patternMinimumRelaxedByTime(fitted: 2),
            .patternMinimumRelaxedByLimit(fitted: 2, limit: .exerciseCount),
            .patternMinimumRelaxedByLimit(fitted: 1, limit: .family),
            .plannedVolumeLoss(muscle: .gluteMax, sets: 8, cause: .skipped),
            .plannedVolumeLoss(muscle: .quads, sets: 1, cause: .restOverride),
            .weekShortfallByTime(muscle: .lats, sets: 3),
            .workoutGenerationDisabled,
            .noFeasibleExercises,
            .dayVectorMissing(kind: .lower, accent: .gluteMax),
            .dayVectorMissing(kind: .fullBody, accent: nil),
            .substitutionKeepsLeadingMuscle(muscle: .gluteMax),
            .substitutionRelievesJoint(joint: .knee, from: .high, to: .low),
            .substitutionRelievesJoint(joint: .lowerBack, from: .medium, to: nil),
        ]
        for cause in allRebuildCauses { reasons.append(.planRebuilt(cause: cause)) }
        return reasons
    }

    private var allRebuildCauses: [RebuildCause] {
        [
            .phaseChanged(phase: .menstrual, cycleConfidence: 0.7),
            .phaseChanged(phase: nil, cycleConfidence: nil),
            .phaseChanged(phase: .lateLuteal, cycleConfidence: 0.2),
            .cycleConfidenceChanged(cycleConfidence: 0.45),
            .cycleConfidenceChanged(cycleConfidence: nil),
            .workoutSkipped, .workoutCompleted, .override, .dayEdited, .equipmentChanged,
        ]
    }

    // MARK: - Round-trip

    /// SPEC §20.8: границу такого рода «нельзя поменять никогда». Тест ловит
    /// первое же расхождение кодирования с декодированием — в том числе то,
    /// которое возникло бы от переименования случая в FitCore, если бы форма
    /// зависела от имён.
    func test_everyReasonSurvivesRoundTrip() throws {
        for reason in allReasons {
            let dto = ReasonDTO(reason)
            let data = try encoder.encode(dto)
            let back = try decoder.decode(ReasonDTO.self, from: data)
            XCTAssertEqual(back.reason, reason, "причина не пережила round-trip: \(reason)")
            XCTAssertEqual(back.message, dto.message)
        }
    }

    func test_everyRebuildCauseSurvivesRoundTrip() throws {
        for cause in allRebuildCauses {
            let dto = RebuildCauseDTO(cause)
            let back = try decoder.decode(RebuildCauseDTO.self, from: try encoder.encode(dto))
            XCTAssertEqual(back.cause, cause, "причина пересборки не пережила round-trip: \(cause)")
        }
    }

    /// Коды обязаны быть различны: одинаковый `code` у двух случаев сделал бы
    /// декодирование неоднозначным, а фронтенд — слепым к различию.
    func test_reasonCodesAreDistinct() {
        let codes = allReasons.map(ReasonDTO.code(for:))
        XCTAssertEqual(Set(codes).count, Set(allReasons.map { describe($0) }).count)
    }

    private func describe(_ reason: ReasonCode) -> String { ReasonDTO.code(for: reason) }

    // MARK: - Форма на проводе

    func test_wireShapeIsCodeParamsMessage() throws {
        let dto = ReasonDTO(.phasePeriodization(phase: .lateLuteal, cycleConfidence: 0.62))
        let json = try JSONSerialization.jsonObject(
            with: try encoder.encode(dto)) as? [String: Any]

        XCTAssertEqual(json?["code"] as? String, "phase_periodization")
        let params = json?["params"] as? [String: Any]
        XCTAssertEqual(params?["phase"] as? String, "late_luteal")
        XCTAssertEqual(params?["cycle_confidence"] as? Double ?? -1, 0.62, accuracy: 0.0001)
        XCTAssertNotNil(json?["message"] as? String)
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["code", "params", "message"],
                       "конверт причины — ровно три поля (§20.3)")
    }

    /// SPEC §14.6: `cycle_confidence` обязан ехать у ВСЯКОЙ причины фазового
    /// происхождения, включая вложенные в `plan_rebuilt`, — не только у тех,
    /// что лежат верхним уровнем.
    func test_cycleConfidenceTravelsWithNestedPhaseCauses() throws {
        let dto = ReasonDTO(.planRebuilt(cause: .phaseChanged(phase: .menstrual, cycleConfidence: 0.7)))
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(dto)) as? [String: Any]
        let cause = (json?["params"] as? [String: Any])?["cause"] as? [String: Any]

        XCTAssertEqual(cause?["code"] as? String, "phase_changed")
        let params = cause?["params"] as? [String: Any]
        XCTAssertEqual(params?["cycle_confidence"] as? Double ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertEqual(params?["phase"] as? String, "menstrual")
    }

    // MARK: - Каталог формулировок

    func test_everyReasonHasNonEmptyMessage() {
        for reason in allReasons {
            XCTAssertFalse(ReasonStrings.message(for: reason).isEmpty,
                           "нет формулировки для \(ReasonDTO.code(for: reason))")
        }
        for code in APIErrorCode.allCases {
            XCTAssertFalse(ReasonStrings.message(for: code).isEmpty, "нет формулировки для \(code)")
        }
    }

    /// SPEC §13.5: без восклицательных знаков и без морализаторства.
    func test_messagesFollowToneRules() {
        for reason in allReasons {
            let message = ReasonStrings.message(for: reason)
            XCTAssertFalse(message.contains("!"), "восклицательный знак в «\(message)» (§13.5)")
        }
    }

    /// SPEC §11.3, §14.6: ниже порога 0.3 интерфейс не вправе назвать фазу.
    /// Поскольку строку теперь отдаёт сервер, правило соблюдается здесь.
    func test_lowConfidenceNeverNamesThePhase() {
        let named = ReasonStrings.message(for: .phasePeriodization(phase: .lateLuteal, cycleConfidence: 0.62))
        XCTAssertTrue(named.contains("лютеиновой"), "при достаточной уверенности фаза называется")

        for confidence in [0.0, 0.1, 0.29] {
            for phase in Phase.allCases {
                let message = ReasonStrings.message(for: .phasePeriodization(phase: phase, cycleConfidence: confidence))
                XCTAssertFalse(message.contains(ReasonStrings.prepositional(phase)),
                               "фаза названа при уверенности \(confidence): «\(message)»")
            }
        }

        let vague = ReasonStrings.message(for: .planRebuilt(
            cause: .phaseChanged(phase: .menstrual, cycleConfidence: 0.2)))
        XCTAssertFalse(vague.contains("менструальная"), "вложенная причина обязана молчать так же")
    }

    /// Та же защита на уровне DTO: `phase` в ответе отсутствует, но
    /// `cycle_confidence` остаётся — §14.6 требует машиночитаемой
    /// неопределённости независимо от того, названа фаза или нет.
    func test_cycleStateHidesPhaseBelowThresholdButKeepsConfidence() {
        let low = CycleStateDTO(CycleState(
            phaseMode: .phases, noPhaseReason: nil, hasAnchor: true, phase: .lateLuteal,
            cycleConfidence: 0.2, periodization: nil, effectivePhaseAdjustment: nil))
        XCTAssertNil(low.phase)
        XCTAssertEqual(low.cycleConfidence ?? -1, 0.2, accuracy: 0.0001)

        let high = CycleStateDTO(CycleState(
            phaseMode: .phases, noPhaseReason: nil, hasAnchor: true, phase: .lateLuteal,
            cycleConfidence: 0.62, periodization: nil, effectivePhaseAdjustment: nil))
        XCTAssertEqual(high.phase, "late_luteal")
    }

    // MARK: - Плюрализация

    func test_setsPluralisation() {
        XCTAssertEqual(ReasonStrings.sets(1), "1 подход")
        XCTAssertEqual(ReasonStrings.sets(2), "2 подхода")
        XCTAssertEqual(ReasonStrings.sets(5), "5 подходов")
        XCTAssertEqual(ReasonStrings.sets(11), "11 подходов")
        XCTAssertEqual(ReasonStrings.sets(21), "21 подход")
        XCTAssertEqual(ReasonStrings.sets(112), "112 подходов")
    }

    // MARK: - Запросы

    /// Снятие акцента — плановое решение (§7.2), и отличать «прислали null» от
    /// «поля нет» обязательно: первое снимает акцент, второе его не трогает.
    func test_patchDayDistinguishesAbsentAccentFromExplicitNull() throws {
        let absent = try decoder.decode(PatchPlannedDayRequest.self, from: Data(
            #"{"date":"2026-09-24","tz":"Europe/Moscow"}"#.utf8))
        // Сравнение с `.none` явно, а не через XCTAssertNil: у двойного
        // опционала тот проверял бы внешний слой через коэрцию в Any?.
        XCTAssertTrue(absent.accentMuscle == nil, "поля нет — акцент не трогаем")

        let cleared = try decoder.decode(PatchPlannedDayRequest.self, from: Data(
            #"{"accent_muscle":null,"date":"2026-09-24","tz":"Europe/Moscow"}"#.utf8))
        XCTAssertEqual(cleared.accentMuscle, .some(nil), "явный null — акцент снимается")

        let set = try decoder.decode(PatchPlannedDayRequest.self, from: Data(
            #"{"accent_muscle":"glute_max","date":"2026-09-24","tz":"Europe/Moscow"}"#.utf8))
        XCTAssertEqual(set.accentMuscle, .some(.gluteMax))
    }

    /// §20.3: клиент вправе назвать только те две причины, которые сервер не
    /// наблюдает сам.
    func test_clientRebuildCausesAreOnlyTheTwoServerCannotObserve() {
        XCTAssertEqual(Set(ClientRebuildCause.allCases.map(\.rawValue)),
                       ["equipment_changed", "cycle_event_added"])
    }

    /// Пара (код, статус) — часть контракта §20.3, а не решение обработчика.
    func test_errorCodesCarryTheirHTTPStatus() {
        XCTAssertEqual(APIErrorCode.unauthorized.httpStatus, 401)
        XCTAssertEqual(APIErrorCode.jwksUnavailable.httpStatus, 503)
        XCTAssertEqual(APIErrorCode.dateSkew.httpStatus, 422)
        XCTAssertEqual(APIErrorCode.setImmutable.httpStatus, 409)
        XCTAssertEqual(APIErrorCode.allCases.count, 14, "словарь §20.3 закрыт")
    }

    func test_errorEnvelopeShape() throws {
        let envelope = APIErrorEnvelope(code: .dateSkew, details: ["sent": .string("2026-09-01")])
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(envelope)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "date_skew")
        XCTAssertFalse((error?["message"] as? String ?? "").isEmpty)
        XCTAssertEqual((error?["details"] as? [String: Any])?["sent"] as? String, "2026-09-01")
    }
}
