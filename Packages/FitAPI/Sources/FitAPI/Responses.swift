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
    /// Ветка показа, закрытый словарь §20.3: `session`, `stretching`,
    /// `not_built`, `vector_missing`, `generator_disabled`. Строкой, а не
    /// конвертом причины: это не причина, а то, что рисовать, и формулировки у
    /// неё нет.
    public var kind: String
    /// Причина — полным конвертом `{code, params, message}` (§20.3): её видит
    /// пользовательница, и формулировку отдаёт сервер.
    public var cause: DayCauseDTO?
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
        cause = o.cause.map { DayCauseDTO($0) }
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

// MARK: - Тела успешных ответов (§20.3)

/// Карточка дня, `GET /v1/today` (§13.1).
public struct TodayCardDTO: Sendable, Equatable, Codable {
    /// Локальная дата клиента, на которую посчитана карточка (§20.7).
    public var date: String
    /// Дневная готовность §10 — не `weight_readiness` упражнения (§7.6).
    public var readiness: Double
    public var cycle: CycleStateDTO
    public var day: DayOutcomeDTO
    /// Причины уровня дня; причины сборки лежат внутри `day.session`.
    public var reasons: [ReasonDTO]

    public init(date: String, readiness: Double, cycle: CycleStateDTO,
                day: DayOutcomeDTO, reasons: [ReasonDTO] = []) {
        self.date = date
        self.readiness = readiness
        self.cycle = cycle
        self.day = day
        self.reasons = reasons
    }
}

/// Ответ всех четырёх недельных путей (§20.3): `GET`, генерация, правка дня,
/// пересборка. Один тип на четыре, потому что ответ у них один и тот же —
/// неделя, — и различаются они только тем, есть ли что сказать про изменение.
public struct WeekPlanResponseDTO: Sendable, Equatable, Codable {
    public var plan: WeekPlanDTO
    /// «План обновлён» (§7.1). `null` там, где сравнивать не с чем (первая
    /// генерация, `last_shown_plan` пуст) или где ничего не изменилось —
    /// молчаливая пересборка §7.1 недопустима, но и строка без изменения тоже.
    public var notice: ReasonDTO?

    public init(plan: WeekPlanDTO, notice: ReasonDTO? = nil) {
        self.plan = plan
        self.notice = notice
    }
}

/// Строка `sets` (§3.1) наружу.
public struct SetDTO: Sendable, Equatable, Codable {
    public var id: String
    public var setIndex: Int
    public var prescribedKg: Double?
    public var prescribedReps: Int
    public var actualKg: Double?
    public var actualReps: Int?
    public var feedback: Feedback?
    public var painFlag: Bool
    /// Суставы события боли (§8.4 п.5), зафиксированные на момент события.
    public var painJoints: [Joint]
    public var restSeconds: Int?
    /// Настоящий момент, ISO 8601 с зоной, — не значение шкалы FitCore (§20.7).
    public var completedAt: String?
    public var skipped: Bool

    enum CodingKeys: String, CodingKey {
        case id, setIndex = "set_index", prescribedKg = "prescribed_kg",
             prescribedReps = "prescribed_reps", actualKg = "actual_kg",
             actualReps = "actual_reps", feedback, painFlag = "pain_flag",
             painJoints = "pain_joints", restSeconds = "rest_seconds",
             completedAt = "completed_at", skipped
    }

