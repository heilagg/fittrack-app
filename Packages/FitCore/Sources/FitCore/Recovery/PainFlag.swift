//  Флаг боли (SPEC §8.4). Немедленное прекращение упражнения и запись
//  `sets.pain_flag = true` (SPEC §3.1, п.1) — это состояние одного подхода,
//  которое пишет FitData/экран тренировки напрямую; Recovery в этом не
//  участвует. Здесь — только то, что требует памяти по истории событий:
//  исключение упражнения на 14 дней (п.3) и эскалация по 30-дневному окну
//  (п.4, п.5).

/// Один зафиксированный флаг боли — срез `sets` (`pain_flag = true`),
/// дополненный суставом с наибольшим `joint_stress` задействованного
/// упражнения на момент флага. Сам `joint_stress` — поле упражнения из
/// FitContent, от которого FitCore не зависит, поэтому сустав передаёт
/// вызывающая сторона, а не вычисляется здесь.
public struct PainEvent: Sendable, Equatable {
    public var exerciseSlug: String
    public var joint: Joint
    public var occurredOn: CalendarDay

    public init(exerciseSlug: String, joint: Joint, occurredOn: CalendarDay) {
        self.exerciseSlug = exerciseSlug
        self.joint = joint
        self.occurredOn = occurredOn
    }
}

/// Мягкое предложение пользователю по итогам эскалации (SPEC §8.4, п.4–5).
/// Ни один из вариантов не блокирует и не применяет ограничение сам —
/// решение остаётся за пользователем (SPEC §8.4 читается в связке с §8.2:
/// «не блокируем»).
public enum PainEscalation: Sendable, Equatable {
    case suggestPermanentRestriction(exerciseSlug: String)
    case suggestSpecialist(joint: Joint)
}

extension Recovery {
    /// SPEC §8.4, п.3.
    public static let painExclusionDays = 14
    /// SPEC §8.4, п.4–5.
    public static let painEscalationWindowDays = 30

    /// SPEC §8.4, п.3: упражнение исключается из подбора на 14 дней после
    /// флага боли на нём. Границу дня 14 включаем (симметрично с §8.4,
    /// который не уточняет — окно «на 14 дней» естественнее читать как
    /// включающее, чем как «13 полных дней»).
    public static func isExcluded(exerciseSlug: String, from events: [PainEvent], asOf today: CalendarDay) -> Bool {
        events.contains { event in
            event.exerciseSlug == exerciseSlug
                && isWithin(event.occurredOn, of: today, days: painExclusionDays)
        }
    }

    /// SPEC §8.4, п.4–5: эскалации за последние 30 дней. Порядок вывода
    /// детерминирован (сортировка по слагу/суставу) — источник, `events`,
    /// такой гарантии не даёт.
    public static func escalations(from events: [PainEvent], asOf today: CalendarDay) -> [PainEscalation] {
        let recent = events.filter { isWithin($0.occurredOn, of: today, days: painEscalationWindowDays) }

        // п.4: флаг боли по одному упражнению повторяется 2 раза за 30 дней.
        let restrictionSlugs = Dictionary(grouping: recent, by: \.exerciseSlug)
            .filter { $0.value.count >= 2 }
            .keys.sorted()

        // п.5: флаг боли по разным упражнениям с одним joint_stress-суставом
        // 3 раза за 30 дней — «разным» проверяем через количество различных
        // exercise_slug, а не общее число событий (иначе совпало бы с п.4
        // при повторной боли в одном и том же упражнении).
        let specialistJoints = Dictionary(grouping: recent, by: \.joint)
            .filter { Set($0.value.map(\.exerciseSlug)).count >= 3 }
            .keys.sorted { $0.rawValue < $1.rawValue }

        return restrictionSlugs.map { .suggestPermanentRestriction(exerciseSlug: $0) }
            + specialistJoints.map { .suggestSpecialist(joint: $0) }
    }

    private static func isWithin(_ day: CalendarDay, of today: CalendarDay, days: Int) -> Bool {
        let elapsed = day.days(until: today)
        return elapsed >= 0 && elapsed <= days
    }
}
