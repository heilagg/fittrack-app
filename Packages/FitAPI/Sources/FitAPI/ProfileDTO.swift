//  Тела `GET` и `PATCH /v1/profile` (SPEC §5, §20.3, §20.6).
//
//  ── Почему почти всё необязательно ────────────────────────────────────────
//
//  Это не слабость типа, а состояние онбординга. §5 заполняет профиль по шагам,
//  и на вебе шаги пишутся на сервер по мере прохождения (§4.2), поэтому строка
//  существует НЕПОЛНОЙ: `null` означает «ещё не спросили». Обязательны только
//  те два поля, у которых в схеме есть умолчание, и `is_complete`.
//
//  ── `is_complete` — ответ сервера, а не колонка ───────────────────────────
//
//  Единственный вопрос, который клиенту про профиль нужен: хватает ли данных,
//  чтобы сгенерировать неделю. Считается он из четырёх полей `profiles` и
//  наличия профиля инвентаря по умолчанию (`equipment_profiles` с
//  `is_default = true`, §20.3) и мог бы считаться клиентом — но тогда правило
//  жило бы в двух местах, и разойтись им значит показать кнопку «Начать», за
//  которой стоит 409 (§20.6).
//
//  ── Три состояния поля в теле правки ──────────────────────────────────────
//
//  Отсутствие ключа — «не трогать», явный `null` — «снять значение», значение —
//  «поставить» (§20.3). Различать первые два обязательно: онбординг шлёт
//  подмножества полей, и «поле не прислали» не означает «сними его».
//
//  Исключение — `session_minutes` и `cycle_tracking`: в схеме они `not null` с
//  умолчанием, снять их нечем, и третьего состояния у них не бывает.

import FitCore

/// Настройки цикла — `cycle_profiles` (§3.1, §11.5).
public struct CycleProfileDTO: Sendable, Equatable, Codable {
    public var typicalCycleLengthDays: Int?
    public var typicalPeriodLengthDays: Int?
    public var declaredRegularity: DeclaredRegularity?
    public var phaseMode: PhaseMode
    public var noPhaseReason: NoPhaseReason?

    enum CodingKeys: String, CodingKey {
        case typicalCycleLengthDays = "typical_cycle_length_days"
        case typicalPeriodLengthDays = "typical_period_length_days"
        case declaredRegularity = "declared_regularity"
        case phaseMode = "phase_mode"
        case noPhaseReason = "no_phase_reason"
    }

    public init(typicalCycleLengthDays: Int? = nil, typicalPeriodLengthDays: Int? = nil,
                declaredRegularity: DeclaredRegularity? = nil, phaseMode: PhaseMode,
                noPhaseReason: NoPhaseReason? = nil) {
        self.typicalCycleLengthDays = typicalCycleLengthDays
        self.typicalPeriodLengthDays = typicalPeriodLengthDays
        self.declaredRegularity = declaredRegularity
        self.phaseMode = phaseMode
        self.noPhaseReason = noPhaseReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        typicalCycleLengthDays = try c.decodeIfPresent(Int.self, forKey: .typicalCycleLengthDays)
        typicalPeriodLengthDays = try c.decodeIfPresent(Int.self, forKey: .typicalPeriodLengthDays)
        declaredRegularity = try c.decodeRawIfPresent(DeclaredRegularity.self, forKey: .declaredRegularity)
        phaseMode = try c.decodeRaw(PhaseMode.self, forKey: .phaseMode)
        noPhaseReason = try c.decodeRawIfPresent(NoPhaseReason.self, forKey: .noPhaseReason)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(typicalCycleLengthDays, forKey: .typicalCycleLengthDays)
        try c.encodeIfPresent(typicalPeriodLengthDays, forKey: .typicalPeriodLengthDays)
        try c.encodeRawIfPresent(declaredRegularity, forKey: .declaredRegularity)
        try c.encodeRaw(phaseMode, forKey: .phaseMode)
        try c.encodeRawIfPresent(noPhaseReason, forKey: .noPhaseReason)
    }
}

