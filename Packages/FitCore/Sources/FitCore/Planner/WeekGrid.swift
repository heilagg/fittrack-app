//  Недельная сетка (SPEC §7.2) и запись дня недели, которую читают сборка и
//  пересборка. Сетка зависит только от выбранных дней, уровня и схемы
//  тренировок (`TrainingSplit`): цель, фаза, утомление и прошлый объём
//  действуют в сборке, не в расстановке.

/// `planned_days.session_kind` (SPEC §3.1). «Ноги» — `lower`.
public enum SessionKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case fullBody = "full_body"
    case upper
    case lower
    case push
    case pull
    case rest
    case stretch
}

/// `planned_days.status` (SPEC §3.1).
public enum PlannedDayStatus: String, Sendable, Equatable, Hashable {
    case planned
    case done
    case skipped
    case replaced
}

/// Строка `planned_days` вместе с целевым вектором её пары (тип, акцент).
/// Вектор — вход (§7.3): таблицу векторов держит FitContent, и для растяжки и
/// отдыха он пустой.
public struct PlannedDay: Sendable, Equatable {
    public var id: String
    public var date: CalendarDay
    public var kind: SessionKind
    public var accent: MuscleSlug?
    public var vector: [MuscleSlug: Double]
    public var status: PlannedDayStatus

    public init(
        id: String,
        date: CalendarDay,
        kind: SessionKind,
        accent: MuscleSlug? = nil,
        vector: [MuscleSlug: Double],
        status: PlannedDayStatus = .planned
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.accent = accent
        self.vector = vector
        self.status = status
    }

    /// Силовая сессия — та, что входит в знаменатель `S_эфф` (§7.3).
    public var isStrength: Bool { !vector.isEmpty && kind != .stretch && kind != .rest }
}

/// Слот сетки: дата и тип. Акцент сетка не ставит никогда (§7.2).
public struct GridSlot: Sendable, Equatable {
    public var date: CalendarDay
    public var kind: SessionKind
    public var accent: MuscleSlug? { nil }

    public init(date: CalendarDay, kind: SessionKind) {
        self.date = date
        self.kind = kind
    }
}

/// `profiles.training_split` (SPEC §3.1, §7.2, «Схема тренировок»).
public enum TrainingSplit: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Расстановка §7.2 по числу дней и уровню — прежнее поведение.
    case auto
    case fullBody = "full_body"
    case upperLower = "upper_lower"
    case pushPullLegs = "push_pull_legs"
}

extension Planner {
    /// Расстановка §7.2. Типы назначаются выбранным дням в календарном порядке;
    /// растяжка — последний выбранный день и входит в `days_per_week`.
    ///
    /// Даты вызывающая сторона строит из `profiles.training_weekdays` (SPEC
    /// §3.1, §7.2) — ISO-номера 1...7 от понедельника недели. **Дубликаты
    /// схлопываются здесь молча** (`Set(days)`), поэтому уникальность набора
    /// обязана проверяться схемой: `{2,2,4}` при `days_per_week = 3` даёт два
    /// дня вместо трёх и другие типы дней (два full body вместо верх/низ/full
    /// body).
    ///
    /// `split` — схема тренировок из Профиля. Значения по умолчанию у параметра
    /// нет намеренно: забытый аргумент неотличим от «Авто», и выбранная схема
    /// молча перестала бы действовать. Уровень опыта читает только «Авто»: явная
    /// схема — выбор пользовательницы (§7.2). Ротации между неделями нет, каждая
    /// неделя собирается от понедельника заново.
    public static func weekGrid(days: [CalendarDay], level: ExperienceLevel, split: TrainingSplit) -> [GridSlot] {
        let sorted = Set(days).sorted()
        let kinds = gridKinds(count: sorted.count, level: level, split: split)
        return zip(sorted, kinds).map { GridSlot(date: $0, kind: $1) }
    }

    /// Таблица §7.2 — типы по числу дней. Больше семи дней в неделе не бывает:
    /// всё, что выше, читается как семь, как и раньше.
    static func gridKinds(count: Int, level: ExperienceLevel, split: TrainingSplit) -> [SessionKind] {
        guard count > 0 else { return [] }
        let n = min(count, 7)
        switch split {
        case .auto:
            switch n {
            case 1, 2: return Array(repeating: .fullBody, count: n)
            case 3: return level == .novice ? [.fullBody, .fullBody, .fullBody] : [.upper, .lower, .fullBody]
            case 4: return [.upper, .lower, .upper, .lower]
            case 5: return [.upper, .lower, .upper, .lower, .fullBody]
            case 6: return [.push, .pull, .lower, .upper, .lower, .stretch]
            default: return [.push, .pull, .lower, .push, .pull, .lower, .stretch]
            }
        case .fullBody:
            // С шести дней последний — растяжка, как в «Авто» (§7.2).
            return n >= 6 ? Array(repeating: .fullBody, count: n - 1) + [.stretch]
                          : Array(repeating: .fullBody, count: n)
        case .upperLower:
            switch n {
            // Один день — «Всё тело»: одна сессия верха или низа оставила бы
            // половину тела без работы на неделю (§7.2, «Где схема подменяется»).
            case 1: return [.fullBody]
            case 2: return [.upper, .lower]
            case 3: return [.upper, .lower, .fullBody]
            case 4: return [.upper, .lower, .upper, .lower]
            case 5: return [.upper, .lower, .upper, .lower, .fullBody]
            case 6: return [.upper, .lower, .upper, .lower, .upper, .stretch]
            default: return [.upper, .lower, .upper, .lower, .upper, .lower, .stretch]
            }
        case .pushPullLegs:
            switch n {
            case 1: return [.fullBody]
            // Два дня — «Верх тела / Низ тела»: жимовая и тяговая без дня низа
            // оставили бы ноги без нагрузки, а ротации между неделями нет (§7.2).
            case 2: return [.upper, .lower]
            case 3: return [.push, .pull, .lower]
            case 4: return [.push, .pull, .lower, .fullBody]
            case 5: return [.push, .pull, .lower, .upper, .lower]
            case 6: return [.push, .pull, .lower, .upper, .lower, .stretch]
            default: return [.push, .pull, .lower, .push, .pull, .lower, .stretch]
            }
        }
    }
}