    public init(id: String, setIndex: Int, prescribedKg: Double? = nil, prescribedReps: Int,
                actualKg: Double? = nil, actualReps: Int? = nil, feedback: Feedback? = nil,
                painFlag: Bool = false, painJoints: [Joint] = [], restSeconds: Int? = nil,
                completedAt: String? = nil, skipped: Bool = false) {
        self.id = id
        self.setIndex = setIndex
        self.prescribedKg = prescribedKg
        self.prescribedReps = prescribedReps
        self.actualKg = actualKg
        self.actualReps = actualReps
        self.feedback = feedback
        self.painFlag = painFlag
        self.painJoints = painJoints
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.skipped = skipped
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        setIndex = try c.decode(Int.self, forKey: .setIndex)
        prescribedKg = try c.decodeIfPresent(Double.self, forKey: .prescribedKg)
        prescribedReps = try c.decode(Int.self, forKey: .prescribedReps)
        actualKg = try c.decodeIfPresent(Double.self, forKey: .actualKg)
        actualReps = try c.decodeIfPresent(Int.self, forKey: .actualReps)
        feedback = try c.decodeRawIfPresent(Feedback.self, forKey: .feedback)
        painFlag = try c.decodeIfPresent(Bool.self, forKey: .painFlag) ?? false
        painJoints = try c.decodeRawArrayIfPresent(Joint.self, forKey: .painJoints) ?? []
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(setIndex, forKey: .setIndex)
        try c.encodeIfPresent(prescribedKg, forKey: .prescribedKg)
        try c.encode(prescribedReps, forKey: .prescribedReps)
        try c.encodeIfPresent(actualKg, forKey: .actualKg)
        try c.encodeIfPresent(actualReps, forKey: .actualReps)
        try c.encodeRawIfPresent(feedback, forKey: .feedback)
        try c.encode(painFlag, forKey: .painFlag)
        try c.encodeRawArray(painJoints, forKey: .painJoints)
        try c.encodeIfPresent(restSeconds, forKey: .restSeconds)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(skipped, forKey: .skipped)
    }
}

/// Строка `workout_exercises` (§3.1) наружу, с подходами и деревом.
public struct WorkoutExerciseDTO: Sendable, Equatable, Codable {
    public var id: String
    public var slug: String
    public var orderIndex: Int
    public var targetSets: Int
    public var targetRepMin: Int
    public var targetRepMax: Int
    public var targetRIR: Int
    public var prescribedKg: Double?
    public var weightReadiness: Double
    /// Было ли ЭТО упражнение в калибровке на момент старта (§9.8): снимок
    /// `exercise_states.in_calibration`, а не флаг тренировки.
    public var isCalibration: Bool
    public var substitutedFrom: String?
    public var substitutionReason: SubstitutionReason?
    /// Дерево §20.9 — поле упражнения, а не отдельная карта: строится оно от
    /// веса и остатка подходов именно этого упражнения. `nil` у не начатого
    /// дня: дерева там ещё не существует.
    public var decisionTree: DecisionTreeDTO?
    public var sets: [SetDTO]

    enum CodingKeys: String, CodingKey {
        case id, slug, orderIndex = "order_index", targetSets = "target_sets",
             targetRepMin = "target_rep_min", targetRepMax = "target_rep_max",
             targetRIR = "target_rir", prescribedKg = "prescribed_kg",
             weightReadiness = "weight_readiness", isCalibration = "is_calibration",
             substitutedFrom = "substituted_from", substitutionReason = "substitution_reason",
             decisionTree = "decision_tree", sets
    }

    public init(id: String, prescribed: PrescribedExercise, isCalibration: Bool,
                substitutedFrom: String? = nil, substitutionReason: SubstitutionReason? = nil,
                decisionTree: DecisionTreeDTO? = nil, sets: [SetDTO] = []) {
        self.id = id
        self.slug = prescribed.slug
        self.orderIndex = prescribed.orderIndex
        self.targetSets = prescribed.targetSets
        self.targetRepMin = prescribed.targetRepMin
        self.targetRepMax = prescribed.targetRepMax
        self.targetRIR = prescribed.targetRIR
        self.prescribedKg = prescribed.prescribedKg
        self.weightReadiness = prescribed.weightReadiness
        self.isCalibration = isCalibration
        self.substitutedFrom = substitutedFrom
        self.substitutionReason = substitutionReason
        self.decisionTree = decisionTree
        self.sets = sets
    }
}

