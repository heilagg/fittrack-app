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

    // MARK: - Итог дня

    private var allDayCauses: [DayOutcome.Cause] {
        // Список ручной по той же причине, что и у ReasonCode: DayOutcome.Cause
        // не CaseIterable, и новый случай обязан быть добавлен сюда руками,
        // иначе он уедет наружу без формулировки.
        [.restOverride, .skipped, .replaced, .started, .done, .past,
         .gridStretch, .markupMissing, .pregnancy]
    }

    /// §20.3: словарь причин дня закрыт и состоит из девяти значений.
    func test_dayCauseDictionaryIsTheNineOfTheSpec() {
        XCTAssertEqual(Set(allDayCauses.map(ReasonDTO.code(for:))),
                       ["rest_override", "skipped", "replaced", "started", "done", "past",
                        "grid_stretch", "markup_missing", "pregnancy"])
    }

    /// §20.3: словарь веток показа закрыт и состоит из пяти значений.
    func test_dayKindDictionaryIsTheFiveOfTheSpec() {
        let kinds: [DayOutcome.Kind] = [.session, .stretching, .notBuilt, .vectorMissing, .generatorDisabled]
        let encoded = kinds.map { kind in
            DayOutcomeDTO(DayOutcome(dayID: "d", kind: kind, cause: nil,
                                     losesPlannedVolume: false, session: nil)).kind
        }
        XCTAssertEqual(Set(encoded),
                       ["session", "stretching", "not_built", "vector_missing", "generator_disabled"])
    }

    /// Причина дня едет полным конвертом, как всякая доменная причина, и несёт
    /// готовую формулировку: §20.3 не оставляет клиенту собирать её самому.
    func test_dayCauseTravelsAsCodeParamsMessage() throws {
        for cause in allDayCauses {
            let dto = DayCauseDTO(cause)
            XCTAssertFalse(dto.message.isEmpty, "нет формулировки для \(ReasonDTO.code(for: cause))")
            XCTAssertFalse(dto.message.contains("!"), "восклицательный знак в «\(dto.message)» (§13.5)")

            let json = try JSONSerialization.jsonObject(with: try encoder.encode(dto)) as? [String: Any]
            XCTAssertEqual(Set(json?.keys ?? [:].keys), ["code", "params", "message"],
                           "конверт причины дня — те же три поля")
            XCTAssertEqual((json?["params"] as? [String: Any])?.isEmpty, true,
                           "params пуст, но присутствует: форма одна на все причины")

            let back = try decoder.decode(DayCauseDTO.self, from: try encoder.encode(dto))
            XCTAssertEqual(back, dto, "причина дня не пережила round-trip: \(cause)")
        }
    }

    /// Формулировка одна на два места: строка потери объёма и карточка дня не
    /// вправе называть один факт по-разному.
    func test_dayCauseMessageIsTheSamePhraseAsInVolumeLoss() {
        let lost = ReasonStrings.message(for: .plannedVolumeLoss(muscle: .gluteMax, sets: 8, cause: .skipped))
        let standalone = ReasonStrings.message(for: DayOutcome.Cause.skipped)
        XCTAssertTrue(lost.lowercased().contains(standalone.lowercased()),
                      "«\(standalone)» обязана быть той же формулировкой, что внутри «\(lost)»")
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

    // MARK: - Тела ответов

    private var prescribed: PrescribedExercise {
        PrescribedExercise(slug: "hip_thrust_barbell", orderIndex: 0, targetSets: 3,
                           targetRepMin: 8, targetRepMax: 12, targetRIR: 2,
                           prescribedKg: 40, weightReadiness: 1.0)
    }

    private func workout(tree: DecisionTreeDTO?) -> WorkoutDTO {
        WorkoutDTO(
            id: "w1", plannedDayID: "d1", sessionKind: .lower, accentMuscle: .gluteMax,
            startedAt: "2026-09-24T19:00:00+03:00", readiness: 1.1, cyclePhase: .lateLuteal,
            cycleConfidence: 0.62, isCalibration: false,
            exercises: [WorkoutExerciseDTO(id: "we1", prescribed: prescribed, isCalibration: false,
                                           decisionTree: tree,
                                           sets: [SetDTO(id: "s1", setIndex: 1, prescribedKg: 40,
                                                         prescribedReps: 12, actualKg: 40, actualReps: 11,
                                                         feedback: .ok, painJoints: [.hip, .lowerBack],
                                                         completedAt: "2026-09-24T19:04:00+03:00")])])
    }

    private var tree: DecisionTreeDTO {
        DecisionTree.build(weightKg: 40, remainingSets: 2, range: 8...12, isCalibration: false,
                           ladder: .arithmetic(step: 2.5))
    }

    func test_workoutSurvivesRoundTrip() throws {
        let dto = workout(tree: tree)
        XCTAssertEqual(try decoder.decode(WorkoutDTO.self, from: try encoder.encode(dto)), dto)
    }

    /// Ключи на проводе — snake_case, как у всей границы.
    func test_workoutKeysAreSnakeCase() throws {
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(workout(tree: tree))) as? [String: Any]
        XCTAssertNotNil(json?["planned_day_id"])
        XCTAssertNotNil(json?["session_kind"])
        XCTAssertNotNil(json?["is_calibration"])

        let exercise = (json?["exercises"] as? [[String: Any]])?.first
        XCTAssertNotNil(exercise?["decision_tree"], "дерево — поле упражнения (§20.3)")
        XCTAssertNotNil(exercise?["weight_readiness"])
        XCTAssertEqual(exercise?["is_calibration"] as? Bool, false, "калибровка по упражнению, не по тренировке")

        let set = (exercise?["sets"] as? [[String: Any]])?.first
        XCTAssertEqual(set?["pain_joints"] as? [String], ["hip", "lower_back"])
        XCTAssertEqual(set?["prescribed_reps"] as? Int, 12)
    }

    /// §20.3: у не начатого дня дерева не существует, и поле отсутствует.
    func test_decisionTreeIsAbsentWhenWorkoutHasNotStarted() throws {
        let json = try JSONSerialization.jsonObject(
            with: try encoder.encode(workout(tree: nil))) as? [String: Any]
        let exercise = (json?["exercises"] as? [[String: Any]])?.first
        XCTAssertNil(exercise?["decision_tree"])
    }

    /// §20.3: ответ на лог подхода несёт ТОЛЬКО дерево — второго источника
    /// того же числа у клиента быть не должно.
    func test_logSetResponseCarriesOnlyTheTree() throws {
        let json = try JSONSerialization.jsonObject(
            with: try encoder.encode(LogSetResponseDTO(decisionTree: tree))) as? [String: Any]
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["decision_tree"])
    }

    /// Один тип на четыре недельных пути, `notice` необязателен.
    func test_weekPlanResponseCarriesOptionalNotice() throws {
        let plan = WeekPlanDTO(WeekPlan(days: [:], statusLines: []))
        let silent = WeekPlanResponseDTO(plan: plan)
        XCTAssertNil(try decoder.decode(WeekPlanResponseDTO.self, from: try encoder.encode(silent)).notice)

        let loud = WeekPlanResponseDTO(plan: plan, notice: ReasonDTO(.planRebuilt(cause: .equipmentChanged)))
        let back = try decoder.decode(WeekPlanResponseDTO.self, from: try encoder.encode(loud))
        XCTAssertEqual(back, loud)
    }

    func test_todayCardSurvivesRoundTrip() throws {
        let card = TodayCardDTO(
            date: "2026-09-24", readiness: 1.1,
            cycle: CycleStateDTO(CycleState(phaseMode: .phases, noPhaseReason: nil, hasAnchor: true,
                                            phase: .lateLuteal, cycleConfidence: 0.62,
                                            periodization: nil, effectivePhaseAdjustment: nil)),
            day: DayOutcomeDTO(DayOutcome(dayID: "d1", kind: .notBuilt, cause: .skipped,
                                          losesPlannedVolume: true, session: nil)),
            reasons: [ReasonDTO(.phasePeriodization(phase: .lateLuteal, cycleConfidence: 0.62))])
        XCTAssertEqual(try decoder.decode(TodayCardDTO.self, from: try encoder.encode(card)), card)
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
        XCTAssertEqual(APIErrorCode.unlinkedAccount.httpStatus, 403)
        XCTAssertEqual(APIErrorCode.allCases.count, 15, "словарь §20.3 закрыт")
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
