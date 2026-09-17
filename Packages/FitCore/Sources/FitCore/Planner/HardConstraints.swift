//  Жёсткие ограничения подбора, которые проверяются по одному упражнению
//  (SPEC §7.3): инвентарь, травмы, флаги боли, skill_level, консервативный
//  режим. Безопасность не ослабляется никогда — ни фазой, ни нехваткой времени.
//  Ограничения на набор (паттерны, семьи, время, потолок) живут в SessionBuilder.

/// `user_restrictions.severity` (SPEC §3.1, §14.4).
public enum RestrictionSeverity: String, Sendable, Equatable, Hashable {
    case avoid
    case careful
}

/// Активное ограничение по суставу (`resolved_at is null`, §3.1). Снятые
/// ограничения вызывающая сторона не передаёт.
public struct UserRestriction: Sendable, Equatable, Hashable {
    public var joint: Joint
    public var severity: RestrictionSeverity

    public init(joint: Joint, severity: RestrictionSeverity) {
        self.joint = joint
        self.severity = severity
    }
}

/// Профиль безопасности и уровня пользователя — то, что отсекает упражнения
/// до любого score.
public struct SafetyProfile: Sendable, Equatable {
    public var level: ExperienceLevel
    public var restrictions: [UserRestriction]
    public var painEvents: [PainEvent]
    /// Красный флаг PAR-Q (§14.1).
    public var isConservative: Bool

    public init(
        level: ExperienceLevel,
        restrictions: [UserRestriction] = [],
        painEvents: [PainEvent] = [],
        isConservative: Bool = false
    ) {
        self.level = level
        self.restrictions = restrictions
        self.painEvents = painEvents
        self.isConservative = isConservative
    }
}

extension Planner {
    /// Проходит ли упражнение все жёсткие ограничения §7.3 на день `day`.
    public static func passesHardConstraints(
        _ candidate: ExerciseCandidate,
        safety: SafetyProfile,
        availability: EquipmentAvailability,
        equipment: EquipmentProfile,
        on day: CalendarDay
    ) -> Bool {
        guard isFeasible(candidate, availability: availability, equipment: equipment) else { return false }

        // §14.4: avoid исключает medium и high, careful — только high.
        for restriction in safety.restrictions {
            guard let stress = candidate.jointStress[restriction.joint] else { continue }
            switch restriction.severity {
            case .avoid where stress >= .medium: return false
            case .careful where stress == .high: return false
            default: break
            }
        }

        // §8.4: флаг боли исключает само упражнение на 14 дней включительно.
        if Recovery.isExcluded(exerciseSlug: candidate.slug, from: safety.painEvents, asOf: day) {
            return false
        }

        // §7.3 и §14.1: skill_level ≤ уровня; в консервативном режиме потолок —
        // novice и исключается любой joint_stress: high.
        let skillCap: ExperienceLevel = safety.isConservative ? .novice : safety.level
        guard candidate.skillLevel <= skillCap else { return false }
        if safety.isConservative, candidate.jointStress.values.contains(.high) { return false }

        return true
    }
}
