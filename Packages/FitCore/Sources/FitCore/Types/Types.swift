//  Types — базовые значимые типы предметной области.
//
//  Здесь живут: MuscleSlug, Pattern, LoadType, Feedback, Phase, Goal,
//  ExperienceLevel, ReasonCode, а также собственные CalendarDay/Timestamp.
//
//  Почему свои дата-типы, а не Foundation.Date/Calendar: тесты фаз цикла
//  (SPEC §11) и детренированности (SPEC §9.7) иначе плавают от часового
//  пояса и перехода на летнее время.
//
//  ReasonCode — enum кодов причин. Русские формулировки живут в
//  App/FitTrack/Localization, не здесь.
//
//  Остальные типы добавляются по мере реализации соответствующих модулей.
//  LoadType понадобился первым — как зависимость Equipment/WeightLadder.
//  MuscleSlug, Joint, JointStressLevel и Timestamp добавлены для Recovery:
//  распад утомления (SPEC §8.1) считается в часах, а не в целых сутках, поэтому
//  CalendarDay для него недостаточно точен.
//  Phase, PhaseMode, Override и ExerciseImpact добавлены для Cycle (SPEC §11):
//  все четыре пересекают границу модуля — Readiness читает Phase/PhaseMode/
//  Override для phaseTerm (§10), Planner читает Phase/PhaseMode для недельного
//  среза объёма (§10, plannedFactor) и ExerciseImpact для оверуляторного
//  ограничения (§11.2). ReasonCode тоже добавлен здесь: причина фазового
//  происхождения обязана нести cycleConfidence (SPEC §14.6), и этот контракт
//  общий для любого будущего источника причин, не только Cycle.
//  Pattern, ExperienceLevel и Goal добавлены для Planner (SPEC §7): паттерн и
//  skill_level — поля среза ExerciseCandidate (§7.5), уровень и цель — вход
//  сборки (§7.4, §9.1). Причины планировщика (ослабление паттернов, пересборка,
//  статус недели) — новые случаи ReasonCode, по тому же контракту §14.6.

/// Способ округления/квантования веса упражнения (SPEC §6.3).
public enum LoadType: String, Sendable, Equatable, Hashable, CaseIterable {
    case bodyweight
    case bodyweightLoaded = "bodyweight_loaded"
    case dumbbell
    case barbell
    case machine
    case cable
    case band
    case kettlebell
}

/// Оценка пользователем сложности выполненного подхода (SPEC §9.2),
/// соответствует `sets.feedback` (SPEC §3.1: 'easy' | 'ok' | 'hard' | 'failed').
public enum Feedback: String, Sendable, Equatable, Hashable, CaseIterable {
    case easy
    case ok
    case hard
    case failed
}

/// Календарный день без времени и часового пояса — проленптический
/// григорианский номер дня, независимый от Foundation.Date/Calendar.
/// Понадобился первым в Progression: детренированность (SPEC §9.7) считается
/// в целых днях от `last_performed_at`, и разница по Date/Calendar плавает
/// от часового пояса и перехода на летнее время (см. doc-комментарий файла).
public struct CalendarDay: Sendable, Equatable, Hashable, Comparable {
    public let dayNumber: Int

    public init(dayNumber: Int) {
        self.dayNumber = dayNumber
    }

    /// `year`/`month`/`day` в проленптическом григорианском календаре.
    /// Алгоритм Хауарда Хиннанта (`days_from_civil`) — целочисленный, без
    /// плавающей точки и без обращения к системному календарю:
    /// http://howardhinnant.github.io/date_algorithms.html
    public init(year: Int, month: Int, day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        self.dayNumber = era * 146097 + dayOfEra - 719468
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }

    /// Число дней от `self` до `other`; отрицательное, если `other` раньше `self`.
    public func days(until other: CalendarDay) -> Int {
        other.dayNumber - dayNumber
    }

    public func adding(days: Int) -> CalendarDay {
        CalendarDay(dayNumber: dayNumber + days)
    }
}

/// Момент времени в часах от эпохи — независим от Foundation.Date/TimeZone,
/// как и CalendarDay. Нужен там, где гранулярности суток недостаточно:
/// распад утомления (SPEC §8.1) считается по периоду полураспада в часах
/// (20–40ч), а не в сутках.
public struct Timestamp: Sendable, Equatable, Hashable, Comparable {
    public let hoursSinceEpoch: Double

