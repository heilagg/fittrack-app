//  Срезы профиля, инвентаря и безопасности (SPEC §20.6).
//
//  Проверяется не отображение колонок — оно видно глазами, — а те правила
//  §20.6, которые слой обязан ПОСЧИТАТЬ. У всех них одно общее свойство,
//  названное в SPEC прямо: ни одно не падает и ни одно не видно в ответе.
//  Забытый фильтр активных ограничений даёт пул упражнений уже, чем должен;
//  непустой набор гирь при снятом флаге — вес, который неоткуда взять. Поэтому
//  тесты здесь отрицательные там, где правило отрицательное.

import Testing
import FitCore
@testable import FitServer

@Suite("Mapping: профиль, инвентарь, безопасность (§20.6)")
struct MappingProfileTests {

    // MARK: - Профиль и полнота

    private func row(level: String? = "novice", goal: String? = "hypertrophy",
                     weekdays: [Int]? = [1, 3, 5], minutes: Int = 45,
                     tracking: String = "off", split: String = "auto",
                     equipment: Bool = true) -> Mapping.ProfileRow {
        Mapping.ProfileRow(experienceLevel: level, goal: goal, trainingWeekdays: weekdays,
                           sessionMinutes: minutes, trainingSplit: split, cycleTracking: tracking,
                           sexAtBirth: "female",
                           hasDefaultEquipment: equipment)
    }

    @Test("training_split читается в срез и доезжает до CompleteProfile (§7.2)")
    func trainingSplitReachesCompleteProfile() throws {
        let slice = Mapping.profile(from: row(split: "push_pull_legs"))
        #expect(slice.trainingSplit == .pushPullLegs)
        #expect(slice.complete?.trainingSplit == .pushPullLegs)
        // Значение вне словаря — умолчание, как у cycle_tracking: профиль не
        // становится нечитаемым из-за одного поля.
        #expect(Mapping.profile(from: row(split: "bro_split")).trainingSplit == .auto)
        #expect(Mapping.ProfileSlice.notStarted.trainingSplit == .auto)
    }

    @Test("полный профиль даёт CompleteProfile")
    func completeProfile() throws {
        let slice = Mapping.profile(from: row())
        let complete = try #require(slice.complete)
        #expect(complete.level == .novice)
        #expect(complete.goal == .hypertrophy)
        #expect(complete.trainingWeekdays == [1, 3, 5])
        #expect(complete.daysPerWeek == 3)
    }

    @Test("любое из четырёх незаполненное — профиль неполон (§20.6)")
    func incompleteWhenAnyOfFourMissing() {
        #expect(Mapping.profile(from: row(level: nil)).complete == nil)
        #expect(Mapping.profile(from: row(goal: nil)).complete == nil)
        #expect(Mapping.profile(from: row(weekdays: nil)).complete == nil)
        #expect(Mapping.profile(from: row(weekdays: [])).complete == nil)
    }

    @Test("четыре поля без инвентаря по умолчанию — профиль неполон и называет его (§20.3, §20.6)")
    func incompleteWithoutDefaultEquipment() {
        let slice = Mapping.profile(from: row(equipment: false))
        #expect(slice.complete == nil)
        #expect(Mapping.missingProfileFields(slice) == ["equipment_profile"])
        #expect(Mapping.profile(from: row()).complete != nil)
    }

    @Test("шаги 3–5 пройдены, шаг 6 нет — профиль читается, но неполон (§5)")
    func partialOnboardingIsReadable() {
        let slice = Mapping.profile(from: row(weekdays: nil))
        #expect(slice.level == .novice, "то, что заполнено, доступно")
        #expect(slice.goal == .hypertrophy)
        #expect(slice.complete == nil, "а генерировать неделю нечем")
    }

