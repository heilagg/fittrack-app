//  Недельная сетка (SPEC §7.2) и запись дня недели, которую читают сборка и
//  пересборка. Сетка зависит только от выбранных дней и уровня: цель, фаза,
//  утомление и прошлый объём действуют в сборке, не в расстановке.

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
    public static func weekGrid(days: [CalendarDay], level: ExperienceLevel) -> [GridSlot] {
        let sorted = Set(days).sorted()
        let kinds: [SessionKind]
        switch sorted.count {
        case 0: kinds = []
        case 1, 2: kinds = Array(repeating: .fullBody, count: sorted.count)
        case 3: kinds = level == .novice ? [.fullBody, .fullBody, .fullBody] : [.upper, .lower, .fullBody]
        case 4: kinds = [.upper, .lower, .upper, .lower]
        case 5: kinds = [.upper, .lower, .upper, .lower, .fullBody]
        case 6: kinds = [.push, .pull, .lower, .upper, .lower, .stretch]
        default: kinds = [.push, .pull, .lower, .push, .pull, .lower, .stretch]
        }
        return zip(sorted, kinds).map { GridSlot(date: $0, kind: $1) }
    }
}
