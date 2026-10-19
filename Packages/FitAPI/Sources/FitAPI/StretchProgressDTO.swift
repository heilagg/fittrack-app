//  Сессии растяжки и прогресс (SPEC §12.2, §13.7, §20.3).
//
//  Форма границы — здесь, по общему правилу §20.2: имена случаев FitCore на
//  провод не едут, каждый ключ задан строкой.

import FitCore

// MARK: - Сессии растяжки

/// `POST /v1/stretch-sessions` (§20.3). `id` — клиентский: повтор с тем же
/// `id` отдаёт ту же строку, как у подходов (§20.6).
public struct StartStretchSessionRequest: Sendable, Equatable, Codable {
    public var id: String
    /// `standalone` | `static_cooldown`; `mobility_warmup` на В3 не пишется (§12.1).
    public var kind: String
    /// Шаблон §12.2; у заминки — `nil`.
    public var templateSlug: String?
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case id, kind
        case templateSlug = "template_slug"
        case date, tz
    }

    public init(id: String, kind: String, templateSlug: String?, day: DayContext) {
        self.id = id
        self.kind = kind
        self.templateSlug = templateSlug
        self.date = day.date
        self.tz = day.tz
    }
}

/// `POST /v1/stretch-sessions/{id}/finish`.
public struct FinishStretchSessionRequest: Sendable, Equatable, Codable {
    public var date: String
    public var tz: String

    public init(day: DayContext) {
        self.date = day.date
        self.tz = day.tz
    }
}

/// Строка `stretch_sessions` на проводе (§3.1, §20.3).
public struct StretchSessionDTO: Sendable, Equatable, Codable {
    public var id: String
    public var kind: String
    public var templateSlug: String?
    /// Местный день сессии, ISO `yyyy-mm-dd` (§20.7).
    public var performedOn: String
    public var startedAt: String
    public var finishedAt: String?
    /// `finished_at − started_at`, только у завершённой.
    public var durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case templateSlug = "template_slug"
        case performedOn = "performed_on"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationSeconds = "duration_seconds"
    }

    public init(id: String, kind: String, templateSlug: String?, performedOn: String,
                startedAt: String, finishedAt: String?, durationSeconds: Int?) {
        self.id = id
        self.kind = kind
        self.templateSlug = templateSlug
        self.performedOn = performedOn
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
    }
}

/// `GET /v1/stretch-sessions` (§20.3): последние завершённые сессии и
/// предложенный шаблон дня (§12.2).
public struct StretchHistoryDTO: Sendable, Equatable, Codable {
    public var sessions: [StretchSessionDTO]
    public var suggestedTemplate: String

    enum CodingKeys: String, CodingKey {
        case sessions
        case suggestedTemplate = "suggested_template"
    }

    public init(sessions: [StretchSessionDTO], suggestedTemplate: String) {
        self.sessions = sessions
        self.suggestedTemplate = suggestedTemplate
    }
}

// MARK: - Прогресс

/// Названия групп мышц экрана прогресса (§13.7). Каталог формулировок — здесь,
/// по тому же доводу, что названия типов дня (§7.2).
public enum MuscleGroupNames {
    public static func name(_ group: MuscleGroup) -> String {
        switch group {
        case .legsGlutes: return "Ноги и ягодицы"
        case .back: return "Спина"
        case .chest: return "Грудь"
        case .shoulders: return "Плечи"
        case .arms: return "Руки"
        case .core: return "Кор"
        }
    }
}

/// `GET /v1/progress` (§13.7, §20.3).
public struct ProgressDTO: Sendable, Equatable, Codable {
    public var from: String
    public var to: String
    public var weeks: [ProgressWeekDTO]
    public var groupNorms: [GroupNormDTO]
    public var baselines: [BaselineSeriesDTO]
    public var days: [ProgressDayDTO]
    public var streakWeeks: Int

    enum CodingKeys: String, CodingKey {
        case from, to, weeks
        case groupNorms = "group_norms"
        case baselines, days
        case streakWeeks = "streak_weeks"
    }

    public init(from: String, to: String, weeks: [ProgressWeekDTO], groupNorms: [GroupNormDTO],
                baselines: [BaselineSeriesDTO], days: [ProgressDayDTO], streakWeeks: Int) {
        self.from = from
        self.to = to
        self.weeks = weeks
        self.groupNorms = groupNorms
        self.baselines = baselines
        self.days = days
        self.streakWeeks = streakWeeks
    }
}

/// Неделя окна: объём групп в эффективных подходах; `partial` — текущая.
public struct ProgressWeekDTO: Sendable, Equatable, Codable {
    public var weekStart: String
    public var partial: Bool
    /// Ключи — `MuscleGroup.rawValue`, все шесть всегда.
    public var groups: [String: Double]

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start", partial, groups
    }

    public init(weekStart: String, partial: Bool, groups: [String: Double]) {
        self.weekStart = weekStart
        self.partial = partial
        self.groups = groups
    }
}

/// Норма и потолок группы по уровню (§13.7) и её название.
public struct GroupNormDTO: Sendable, Equatable, Codable {
    public var group: String
    public var name: String
    public var norm: Double
    public var ceiling: Double

    public init(group: MuscleGroup, level: ExperienceLevel) {
        let values = Progress.groupNorm(group, level: level)
        self.group = group.rawValue
        self.name = MuscleGroupNames.name(group)
        self.norm = values.norm
        self.ceiling = values.ceiling
    }
}

/// Ряд базовой линии упражнения (§13.7).
public struct BaselineSeriesDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var points: [BaselinePointDTO]

    public init(slug: String, points: [BaselinePointDTO]) {
        self.slug = slug
        self.points = points
    }
}

public struct BaselinePointDTO: Sendable, Equatable, Codable {
    public var date: String
    public var kg: Double

    public init(date: String, kg: Double) {
        self.date = date
        self.kg = kg
    }
}

/// День календаря активности (§13.7). `phase` есть только в режиме с фазами и
/// при уверенности на тот день не ниже 0.3; уверенность не отдаётся.
public struct ProgressDayDTO: Sendable, Equatable, Codable {
    public var date: String
    public var strength: Bool
    public var stretch: Bool
    public var skipped: Bool
    public var phase: String?

    public init(date: String, strength: Bool, stretch: Bool, skipped: Bool, phase: String?) {
        self.date = date
        self.strength = strength
        self.stretch = stretch
        self.skipped = skipped
        self.phase = phase
    }
}