    @Test("значение колонки вне словаря читается как незаполненное, а не роняет срез")
    func unknownEnumBecomesNil() {
        let slice = Mapping.profile(from: row(level: "чемпион", goal: "похудеть"))
        #expect(slice.level == nil)
        #expect(slice.goal == nil)
        #expect(slice.complete == nil)
    }

    @Test("cycle_tracking вне словаря — это off, а не отказ")
    func unknownTrackingIsOff() {
        #expect(Mapping.profile(from: row(tracking: "garmin")).cycleTracking == .off)
        #expect(Mapping.profile(from: row(tracking: "manual")).cycleTracking == .manual)
    }

    @Test("дни недели сортируются: сетка §7.2 раздаёт типы в календарном порядке")
    func weekdaysAreSorted() {
        #expect(Mapping.profile(from: row(weekdays: [5, 1, 3])).trainingWeekdays == [1, 3, 5])
    }

    @Test("ISO-номера превращаются в даты недели")
    func weekdaysBecomeDates() {
        // 2026-09-28 — понедельник.
        let monday = CalendarDay(year: 2026, month: 9, day: 28)
        let dates = Mapping.trainingDates(weekStart: monday, weekdays: [1, 3, 5])
        #expect(dates == [monday, monday.adding(days: 2), monday.adding(days: 4)])
        #expect(Mapping.trainingDates(weekStart: monday, weekdays: [7])
                == [CalendarDay(year: 2026, month: 10, day: 4)], "воскресенье — седьмой день")
    }

    // MARK: - Инвентарь: флаг главнее своей колонки (§7.5, §20.6)

    @Test("has_kettlebells = false обнуляет набор гирь, как бы он ни был заполнен")
    func kettlebellsFollowTheirFlag() {
        let row = Mapping.EquipmentRow(hasKettlebells: false, kettlebellsKg: [16, 24, 32])
        #expect(Mapping.equipment(from: row).profile.kettlebellsKg == [])
        #expect(Mapping.equipment(from: row).availability.hasKettlebells == false)

        var on = row
        on.hasKettlebells = true
        #expect(Mapping.equipment(from: on).profile.kettlebellsKg == [16, 24, 32])
    }

    @Test("шаг стека обнуляется, когда нет ни троса, ни тренажёров")
    func machineStepFollowsItsFlag() {
        let bare = Mapping.EquipmentRow(machineStepKg: 2.5, cableMachine: false, machines: [])
        #expect(Mapping.equipment(from: bare).profile.machineStepKg == nil)

        var cable = bare
        cable.cableMachine = true
        #expect(Mapping.equipment(from: cable).profile.machineStepKg == 2.5)

        var machines = bare
        machines.machines = ["leg_press"]
        #expect(Mapping.equipment(from: machines).profile.machineStepKg == 2.5,
                "тренажёра достаточно, троса не требуется")
    }

    @Test("обнулённый шаг даёт пустую лестницу: вес, которого неоткуда взять, не предписывается")
    func zeroedStepYieldsEmptyLadder() {
        let bare = Mapping.EquipmentRow(machineStepKg: 2.5, cableMachine: false, machines: [])
        let slice = Mapping.equipment(from: bare)
        // `.discrete([])`, а не `.none`: последнее означает «упражнение без
        // веса» (§9.5), а здесь упражнение весовое, просто достижимых весов
        // нет. Разница несущая — §7.5 объявляет упражнение выполнимым, только
        // если лестница его `load_type` НЕ пуста, и пустая снимает его с
        // подбора. Оставленный шаг при снятом флаге, наоборот, оставил бы
        // упражнение в пуле и предписал вес на невидимом стеке.
        #expect(WeightLadder.build(loadType: .machine, profile: slice.profile) == .discrete([]))
        #expect(WeightLadder.build(loadType: .cable, profile: slice.profile) == .discrete([]))

        var withCable = bare
        withCable.cableMachine = true
        #expect(WeightLadder.build(loadType: .machine, profile: Mapping.equipment(from: withCable).profile)
                == .arithmetic(step: 2.5))
    }

    @Test("строка даёт оба значения §7.5 сразу")
    func rowYieldsBothQuestions() {
        let row = Mapping.EquipmentRow(dumbbellsKg: [10, 6, 8], platesKg: [10, 1.25, 2.5],
                                       barbellKg: 20, bands: true, pullupBar: true,
                                       bench: "adjustable", stepPlatform: true)
        let slice = Mapping.equipment(from: row)
        #expect(slice.profile.dumbbellsKg == [6, 8, 10], "веса сортируются")
        #expect(slice.profile.platesKg == [1.25, 2.5, 10])
        #expect(slice.profile.barbellKg == 20)
        #expect(slice.availability.bench == .adjustable)
        #expect(slice.availability.satisfies(.benchFlat), "регулируемая годится на месте плоской")
        #expect(slice.availability.satisfies(.pullupBar))
        #expect(slice.availability.satisfies(.stepPlatform))
        #expect(!slice.availability.satisfies(.plyoBox), "тумба под степ не подходит (§6.6)")
    }

    @Test("скамья вне словаря — как будто скамьи нет")
    func unknownBenchIsNoBench() {
        let slice = Mapping.equipment(from: Mapping.EquipmentRow(bench: "олимпийская"))
        #expect(slice.availability.bench == nil)
        #expect(!slice.availability.satisfies(.benchFlat))
    }

    // MARK: - Безопасность

    @Test("снятое ограничение не фильтрует (§20.6)")
    func resolvedRestrictionsAreDropped() {
        let rows = [
            Mapping.RestrictionRow(joint: "knee", severity: "avoid"),
            Mapping.RestrictionRow(joint: "shoulder", severity: "careful",
                                   resolvedAt: "2026-09-01T00:00:00Z")
        ]
        let active = Mapping.restrictions(from: rows)
        #expect(active.map(\.joint) == [.knee], "плечо снято — пул не сужается")
    }

    @Test("ограничение с нераспознанным суставом или степенью не молчит наполовину")
    func unknownRestrictionIsDropped() {
        let rows = [Mapping.RestrictionRow(joint: "позвоночник", severity: "avoid"),
                    Mapping.RestrictionRow(joint: "knee", severity: "иногда")]
        #expect(Mapping.restrictions(from: rows).isEmpty)
    }

    @Test("суставы события боли читаются из колонки, а не выводятся заново")
    func painJointsComeFromTheColumn() {
        let day = CalendarDay(year: 2026, month: 9, day: 20)
        let events = Mapping.painEvents(from: [
            Mapping.PainRow(exerciseSlug: "squat_barbell", joints: ["knee", "hip"], occurredOn: day)
        ])
        #expect(events.count == 1)
        #expect(events[0].joints == [.knee, .hip])
        #expect(events[0].occurredOn == day)
    }

    @Test("событие без единого распознанного сустава отбрасывается целиком")
    func painRowWithoutJointsIsDropped() {
        // Пустое событие раздуло бы счёт эскалации §8.4 п.4, не дав ни одного
        // сустава для разгрузки.
        let day = CalendarDay(year: 2026, month: 9, day: 20)
        #expect(Mapping.painEvents(from: [
            Mapping.PainRow(exerciseSlug: "squat_barbell", joints: [], occurredOn: day),
            Mapping.PainRow(exerciseSlug: "squat_barbell", joints: ["хребет"], occurredOn: day)
        ]).isEmpty)
    }

    @Test("isConservative — это has_red_flag, и acknowledged на него не влияет (§14.1)")
    func conservativeFollowsRedFlagOnly() {
        let flagged = Mapping.safety(level: .novice, restrictions: [], painRows: [], hasRedFlag: true)
        #expect(flagged.isConservative)
        let clear = Mapping.safety(level: .novice, restrictions: [], painRows: [], hasRedFlag: false)
        #expect(!clear.isConservative)
    }
}
