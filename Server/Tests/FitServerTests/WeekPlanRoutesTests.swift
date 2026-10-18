//  Недельный блок: то, что проверяется без живой базы (SPEC §7.1, §20.3).
//
//  Сами пути требуют Postgres с RLS и настоящих JWT — это 20a, 20j и соседние
//  из §20.15, и обвяза под них ещё нет. Здесь проверяется то, что от базы не
//  зависит: разбор недели из пути, правило «текущая или ближайшая следующая»,
//  вывод причины пересборки и форма снимка входа.

import Testing
import FitAPI
import FitCore
@testable import FitServer

@Suite("Недельный блок: правила без базы (§20.3)")
struct WeekPlanRoutesTests {

    typealias LocalTime = Mapping.LocalTime

    // MARK: - Понедельник недели

    @Test("понедельник считается арифметикой дней, а не календарём")
    func mondayOfWeek() {
        // 2026-09-28 — понедельник, 2026-10-04 — воскресенье той же недели.
        let monday = CalendarDay(year: 2026, month: 9, day: 28)
        for offset in 0...6 {
            #expect(LocalTime.mondayOfWeek(monday.adding(days: offset)) == monday)
        }
        #expect(LocalTime.mondayOfWeek(monday.adding(days: 7)) == monday.adding(days: 7))
    }

    @Test("эпоха — четверг, и это тот случай, на котором формула ломается при описке")
    func epochIsThursday() {
        // 1970-01-01 = день 0 = четверг; понедельник той недели — 1969-12-29.
        #expect(LocalTime.iso(LocalTime.mondayOfWeek(CalendarDay(dayNumber: 0))) == "1969-12-29")
    }

    @Test("недели до эпохи не ломают знак")
    func mondayBeforeEpoch() {
        let day = CalendarDay(year: 1969, month: 12, day: 31)
        #expect(LocalTime.iso(LocalTime.mondayOfWeek(day)) == "1969-12-29")
    }

    // MARK: - Причина пересборки (§20.3, решение E4)

    private func cycle(_ events: [(String, CalendarDay)], mode: PhaseMode = .phases) -> CycleInputs {
        CycleInputs(events: events.compactMap { kind, day in
            CycleEventKind(rawValue: kind).map { CycleEvent(kind: $0, occurredOn: day) }
        }, profile: CycleProfile(typicalCycleLengthDays: 28, typicalPeriodLengthDays: 5,
                                 declaredRegularity: .regular, phaseMode: mode))
    }

    @Test("equipment_changed едет один к одному")
    func equipmentCauseIsDirect() {
        let cause = WeekPlanRoutes.cause(for: .equipmentChanged, cycle: cycle([]),
                                         on: CalendarDay(year: 2026, month: 9, day: 29))
        #expect(cause == .equipmentChanged)
    }

    @Test("«до» вычисляется отбрасыванием последнего события по occurred_on")
    func beforeStateDropsTheLatestEvent() {
        let today = CalendarDay(year: 2026, month: 9, day: 29)
        // Первая отметка вообще: до неё опорной даты не было, значит и фазы.
        let inputs = cycle([("period_start", today)])
        let cause = WeekPlanRoutes.cause(for: .cycleEventAdded, cycle: inputs, on: today)
        guard case .phaseChanged = cause else {
            Issue.record("появление опорной даты — смена фазы, а не уверенности")
            return
        }
    }

    @Test("событие, не сдвинувшее опорную дату, даёт смену уверенности")
    func samePhaseYieldsConfidenceChange() {
        let today = CalendarDay(year: 2026, month: 9, day: 29)
        // `spotting` опорной датой не является (§11.3): фаза на сегодня от него
        // не меняется, а уверенность — да. Ровно тот случай, ради которого
        // §20.3 велит серверу различать две причины самому.
        let inputs = cycle([("period_start", today.adding(days: -10)),
                            ("spotting", today)])
        let cause = WeekPlanRoutes.cause(for: .cycleEventAdded, cycle: inputs, on: today)
        guard case .cycleConfidenceChanged = cause else {
            Issue.record("фаза не менялась — причина про уверенность, получено: \(cause)")
            return
        }
    }

    @Test("событий нет вовсе — уверенность, а не фаза: фазе меняться не с чего")
    func noEventsYieldConfidenceChange() {
        let cause = WeekPlanRoutes.cause(for: .cycleEventAdded, cycle: cycle([]),
                                         on: CalendarDay(year: 2026, month: 9, day: 29))
        guard case .cycleConfidenceChanged = cause else {
            Issue.record("ожидалась смена уверенности, получено: \(cause)")
            return
        }
    }

    @Test("в режиме без фаз причина всё равно называется, а не теряется")
    func noPhasesStillNamesACause() {
        let today = CalendarDay(year: 2026, month: 9, day: 29)
        let cause = WeekPlanRoutes.cause(for: .cycleEventAdded,
                                         cycle: cycle([("period_start", today)], mode: .noPhases),
                                         on: today)
        // §7.1 запрещает молчаливую пересборку: причина обязана быть даже там,
        // где фаза не участвует.
        guard case .cycleConfidenceChanged = cause else {
            Issue.record("ожидалась смена уверенности, получено: \(cause)")
            return
        }
    }

    // MARK: - Неполный профиль