/// Источник данных о цикле — `profiles.cycle_tracking` (§3.1). НЕ режим фаз:
/// режим живёт в `cycle_profiles.phase_mode`, и путать их нельзя.
public enum CycleTracking: String, Sendable, Equatable, CaseIterable, Codable {
    case off
    case manual
    case healthkit
}

/// Тело `GET /v1/profile` и `PATCH /v1/profile` (§20.3).
public struct ProfileDTO: Sendable, Equatable, Codable {
    public var sexAtBirth: String?
    public var birthYear: Int?
    public var heightCm: Double?
    public var experienceLevel: ExperienceLevel?
    public var goal: Goal?
    public var daysPerWeek: Int?
    public var trainingWeekdays: [Int]?
    public var sessionMinutes: Int
    public var cycleTracking: CycleTracking
    /// Хватает ли данных, чтобы сгенерировать неделю (§20.6). Считает сервер.
    public var isComplete: Bool
    /// `null` — строки `cycle_profiles` нет вовсе (мужчина либо шаг 9 не
    /// пройден). Законное состояние: `Mapping/` подставляет режим «без фаз».
    public var cycle: CycleProfileDTO?

    enum CodingKeys: String, CodingKey {
        case sexAtBirth = "sex_at_birth", birthYear = "birth_year", heightCm = "height_cm"
        case experienceLevel = "experience_level", goal
        case daysPerWeek = "days_per_week", trainingWeekdays = "training_weekdays"
        case sessionMinutes = "session_minutes", cycleTracking = "cycle_tracking"
        case isComplete = "is_complete", cycle
    }

    public init(sexAtBirth: String? = nil, birthYear: Int? = nil, heightCm: Double? = nil,
                experienceLevel: ExperienceLevel? = nil, goal: Goal? = nil,
                daysPerWeek: Int? = nil, trainingWeekdays: [Int]? = nil,
                sessionMinutes: Int, cycleTracking: CycleTracking, isComplete: Bool,
                cycle: CycleProfileDTO? = nil) {
        self.sexAtBirth = sexAtBirth
        self.birthYear = birthYear
        self.heightCm = heightCm
        self.experienceLevel = experienceLevel
        self.goal = goal
        self.daysPerWeek = daysPerWeek
        self.trainingWeekdays = trainingWeekdays
        self.sessionMinutes = sessionMinutes
        self.cycleTracking = cycleTracking
        self.isComplete = isComplete
        self.cycle = cycle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sexAtBirth = try c.decodeIfPresent(String.self, forKey: .sexAtBirth)
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        experienceLevel = try c.decodeRawIfPresent(ExperienceLevel.self, forKey: .experienceLevel)
        goal = try c.decodeRawIfPresent(Goal.self, forKey: .goal)
        daysPerWeek = try c.decodeIfPresent(Int.self, forKey: .daysPerWeek)
        trainingWeekdays = try c.decodeIfPresent([Int].self, forKey: .trainingWeekdays)
        sessionMinutes = try c.decode(Int.self, forKey: .sessionMinutes)
        cycleTracking = try c.decodeRaw(CycleTracking.self, forKey: .cycleTracking)
        isComplete = try c.decode(Bool.self, forKey: .isComplete)
        cycle = try c.decodeIfPresent(CycleProfileDTO.self, forKey: .cycle)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sexAtBirth, forKey: .sexAtBirth)
        try c.encodeIfPresent(birthYear, forKey: .birthYear)
        try c.encodeIfPresent(heightCm, forKey: .heightCm)
        try c.encodeRawIfPresent(experienceLevel, forKey: .experienceLevel)
        try c.encodeRawIfPresent(goal, forKey: .goal)
        try c.encodeIfPresent(daysPerWeek, forKey: .daysPerWeek)
        try c.encodeIfPresent(trainingWeekdays, forKey: .trainingWeekdays)
        try c.encode(sessionMinutes, forKey: .sessionMinutes)
        try c.encodeRaw(cycleTracking, forKey: .cycleTracking)
        try c.encode(isComplete, forKey: .isComplete)
        try c.encodeIfPresent(cycle, forKey: .cycle)
    }
}