    public init(hoursSinceEpoch: Double) {
        self.hoursSinceEpoch = hoursSinceEpoch
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        lhs.hoursSinceEpoch < rhs.hoursSinceEpoch
    }

    /// Число часов от `self` до `other`; отрицательное, если `other` раньше `self`.
    public func hours(until other: Timestamp) -> Double {
        other.hoursSinceEpoch - hoursSinceEpoch
    }

    public func adding(hours: Double) -> Timestamp {
        Timestamp(hoursSinceEpoch: hoursSinceEpoch + hours)
    }
}

/// Плоский список слагов мышц (SPEC §6.4), без иерархии.
public enum MuscleSlug: String, Sendable, Equatable, Hashable, CaseIterable {
    case gluteMax = "glute_max"
    case gluteMed = "glute_med"
    case quads
    case hamstrings
    case adductors
    case calves
    case erectors
    case lats
    case trapsMid = "traps_mid"
    case trapsUpper = "traps_upper"
    case rearDelts = "rear_delts"
    case sideDelts = "side_delts"
    case frontDelts = "front_delts"
    case pecs
    case biceps
    case triceps
    case forearms
    case abs
    case obliques
}

/// Сустав из `user_restrictions.joint` (SPEC §3.1) / `exercise.joint_stress`
/// (SPEC §6.2) — нужен Recovery для эскалации флага боли по суставу (SPEC §8.4).
///
/// Порядок объявления повторяет порядок в комментарии к `user_restrictions.joint`
/// (§3.1) и используется как детерминированный тай-брейк в
/// `Recovery.primaryJoint(from:)` — см. там же о том, почему тай-брейк вообще
/// понадобился.
public enum Joint: String, Sendable, Equatable, Hashable, CaseIterable {
    case knee
    case lowerBack = "lower_back"
    case shoulder
    case wrist
    case neck
    case hip
    case ankle
}

/// Степень нагрузки на сустав — значение `exercise.joint_stress[joint]` (SPEC §6.2).
///
/// SPEC нигде не перечисляет допустимые значения явным списком (в отличие от
/// `pattern`, `load_type` или колонок `user_restrictions`). Набор `low | medium |
/// high` выведен из примера §6.2 (`{"knee": "low", "lower_back": "medium", …}`)
/// плюс §6.3 и §14.4 («`avoid` исключает `high` и `medium`, `careful` — только
/// `high`»), а не процитирован. Порядок `low < medium < high` там же не объявлен
/// и тоже выведен из этой формулировки: `avoid` строже `careful` и захватывает
/// на одну ступень больше.
public enum JointStressLevel: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: JointStressLevel, rhs: JointStressLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Фаза цикла (SPEC §11.1). Порядок объявления — порядок разрешения границ
/// на коротких циклах (Cycle/PhaseResolver.swift): менструальная выигрывает
/// всегда, фолликулярная схлопывается первой.
public enum Phase: String, Sendable, Equatable, Hashable, CaseIterable {
    case menstrual
    case follicular
    case ovulatory
    case earlyLuteal = "early_luteal"
    case lateLuteal = "late_luteal"
}

/// `cycle_profiles.phase_mode` (SPEC §3.1, §11.5).
public enum PhaseMode: String, Sendable, Equatable, Hashable {
    case phases
    case noPhases = "no_phases"
}

/// Ручной оверрайд готовности на день (SPEC §11.4, `daily_checkins.override`).
public enum Override: String, Sendable, Equatable, Hashable {
    case push
    case ease
    case rest
}

/// Ударная нагрузка упражнения при приземлении (SPEC §6.3, `exercise.impact`).
/// Единственный источник для овуляторного ограничения §11.2.
public enum ExerciseImpact: String, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case low
    case high
}