    @Test("незаполненные поля профиля называются поимённо (§20.6)")
    func missingFieldsAreNamed() {
        let slice = Mapping.profile(from: Mapping.ProfileRow(
            experienceLevel: nil, goal: "hypertrophy", trainingWeekdays: nil,
            sessionMinutes: 45, trainingSplit: "auto", cycleTracking: "off", sexAtBirth: nil,
            hasDefaultEquipment: true))
        #expect(Mapping.missingProfileFields(slice) == ["experience_level", "training_weekdays"])
        #expect(!Mapping.missingProfileFields(slice).contains("goal"))
    }

    @Test("profile_incomplete — это 409 и свой код, а не validation_failed")
    func profileIncompleteIsItsOwnCode() {
        #expect(APIErrorCode.profileIncomplete.httpStatus == 409)
        #expect(APIErrorCode.profileIncomplete.rawValue == "profile_incomplete")
        #expect(!ReasonStrings.message(for: .profileIncomplete).isEmpty)
    }

    // MARK: - Снимок входа генерации

    @Test("input_digest несёт номер версии и то, что задним числом не восстановить")
    func inputDigestShape() throws {
        let weekStart = CalendarDay(year: 2026, month: 9, day: 28)
        let profile = Mapping.CompleteProfile(level: .novice, goal: .hypertrophy,
                                              trainingWeekdays: [1, 3, 5], trainingSplit: .upperLower)
        let context = WeekContext(
            weekStart: weekStart, week: [], today: weekStart,
            fatigue: [.quads: FatigueState(value: 1.5, updatedAt: Timestamp(hoursSinceEpoch: 10))],
            library: [], availability: EquipmentAvailability(),
            equipment: EquipmentProfile(dumbbellsKg: [10, 12], barbellKg: 20),
            safety: SafetyProfile(level: .novice, restrictions: [], painEvents: [],
                                  isConservative: false),
            goal: .hypertrophy, sessionMinutes: 45,
            cycle: CycleInputs(events: [CycleEvent(kind: .periodStart, occurredOn: weekStart)],
                               profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .userChoice)),
            userSeed: 42)

        let digest = Mapping.InputDigest(context: context, profile: profile)
        #expect(digest.version == Mapping.InputDigest.currentVersion)
        #expect(digest.userSeed == "42", "строкой: UInt64 не влезает в Int у всех читателей")
        #expect(digest.equipment["dumbbells_kg"] == [10, 12], "инвентарь после правки не восстановить")
        #expect(digest.fatigue["quads"] == 1.5, "утомление перепишет следующая тренировка")
        #expect(digest.phaseMode == "no_phases")
        #expect(digest.cycleEvents == ["period_start@2026-09-28"])
        #expect(digest.trainingWeekdays == [1, 3, 5])
        // Версия 2 (§20.6): схема рядом с днями — обе задают сетку недели.
        #expect(digest.version == 2)
        #expect(digest.trainingSplit == "upper_lower")
        let json = try Mapping.json(digest)
        #expect(json.contains("\"training_split\":\"upper_lower\""))
        #expect(json.contains("\"v\":2"))
    }

    @Test("снимок сериализуется воспроизводимо: его читают глазами и дифом")
    func inputDigestIsStable() throws {
        let weekStart = CalendarDay(year: 2026, month: 9, day: 28)
        let profile = Mapping.CompleteProfile(level: .novice, goal: .general, trainingWeekdays: [2, 4],
                                              trainingSplit: .auto)
        let context = WeekContext(
            weekStart: weekStart, week: [], today: weekStart, library: [],
            availability: EquipmentAvailability(), equipment: EquipmentProfile(),
            safety: SafetyProfile(level: .novice, restrictions: [], painEvents: [],
                                  isConservative: false),
            goal: .general, sessionMinutes: 30,
            cycle: CycleInputs(events: [], profile: CycleProfile()), userSeed: 7)
        let digest = Mapping.InputDigest(context: context, profile: profile)
        let encoded = try Mapping.json(digest)
        #expect(encoded == (try Mapping.json(digest)), "одинаковый вход — одинаковые байты")

        // Ключи отсортированы: снимок читают глазами и дифом, и порядок обхода
        // словаря сделал бы диф двух одинаковых входов шумным. Проверяется
        // прямо — по взаимному положению трёх известных ключей, а не разбором
        // JSON: разбор здесь был бы второй реализацией того же утверждения.
        func position(_ key: String) throws -> Int {
            let range = try #require(encoded.range(of: "\"\(key)\":"), "ключ \(key) не найден")
            return encoded.distance(from: encoded.startIndex, to: range.lowerBound)
        }
        #expect(try position("cycle_events") < (try position("equipment")))
        #expect(try position("equipment") < (try position("training_weekdays")))
        #expect(try position("training_weekdays") < (try position("v")))
    }
}

/// Прежняя форма вызова: состояние «до» берётся от того же профиля, закрытые
/// циклы не применяются. Проверки применения — `Test17ClosedCyclesApplied`.
extension WeekPlanRoutes {
    static func cause(for client: ClientRebuildCause, cycle: CycleInputs,
                      on today: CalendarDay) -> RebuildCause {
        cause(for: client, cycle: cycle, stored: cycle.profile, applies: false, on: today)
    }
}
