//  DTO ответов `/v1` (SPEC §20.3).
//
//  Успех — голое тело, без конверта: `/v1/content/*` обязан отдавать ровно те
//  байты, от которых считается ETag (§20.11), и конверт добавил бы к ним слой,
//  меняющийся вместе с версией сервера. Ветку «успех или ошибка» клиент берёт
//  из HTTP-статуса.

import FitCore

/// Строка `workout_exercises` до старта (§3.1, §7.6).
public struct PrescribedExerciseDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var orderIndex: Int
    public var targetSets: Int
    public var targetRepMin: Int
    public var targetRepMax: Int
    public var targetRIR: Int
    public var prescribedKg: Double?
    public var weightReadiness: Double

    enum CodingKeys: String, CodingKey {
        case slug, orderIndex = "order_index", targetSets = "target_sets",
             targetRepMin = "target_rep_min", targetRepMax = "target_rep_max",
             targetRIR = "target_rir", prescribedKg = "prescribed_kg",
             weightReadiness = "weight_readiness"
    }

    public init(_ e: PrescribedExercise) {
        slug = e.slug
        orderIndex = e.orderIndex
        targetSets = e.targetSets
        targetRepMin = e.targetRepMin
        targetRepMax = e.targetRepMax
        targetRIR = e.targetRIR
        prescribedKg = e.prescribedKg
        weightReadiness = e.weightReadiness
    }
}

/// Собранная тренировка (§7.3).
public struct BuiltSessionDTO: Sendable, Equatable, Codable {
    public var dayID: String
    public var exercises: [PrescribedExerciseDTO]
    public var estimatedSeconds: Double
    public var leadingMuscle: String?
    public var reasons: [ReasonDTO]

    enum CodingKeys: String, CodingKey {
        case dayID = "day_id", exercises, estimatedSeconds = "estimated_seconds",
             leadingMuscle = "leading_muscle", reasons
    }

    public init(_ s: BuiltSession) {
        dayID = s.dayID
        exercises = s.exercises.map(PrescribedExerciseDTO.init)
        estimatedSeconds = s.estimatedSeconds
        leadingMuscle = s.leadingMuscle?.rawValue
        reasons = s.reasons.map { ReasonDTO($0) }
    }
}

/// Итог дня недели (§7.1).
public struct DayOutcomeDTO: Sendable, Equatable, Codable {
    public var dayID: String
    public var kind: String
    public var cause: String?
    public var losesPlannedVolume: Bool
    public var session: BuiltSessionDTO?

    enum CodingKeys: String, CodingKey {
        case dayID = "day_id", kind, cause,
             losesPlannedVolume = "loses_planned_volume", session
    }

    public init(_ o: DayOutcome) {
        dayID = o.dayID
        switch o.kind {
        case .session: kind = "session"
        case .stretching: kind = "stretching"
        case .notBuilt: kind = "not_built"
        case .vectorMissing: kind = "vector_missing"
        case .generatorDisabled: kind = "generator_disabled"
        }
        cause = o.cause.map(ReasonDTO.code(for:))
        losesPlannedVolume = o.losesPlannedVolume
        session = o.session.map(BuiltSessionDTO.init)
    }
}

/// План недели (§20.3, `GET /v1/week-plans/{week_start}`).
public struct WeekPlanDTO: Sendable, Equatable, Codable {
    public var days: [DayOutcomeDTO]
    public var statusLines: [ReasonDTO]

    enum CodingKeys: String, CodingKey {
        case days, statusLines = "status_lines"
    }

    public init(_ plan: WeekPlan) {
        // Порядок — по `day_id`: словарь FitCore порядка не имеет, а ответ
        // обязан быть воспроизводимым, иначе диф двух ответов шумит на ровном
        // месте.
        days = plan.days.keys.sorted().compactMap { plan.days[$0] }.map(DayOutcomeDTO.init)
        statusLines = plan.statusLines.map { ReasonDTO($0) }
    }
}

/// Состояние цикла (§11.3). `cycle_confidence` едет всегда, когда он есть, —
/// §14.6 требует машиночитаемой неопределённости, и клиент обязан ей
/// воспользоваться независимо от готовых строк.
public struct CycleStateDTO: Sendable, Equatable, Codable {
    public var phaseMode: String
    public var noPhaseReason: String?
    public var hasAnchor: Bool
    /// `null`, если уверенность ниже порога §11.3 — на слабом сигнале
    /// интерфейс не вправе называть фазу, и сервер её не отдаёт.
    public var phase: String?
    public var cycleConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case phaseMode = "phase_mode", noPhaseReason = "no_phase_reason",
             hasAnchor = "has_anchor", phase, cycleConfidence = "cycle_confidence"
    }

    public init(_ state: CycleState) {
        phaseMode = state.phaseMode.rawValue
        noPhaseReason = state.noPhaseReason?.rawValue
        hasAnchor = state.hasAnchor
        let namable = (state.cycleConfidence ?? 0) >= ReasonStrings.phaseNamingThreshold
        phase = namable ? state.phase?.rawValue : nil
        cycleConfidence = state.cycleConfidence
    }
}

/// Альтернатива замены (§13.4), `GET .../alternatives`.
public struct ExerciseAlternativeDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var reasons: [ReasonDTO]

    public init(_ alternative: ExerciseAlternative) {
        slug = alternative.slug
        reasons = alternative.reasons.map { ReasonDTO($0) }
    }
}