/// Причина, стоящая за рекомендацией или её изменением. Русские формулировки
/// живут в App/FitTrack/Localization, не здесь — этот тип несёт только код
/// причины и то, что нужно слою представления для решения, как её показать.
///
/// SPEC §14.6: причина фазового происхождения обязана нести `cycleConfidence`,
/// при котором она выдана — мягкость формулировки в локализации не может быть
/// единственной защитой от утвердительного тона, потому что строку меняет
/// кто угодно и когда угодно.
public enum ReasonCode: Sendable, Equatable {
    /// Фаза сдвинула недельный объём, целевой RIR и/или тип блока (SPEC §11.2).
    case phasePeriodization(phase: Phase, cycleConfidence: Double)
    /// Овуляторное ограничение: понижен приоритет высокоударного упражнения
    /// (SPEC §11.2, `impact = high`).
    case ovulatoryImpactCaution(cycleConfidence: Double)
    /// Минимум трёх паттернов ослаблен: столько разных паттернов, работающих на
    /// мышцы дня, на этом инвентаре и с этими ограничениями нет (SPEC §7.3,
    /// сценарий 30a). Пользователь этого изменить не может.
    case patternMinimumRelaxedUnavailable(available: Int)
    /// Минимум трёх паттернов ослаблен по времени: не помещается в
    /// `session_minutes` (SPEC §7.3, сценарий 29a). Меняется одним тапом.
    case patternMinimumRelaxedByTime(fitted: Int)
    /// Минимум трёх паттернов ослаблен лимитом сборки — семь упражнений или
    /// «не более двух из семьи» (§7.3), а не временем: тап по
    /// `session_minutes` этого не решит, поэтому причина отдельная от
    /// `patternMinimumRelaxedByTime`. SPEC §7.3 называет только две причины
    /// (доступность и время); третья найдена при ревью реализации.
    case patternMinimumRelaxedByLimit(fitted: Int, limit: PatternLimit)
    /// «План обновлён» (SPEC §7.1) — печатается, только если у оставшихся дней
    /// изменился состав или объём.
    case planRebuilt(cause: RebuildCause)
    /// Статус недели: выйдет меньше подходов, потому что день потерян (SPEC
    /// §7.1). Причина отличает пропуск от дня отдыха по оверрайду и от замены —
    /// формулировки у них разные, а число одно и то же.
    case weekLossFromSkips(muscle: MuscleSlug, sets: Int, cause: DayOutcome.Cause)
    /// Статус недели: недобор по времени (SPEC §7.1, сценарий 29c).
    case weekShortfallByTime(muscle: MuscleSlug, sets: Int)
    /// Генератор тренировок отключён (SPEC §14.3, сценарий 26).
    case workoutGenerationDisabled
}

/// Какой лимит сборки не дал добрать паттерны (SPEC §7.3).
public enum PatternLimit: Sendable, Equatable {
    /// Жадный шаг уже набрал семь упражнений.
    case exerciseCount
    /// Все кандидаты нового паттерна — из семей, где уже по два упражнения.
    case family
}

/// Что вызвало пересборку (SPEC §7.1, таблица триггеров). Фазовые причины несут
/// `cycleConfidence` по тому же правилу §14.6, что и `ReasonCode`.
public enum RebuildCause: Sendable, Equatable {
    case phaseChanged(phase: Phase?, cycleConfidence: Double?)
    case cycleConfidenceChanged(cycleConfidence: Double?)
    case workoutSkipped
    case workoutCompleted
    case override
    case dayEdited
    case equipmentChanged
}

/// `exercise.pattern` (SPEC §6.3).
public enum Pattern: String, Sendable, Equatable, Hashable, CaseIterable {
    case squat
    case hinge
    case lunge
    case pushH = "push_h"
    case pushV = "push_v"
    case pullH = "pull_h"
    case pullV = "pull_v"
    case carry
    case core
    case isolation
}

/// `profiles.experience_level` и `exercise.skill_level` (SPEC §3.1, §6.3) —
/// одна шкала: правило §7.3 сравнивает их напрямую.
public enum ExperienceLevel: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case novice
    case intermediate
    case advanced

    private var rank: Int {
        switch self {
        case .novice: return 0
        case .intermediate: return 1
        case .advanced: return 2
        }
    }

    public static func < (lhs: ExperienceLevel, rhs: ExperienceLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// `profiles.goal` (SPEC §3.1, §9.1).
public enum Goal: String, Sendable, Equatable, Hashable, CaseIterable {
    case strength
    case hypertrophy
    case toning
    case endurance
    case general
}
