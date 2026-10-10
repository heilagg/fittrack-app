//  Срез цикла и чек-ина (SPEC §20.6, обязанность 1 + перевод `notified_at`).
//
//  Первая обязанность §20.6 — самая дорогая во всём слое: ошибка в ней не
//  падает, не видна в ответе и не ловится ни одним тестом §20.15. Она видна
//  только объёмом, и только у тех пользователей, у которых цикла нет. Поэтому
//  здесь проверяется не «поле переложилось», а «признак разгрузочной недели
//  работает» — то есть следствие, ради которого правило и существует.

import Testing
import FitCore
@testable import FitServer

@Suite("Mapping: цикл и чек-ин (§20.6)")
struct MappingCycleTests {

    // MARK: - Режим «без фаз» подставляется, а не берётся из дефолта

    @Test("строки cycle_profiles нет — режим без фаз с причиной «выбор пользователя»")
    func missingRowYieldsNoPhases() {
        let profile = Mapping.cycleProfile(from: nil, tracking: .off)
        #expect(profile.phaseMode == .noPhases)
        #expect(profile.noPhaseReason == .userChoice)
    }

    @Test("cycle_tracking = off — тоже без фаз, даже когда строка есть")
    func trackingOffYieldsNoPhases() {
        let row = Mapping.CycleProfileRow(typicalCycleLengthDays: 28, phaseMode: "phases")
        let profile = Mapping.cycleProfile(from: row, tracking: .off)
        #expect(profile.phaseMode == .noPhases, "источника данных нет — фаз нет")
    }

