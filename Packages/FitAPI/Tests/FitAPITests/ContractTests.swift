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
            // §20.3: причина без причины — `GET` недели увидел расхождение со
            // снимком и не знает, чем оно вызвано. Список ведётся руками, и
            // случай, забытый в нём, остаётся без формулировки и без сверки
            // round-trip'а — то есть ровно без того, ради чего файл и есть.
            .planChanged,
            .dayVectorMissing(kind: .lower, accent: .gluteMax),
            .dayVectorMissing(kind: .fullBody, accent: nil),
            .substitutionKeepsLeadingMuscle(muscle: .gluteMax),
            .substitutionRelievesJoint(joint: .knee, from: .high, to: .low),
            .substitutionRelievesJoint(joint: .lowerBack, from: .medium, to: .none),
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

    /// §20.3: проводной словарь причин дня на одно значение ШИРЕ ядерного.
    /// Десятое значение в `Planner.DayOutcome.Cause` отсутствует намеренно —
    /// `classify` принимает `PlannedDay`, а у дня отдыха его нет.
    func test_wireDayCauseDictionaryIsTheTenOfTheSpec() {
        XCTAssertEqual(Set(DayCause.allCases.map(\.rawValue)),
                       ["rest_override", "skipped", "replaced", "started", "done", "past",
                        "grid_stretch", "markup_missing", "pregnancy", "not_a_training_day"])
    }

    /// Девять проводных значений обязаны сводиться к ядерным, десятое — нет.
    /// Без этого утверждения снимок §20.6, который читается ОБРАТНО в значения
    /// FitCore, однажды получил бы причину, которой в ядре нет.
    func test_nineWireCausesMapBackToCoreAndTheTenthDoesNot() {
        for cause in DayCause.allCases where cause != .notATrainingDay {
            XCTAssertNotNil(cause.core, "\(cause.rawValue) обязан сводиться к ядерному")
        }
        XCTAssertNil(DayCause.notATrainingDay.core)
        for cause in allDayCauses {
            XCTAssertEqual(DayCause(cause).core, cause, "перевод туда-обратно не теряет случай")
        }
    }

    /// Формулировку отдаёт сервер для ВСЕХ причин (§20.3), включая десятую,
    /// у которой ядерного источника строки нет.
    func test_everyWireDayCauseCarriesAFormulation() {
        for cause in DayCause.allCases {
            XCTAssertFalse(ReasonStrings.message(for: cause).isEmpty, cause.rawValue)
        }
    }

    /// День без строки `planned_days` (§20.3): `day_id` не едет вовсе — ни
    /// значением, ни `null`. Синтетический идентификатор был бы ключом, по
    /// которому клиент однажды сходит в `PATCH .../days/{day_id}`.
    func test_dayWithoutARowCarriesNoIdentifier() throws {
        for cause in [DayCause?.none, .some(.notATrainingDay)] {
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: try encoder.encode(DayOutcomeDTO.notBuilt(cause: cause))) as? [String: Any])
            XCTAssertNil(json["day_id"], "ключа нет")
            XCTAssertEqual(json["kind"] as? String, "not_built")
            XCTAssertEqual(json["loses_planned_volume"] as? Bool, false)
            XCTAssertNil(json["session"])
        }
    }

    /// Два пустых дня §20.3 различаются ровно причиной, и это то, по чему
    /// клиент выбирает между «сегодня отдых» и «неделя не сгенерирована».
    func test_theTwoEmptyDaysDifferOnlyByCause() throws {
        let noWeek = DayOutcomeDTO.notBuilt(cause: nil)
        let restDay = DayOutcomeDTO.notBuilt(cause: .notATrainingDay)
        XCTAssertNil(noWeek.cause)
        XCTAssertEqual(restDay.cause?.cause, .notATrainingDay)
        XCTAssertEqual(noWeek.kind, restDay.kind)
        XCTAssertEqual(noWeek.dayID, restDay.dayID)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try encoder.encode(restDay)) as? [String: Any])
        let cause = try XCTUnwrap(json["cause"] as? [String: Any])
        XCTAssertEqual(cause["code"] as? String, "not_a_training_day")
        XCTAssertFalse((cause["message"] as? String ?? "").isEmpty)

        for day in [noWeek, restDay] {
            XCTAssertEqual(try decoder.decode(DayOutcomeDTO.self, from: try encoder.encode(day)), day)
        }
    }

    /// §20.3: словарь веток показа закрыт и состоит из пяти значений.
    func test_dayKindDictionaryIsTheFiveOfTheSpec() {
        let kinds: [DayOutcome.Kind] = [.session, .stretching, .notBuilt, .vectorMissing, .generatorDisabled]
        let encoded = kinds.map { kind in
            DayOutcomeDTO(DayOutcome(dayID: "d", kind: kind, cause: nil,
                                     losesPlannedVolume: false, session: nil), dayKind: .upper).kind
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
                                           sets: [SetDTO(id: "s1", exerciseSlug: "hip_thrust_barbell",
                                                         setIndex: 1, prescribedKg: 40,
                                                         prescribedReps: 12, actualKg: 40, actualReps: 11,
                                                         feedback: .ok, painJoints: [.hip, .lowerBack],
                                                         completedAt: "2026-09-24T19:04:00+03:00")])])
    }

    private var tree: DecisionTreeDTO {
        DecisionTree.build(weightKg: 40, remainingSets: 2, range: 8...12, isCalibration: false,
                           previousWasFailed: false, calibrationIncreasesUsed: 0,
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

    /// §20.3: подход несёт свой слаг — после замены упражнения в строке лежат и
    /// подходы прежнего, и клиент обязан их различать. Слаг обязателен: тело
    /// без него не разбирается, а не получает слаг упражнения-владельца.
    func test_setCarriesItsExerciseSlug() throws {
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(workout(tree: nil))) as? [String: Any]
        let set = ((json?["exercises"] as? [[String: Any]])?.first?["sets"] as? [[String: Any]])?.first
        XCTAssertEqual(set?["exercise_slug"] as? String, "hip_thrust_barbell")

        let bare = #"{"id":"s1","set_index":1,"prescribed_reps":12,"pain_flag":false,"pain_joints":[],"skipped":false}"#
        XCTAssertThrowsError(try decoder.decode(SetDTO.self, from: Data(bare.utf8)),
                             "подход без exercise_slug разобрался")
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

    /// §20.3: `/finish` отдаёт `{workout, week}`; без недели ключа `week` нет —
    /// общее правило FitAPI опускать отсутствующее, а не слать `null`.
    func test_finishResponseCarriesWorkoutAndOptionalWeek() throws {
        let week = WeekPlanResponseDTO(plan: WeekPlanDTO(WeekPlan(days: [:], statusLines: []), week: []))
        let full = try JSONSerialization.jsonObject(with: try encoder.encode(
            FinishWorkoutResponseDTO(workout: workout(tree: nil), week: week))) as? [String: Any]
        XCTAssertEqual(Set(full?.keys ?? [:].keys), ["workout", "week"])

        let bare = try JSONSerialization.jsonObject(with: try encoder.encode(
            FinishWorkoutResponseDTO(workout: workout(tree: nil), week: nil))) as? [String: Any]
        XCTAssertEqual(Set(bare?.keys ?? [:].keys), ["workout"])

        let dto = FinishWorkoutResponseDTO(workout: workout(tree: tree), week: week)
        XCTAssertEqual(try decoder.decode(FinishWorkoutResponseDTO.self, from: try encoder.encode(dto)), dto)
    }

    /// Один тип на четыре недельных пути, `notice` необязателен.
    func test_weekPlanResponseCarriesOptionalNotice() throws {
        let plan = WeekPlanDTO(WeekPlan(days: [:], statusLines: []), week: [])
        let silent = WeekPlanResponseDTO(plan: plan)
        XCTAssertNil(try decoder.decode(WeekPlanResponseDTO.self, from: try encoder.encode(silent)).notice)

        let loud = WeekPlanResponseDTO(plan: plan, notice: ReasonDTO(.planRebuilt(cause: .equipmentChanged)))
        let back = try decoder.decode(WeekPlanResponseDTO.self, from: try encoder.encode(loud))
        XCTAssertEqual(back, loud)
    }

    // MARK: - Дни недели и названия типов (§7.2, §20.3)

    /// §7.2: одно название на значение, `lower` — «Низ тела» в любой неделе.
    func test_sessionKindNamesAreTheTableOfSpec72() {
        let names = Dictionary(uniqueKeysWithValues: SessionKind.allCases.map {
            ($0.rawValue, ReasonStrings.sessionKindName($0))
        })
        XCTAssertEqual(names, [
            "full_body": "Всё тело", "upper": "Верх тела", "lower": "Низ тела",
            "push": "Жимовая", "pull": "Тяговая", "stretch": "Растяжка", "rest": "Отдых",
        ])
    }

    private func plannedDay(_ id: String, _ dayNumber: Int, _ kind: SessionKind) -> PlannedDay {
        PlannedDay(id: id, date: CalendarDay(dayNumber: dayNumber), kind: kind, accent: nil, vector: [:])
    }

    private func outcome(_ id: String, session: Bool = false) -> DayOutcome {
        DayOutcome(dayID: id, kind: session ? .session : .notBuilt, cause: session ? nil : .done,
                   losesPlannedVolume: false,
                   session: session ? BuiltSession(dayID: id, exercises: [], estimatedSeconds: 600,
                                                   effectiveVolume: [:], leadingMuscle: nil, scale: 1,
                                                   reasons: []) : nil)
    }

    /// §20.3: дни — по дате, а не по `day_id`; у каждого дата, тип и название.
    func test_weekDaysAreOrderedByDateAndCarryTheirType() {
        // Идентификаторы нарочно в обратном порядке к датам.
        let week = [(plannedDay("b", 3, .pull), "2026-10-14"),
                    (plannedDay("a", 5, .fullBody), "2026-10-16"),
                    (plannedDay("c", 1, .lower), "2026-10-12")]
        let plan = WeekPlan(days: ["a": outcome("a"), "b": outcome("b", session: true), "c": outcome("c")],
                            statusLines: [])
        let dto = WeekPlanDTO(plan, week: week.map { (day: $0.0, isoDate: $0.1) })
        XCTAssertEqual(dto.days.map(\.date), ["2026-10-12", "2026-10-14", "2026-10-16"])
        XCTAssertEqual(dto.days.map(\.dayID), ["c", "b", "a"])
        XCTAssertEqual(dto.days.map(\.sessionKind), ["lower", "pull", "full_body"])
        XCTAssertEqual(dto.days.map(\.sessionKindName), ["Низ тела", "Тяговая", "Всё тело"])
        XCTAssertEqual(dto.days.map(\.kind), ["not_built", "session", "not_built"])
        XCTAssertEqual(dto.days[0].cause?.cause, .done)
        // Сессия несёт тип своего дня, а не соседнего.
        XCTAssertEqual(dto.days[1].session?.sessionKind, "pull")
        XCTAssertEqual(dto.days[1].session?.sessionKindName, "Тяговая")
        XCTAssertNil(dto.days[0].session)
    }

    /// `/preview`: в ответ попадают только дни с итогом в плане (срез одного дня).
    func test_weekDaysWithoutOutcomeAreLeftOut() {
        let plan = WeekPlan(days: ["b": outcome("b")], statusLines: [])
        let dto = WeekPlanDTO(plan, week: [(day: plannedDay("a", 1, .lower), isoDate: "2026-10-12"),
                                           (day: plannedDay("b", 3, .upper), isoDate: "2026-10-14")])
        XCTAssertEqual(dto.days.map(\.dayID), ["b"])
    }

    /// Сессия `/today` несёт тип своего дня и его название.
    func test_dayOutcomeSessionCarriesItsDayType() throws {
        let day = DayOutcomeDTO(outcome("d", session: true), dayKind: .push)
        XCTAssertEqual(day.session?.sessionKind, "push")
        XCTAssertEqual(day.session?.sessionKindName, "Жимовая")
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(day)) as? [String: Any]
        let session = json?["session"] as? [String: Any]
        XCTAssertEqual(session?["session_kind"] as? String, "push")
        XCTAssertEqual(session?["session_kind_name"] as? String, "Жимовая")
        XCTAssertNil(json?["date"], "у дня карточки даты нет: она в TodayCard.date")
    }

    func test_todayCardSurvivesRoundTrip() throws {
        let card = TodayCardDTO(
            date: "2026-09-24", readiness: 1.1,
            cycle: CycleStateDTO(CycleState(phaseMode: .phases, noPhaseReason: nil, hasAnchor: true,
                                            phase: .lateLuteal, cycleConfidence: 0.62,
                                            periodization: nil, effectivePhaseAdjustment: nil)),
            day: DayOutcomeDTO(DayOutcome(dayID: "d1", kind: .notBuilt, cause: .skipped,
                                          losesPlannedVolume: true, session: nil), dayKind: .upper),
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
        XCTAssertEqual(APIErrorCode.allCases.count, 16, "словарь §20.3 закрыт")
    }

    func test_errorEnvelopeShape() throws {
        let envelope = APIErrorEnvelope(code: .dateSkew, details: ["sent": .string("2026-09-01")])
        let json = try JSONSerialization.jsonObject(with: try encoder.encode(envelope)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "date_skew")
        XCTAssertFalse((error?["message"] as? String ?? "").isEmpty)
        XCTAssertEqual((error?["details"] as? [String: Any])?["sent"] as? String, "2026-09-01")
    }
    // MARK: - Календарь цикла (§11.6, §20.3)

    func test_cycleCalendar_phaseTextsAreFourInCycleOrderWithTheNote() {
        let dto = CycleCalendarDTO(CycleCalendar(nextPeriod: nil, overdue: false, days: []),
                                   from: CalendarDay(dayNumber: 0), to: CalendarDay(dayNumber: 0),
                                   cycle: CycleStateDTO(CycleState(phaseMode: .phases, noPhaseReason: nil,
                                                                   hasAnchor: false, phase: nil, cycleConfidence: nil,
                                                                   periodization: nil, effectivePhaseAdjustment: nil)),
                                   marks: [:], iso: { "\($0.dayNumber)" })
        XCTAssertEqual(dto.phases.map(\.phase), ["menstrual", "follicular", "ovulatory", "luteal"])
        XCTAssertEqual(dto.phases.map(\.name), ["Менструация", "После месячных", "Середина цикла", "Вторая половина цикла"])
        XCTAssertTrue(dto.phases.allSatisfy { $0.note == ReasonStrings.phaseTextNote && !$0.feeling.isEmpty && !$0.why.isEmpty })
        XCTAssertEqual(Set(dto.phases.map(\.feeling)).count, 4, "у каждой фазы свой текст")
    }

    func test_cycleCalendarDay_withoutPhase_carriesNoConfidenceKey() throws {
        let day = CycleCalendarDayDTO(CycleCalendarEntry(date: CalendarDay(dayNumber: 1), period: .forecast),
                                      marks: [], iso: { _ in "2026-11-21" })
        let json = String(decoding: try JSONEncoder().encode(day), as: UTF8.self)
        XCTAssertFalse(json.contains("cycle_confidence"))
        XCTAssertFalse(json.contains("\"phase\""))
        XCTAssertTrue(json.contains("\"period\":\"forecast\""))
    }

    func test_cycleCalendar_marksGoToTheirDayOnly() {
        let mark = CycleMarkDTO(id: "x", kind: "period_start", source: "manual")
        let days = [CycleCalendarEntry(date: CalendarDay(dayNumber: 1)), CycleCalendarEntry(date: CalendarDay(dayNumber: 2))]
        let dto = CycleCalendarDTO(CycleCalendar(nextPeriod: nil, overdue: false, days: days),
                                   from: CalendarDay(dayNumber: 1), to: CalendarDay(dayNumber: 2),
                                   cycle: CycleStateDTO(CycleState(phaseMode: .noPhases, noPhaseReason: .declined,
                                                                   hasAnchor: false, phase: nil, cycleConfidence: nil,
                                                                   periodization: nil, effectivePhaseAdjustment: nil)),
                                   marks: [CalendarDay(dayNumber: 2): [mark]], iso: { "\($0.dayNumber)" })
        XCTAssertEqual(dto.days.map(\.marks), [[], [mark]])
    }
    func test_cycleCalendar_overdueAndNextPeriodPassThrough() {
        let next = NextPeriod(expected: CalendarDay(dayNumber: 10), rangeStart: CalendarDay(dayNumber: 8),
                              rangeEnd: CalendarDay(dayNumber: 12), cycleConfidence: 0.6)
        let dto = CycleCalendarDTO(CycleCalendar(nextPeriod: next, overdue: true, days: []),
                                   from: CalendarDay(dayNumber: 1), to: CalendarDay(dayNumber: 2),
                                   cycle: CycleStateDTO(CycleState(phaseMode: .phases, noPhaseReason: nil,
                                                                   hasAnchor: true, phase: nil, cycleConfidence: 0.6,
                                                                   periodization: nil, effectivePhaseAdjustment: nil)),
                                   marks: [:], iso: { "\($0.dayNumber)" })
        XCTAssertTrue(dto.overdue)
        XCTAssertEqual(dto.nextPeriod?.expected, "10")
        XCTAssertEqual(dto.nextPeriod?.rangeStart, "8")
        XCTAssertEqual(dto.nextPeriod?.rangeEnd, "12")
    }
}