/// Тренировка целиком: `GET /v1/workouts/{id}`, `POST /v1/workouts`,
/// `POST /v1/workouts/{id}/finish` (§20.3).
public struct WorkoutDTO: Sendable, Equatable, Codable {
    public var id: String
    public var plannedDayID: String?
    public var sessionKind: SessionKind
    public var accentMuscle: MuscleSlug?
    /// Настоящие моменты, ISO 8601 с зоной (§20.7).
    public var startedAt: String
    public var finishedAt: String?
    /// Дневная готовность §10 на момент старта.
    public var readiness: Double
    public var cyclePhase: Phase?
    public var cycleConfidence: Double?
    /// Флаг тренировки — баннер §9.8 и аналитика. Расчётным он не является:
    /// подходы из утомления исключает `WorkoutExerciseDTO.isCalibration`.
    public var isCalibration: Bool
    public var exercises: [WorkoutExerciseDTO]

    enum CodingKeys: String, CodingKey {
        case id, plannedDayID = "planned_day_id", sessionKind = "session_kind",
             accentMuscle = "accent_muscle", startedAt = "started_at",
             finishedAt = "finished_at", readiness, cyclePhase = "cycle_phase",
             cycleConfidence = "cycle_confidence", isCalibration = "is_calibration", exercises
    }

    public init(id: String, plannedDayID: String?, sessionKind: SessionKind,
                accentMuscle: MuscleSlug? = nil, startedAt: String, finishedAt: String? = nil,
                readiness: Double, cyclePhase: Phase? = nil, cycleConfidence: Double? = nil,
                isCalibration: Bool = false, exercises: [WorkoutExerciseDTO] = []) {
        self.id = id
        self.plannedDayID = plannedDayID
        self.sessionKind = sessionKind
        self.accentMuscle = accentMuscle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.readiness = readiness
        self.cyclePhase = cyclePhase
        self.cycleConfidence = cycleConfidence
        self.isCalibration = isCalibration
        self.exercises = exercises
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        plannedDayID = try c.decodeIfPresent(String.self, forKey: .plannedDayID)
        sessionKind = try c.decodeRaw(SessionKind.self, forKey: .sessionKind)
        accentMuscle = try c.decodeRawIfPresent(MuscleSlug.self, forKey: .accentMuscle)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        readiness = try c.decode(Double.self, forKey: .readiness)
        cyclePhase = try c.decodeRawIfPresent(Phase.self, forKey: .cyclePhase)
        cycleConfidence = try c.decodeIfPresent(Double.self, forKey: .cycleConfidence)
        isCalibration = try c.decodeIfPresent(Bool.self, forKey: .isCalibration) ?? false
        exercises = try c.decodeIfPresent([WorkoutExerciseDTO].self, forKey: .exercises) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(plannedDayID, forKey: .plannedDayID)
        try c.encodeRaw(sessionKind, forKey: .sessionKind)
        try c.encodeRawIfPresent(accentMuscle, forKey: .accentMuscle)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encode(readiness, forKey: .readiness)
        try c.encodeRawIfPresent(cyclePhase, forKey: .cyclePhase)
        try c.encodeIfPresent(cycleConfidence, forKey: .cycleConfidence)
        try c.encode(isCalibration, forKey: .isCalibration)
        try c.encode(exercises, forKey: .exercises)
    }
}

/// Ответ `POST /v1/workouts/{id}/exercises/{we_id}/sets` (§20.3).
///
/// **Только дерево, без готового следующего подхода.** Клиент уже применил
/// ветку мгновенно — ради этого §20.9 и существует, — и готовый подход стал бы
/// вторым источником того же числа: разойдясь с показанным, он менял бы цифру
/// после того, как пользовательница её увидела и приняла. Досрочное завершение
/// упражнения (§9.3) клиент читает оттуда же — из узла с `terminates`.
public struct LogSetResponseDTO: Sendable, Equatable, Codable {
    public var decisionTree: DecisionTreeDTO

    enum CodingKeys: String, CodingKey { case decisionTree = "decision_tree" }

    public init(decisionTree: DecisionTreeDTO) {
        self.decisionTree = decisionTree
    }
}