    @Test("сохранённая причина выигрывает у подставленной: §11.5 различает их по обратимости")
    func storedReasonSurvives() {
        let row = Mapping.CycleProfileRow(phaseMode: "no_phases", noPhaseReason: "menopause")
        #expect(Mapping.cycleProfile(from: row, tracking: .off).noPhaseReason == .menopause,
                "менопаузу нельзя переспросить позже, а «не сейчас» можно")
        let declined = Mapping.CycleProfileRow(phaseMode: "no_phases", noPhaseReason: "declined")
        #expect(Mapping.cycleProfile(from: declined, tracking: .off).noPhaseReason == .declined)
    }

    /// То самое следствие, ради которого обязанность 1 существует. Дефолт
    /// конструктора дал бы здесь фазовый режим, а в нём без опорной даты
    /// `plannedVolumeFactor` возвращает 1.0 и разгрузочная неделя молча
    /// игнорируется.
    @Test("подставленный режим делает признак разгрузочной недели рабочим (§11.5)")
    func noPhasesMakesDeloadWork() {
        let mapped = Mapping.cycleProfile(from: nil, tracking: .off)
        let state = Cycle.state(events: [], profile: mapped, responseProfiles: [:],
                                asOf: CalendarDay(year: 2026, month: 9, day: 29))
        let factor = Readiness.plannedVolumeFactor(cycleState: state, isDeloadWeek: true)
        #expect(factor < 1.0, "объём разгрузочной недели снижен")

        // Контроль: дефолт конструктора, от которого уводит §20.6.
        let naive = Cycle.state(events: [], profile: CycleProfile(), responseProfiles: [:],
                                asOf: CalendarDay(year: 2026, month: 9, day: 29))
        #expect(Readiness.plannedVolumeFactor(cycleState: naive, isDeloadWeek: true) == 1.0,
                "фиксирует цену молчаливого дефолта: разгрузка не срабатывает")
    }

    @Test("режим вне словаря читается как «без фаз», а не как фазовый")
    func unknownModeIsNoPhases() {
        let row = Mapping.CycleProfileRow(phaseMode: "приблизительно")
        #expect(Mapping.cycleProfile(from: row, tracking: .manual).phaseMode == .noPhases,
                "фазовый режим на мусорном значении двигал бы объём по выдуманной фазе")
    }

    @Test("при manual заявленные данные доезжают целиком")
    func declaredDataSurvives() {
        let row = Mapping.CycleProfileRow(typicalCycleLengthDays: 30, typicalPeriodLengthDays: 5,
                                          declaredRegularity: "variable", phaseMode: "phases",
                                          lowConfidenceStreak: 2,
                                          lowConfidenceCountedThrough: CalendarDay(year: 2026, month: 8, day: 1))
        let profile = Mapping.cycleProfile(from: row, tracking: .manual)
        #expect(profile.phaseMode == .phases)
        #expect(profile.typicalCycleLengthDays == 30)
        #expect(profile.typicalPeriodLengthDays == 5)
        #expect(profile.declaredRegularity == .variable)
        #expect(profile.lowConfidenceStreak == 2, "счётчик §11.5 персистентный — его нельзя терять")
        #expect(profile.lowConfidenceCountedThrough == CalendarDay(year: 2026, month: 8, day: 1))
    }

    // MARK: - События

    @Test("события переводятся, неизвестный вид отбрасывается")
    func eventsAreMapped() {
        let day = CalendarDay(year: 2026, month: 9, day: 1)
        let events = Mapping.cycleEvents(from: [
            Mapping.CycleEventRow(kind: "period_start", occurredOn: day),
            Mapping.CycleEventRow(kind: "spotting", occurredOn: day.adding(days: 3)),
            Mapping.CycleEventRow(kind: "полнолуние", occurredOn: day.adding(days: 5))
        ])
        #expect(events.map(\.kind) == [.periodStart, .spotting])
    }

    // MARK: - notified_at → notified

    @Test("notified_at переводится в Bool: ядру нужен факт, момент нужен UI")
    func notifiedIsDerivedFromTheTimestamp() {
        let rows = [
            Mapping.PhaseResponseRow(phase: "late_luteal", adjustment: -0.05, sampleSize: 4,
                                     notifiedAt: "2026-09-01T10:00:00Z"),
            Mapping.PhaseResponseRow(phase: "menstrual", adjustment: 0.02, sampleSize: 3)
        ]
        let profiles = Mapping.phaseResponses(from: rows)
        #expect(profiles[.lateLuteal]?.notified == true)
        #expect(profiles[.lateLuteal]?.adjustment == -0.05)
        #expect(profiles[.lateLuteal]?.sampleSize == 4)
        #expect(profiles[.menstrual]?.notified == false, "null означает «ещё не сообщали»")
    }

    @Test("неизвестная фаза в строке не попадает в словарь")
    func unknownPhaseIsDropped() {
        #expect(Mapping.phaseResponses(from: [
            Mapping.PhaseResponseRow(phase: "предменструальная", adjustment: 0, sampleSize: 9)
        ]).isEmpty)
    }

    // MARK: - Чек-ин и оверрайд

    @Test("строки нет — пустой чек-ин и отсутствие оверрайда, а не нули")
    func missingCheckinIsEmptyNotZero() {
        let (checkin, override) = Mapping.checkin(from: nil)
        #expect(checkin == DailyCheckin())
        #expect(checkin.energy == nil, "§10 читает незаполненное как отсутствие сигнала")
        #expect(override == nil)
    }

    @Test("чек-ин и оверрайд приезжают из одной строки порознь")
    func checkinAndOverrideComeApart() {
        let row = Mapping.CheckinRow(energy: 2, soreness: 4, sleepQuality: 3, stress: 5, override: "rest")
        let (checkin, override) = Mapping.checkin(from: row)
        #expect(checkin == DailyCheckin(energy: 2, soreness: 4, sleepQuality: 3, stress: 5))
        #expect(override == .rest)
    }

    @Test("оверрайд вне словаря — как будто его нет")
    func unknownOverrideIsNone() {
        #expect(Mapping.checkin(from: Mapping.CheckinRow(override: "отдохнуть")).override == nil)
    }

    @Test("частично заполненный чек-ин сохраняет незаполненное как nil")
    func partialCheckinKeepsNils() {
        let (checkin, _) = Mapping.checkin(from: Mapping.CheckinRow(energy: 4))
        #expect(checkin.energy == 4)
        #expect(checkin.soreness == nil)
    }
}
