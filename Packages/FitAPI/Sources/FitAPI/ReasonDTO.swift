//  `ReasonCode` на проводе: `{code, params, message}` (SPEC §20.3).
//
//  Всё написано руками, и это главное свойство файла. Синтезированная Codable
//  для enum с ассоциированными значениями привязала бы `code` и имена полей к
//  именам случаев в Swift — переименование в ядре молча сменило бы контракт у
//  двух развёрнутых клиентов (§20.8). Здесь каждый `code` — отдельная строковая
//  константа, и переименование случая ломает компиляцию, а не проволочный
//  формат.
//
//  `params` — объект с именованными полями СВОЕГО случая, а не общий мешок:
//  у каждого кода свой набор ключей, и во фронтенде это размеченное
//  объединение по `code`. Отсюда же требование §14.6: `cycle_confidence`
//  лежит в `params` у ВСЯКОЙ причины фазового происхождения, включая
//  вложенные в `plan_rebuilt`.

import FitCore

public struct ReasonDTO: Sendable, Equatable {
    public var reason: ReasonCode
    /// Готовая русская формулировка (§20.3). Пустой строки здесь не бывает:
    /// каталог обязан покрывать все случаи, и это проверяется тестом.
    public var message: String

    public init(_ reason: ReasonCode, message: String? = nil) {
        self.reason = reason
        self.message = message ?? ReasonStrings.message(for: reason)
    }
}

// MARK: - Коды

extension ReasonDTO {
    /// Строковый код случая. Значения фиксированы контрактом и не выводятся из
    /// имён случаев Swift.
    public static func code(for reason: ReasonCode) -> String {
        switch reason {
        case .phasePeriodization: return "phase_periodization"
        case .ovulatoryImpactCaution: return "ovulatory_impact_caution"
        case .patternMinimumRelaxedUnavailable: return "pattern_minimum_relaxed_unavailable"
        case .patternMinimumRelaxedByTime: return "pattern_minimum_relaxed_by_time"
        case .patternMinimumRelaxedByLimit: return "pattern_minimum_relaxed_by_limit"
        case .planRebuilt: return "plan_rebuilt"
        case .plannedVolumeLoss: return "planned_volume_loss"
        case .weekShortfallByTime: return "week_shortfall_by_time"
        case .workoutGenerationDisabled: return "workout_generation_disabled"
        case .noFeasibleExercises: return "no_feasible_exercises"
        case .dayVectorMissing: return "day_vector_missing"
        case .substitutionKeepsLeadingMuscle: return "substitution_keeps_leading_muscle"
        case .substitutionRelievesJoint: return "substitution_relieves_joint"
        }
    }

    public static func code(for cause: RebuildCause) -> String {
        switch cause {
        case .phaseChanged: return "phase_changed"
        case .cycleConfidenceChanged: return "cycle_confidence_changed"
        case .workoutSkipped: return "workout_skipped"
        case .workoutCompleted: return "workout_completed"
        case .override: return "override"
        case .dayEdited: return "day_edited"
        case .equipmentChanged: return "equipment_changed"
        }
    }

    static func code(for limit: PatternLimit) -> String {
        switch limit {
        case .exerciseCount: return "exercise_count"
        case .family: return "family"
        }
    }

    static func code(for cause: DayOutcome.Cause) -> String {
        switch cause {
        case .restOverride: return "rest_override"
        case .skipped: return "skipped"
        case .replaced: return "replaced"
        case .started: return "started"
        case .done: return "done"
        case .past: return "past"
        case .gridStretch: return "grid_stretch"
        case .markupMissing: return "markup_missing"
        case .pregnancy: return "pregnancy"
        }
    }

    static func patternLimit(_ code: String) -> PatternLimit? {
        switch code {
        case "exercise_count": return .exerciseCount
        case "family": return .family
        default: return nil
        }
    }

    static func dayCause(_ code: String) -> DayOutcome.Cause? {
        switch code {
        case "rest_override": return .restOverride
        case "skipped": return .skipped
        case "replaced": return .replaced
        case "started": return .started
        case "done": return .done
        case "past": return .past
        case "grid_stretch": return .gridStretch
        case "markup_missing": return .markupMissing
        case "pregnancy": return .pregnancy
        default: return nil
        }
    }
}

// MARK: - Кодирование

extension ReasonDTO: Codable {
    enum Key: String, CodingKey { case code, params, message }

    /// Все ключи, какие встречаются в `params` любого случая. Общий список — не
    /// общий мешок: какие из них присутствуют, однозначно определено кодом.
    enum ParamKey: String, CodingKey {
        case phase, cycleConfidence = "cycle_confidence"
        case available, fitted, limit
        case cause, muscle, sets, kind, accent
        case joint, from, to
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(Self.code(for: reason), forKey: .code)
        try c.encode(message, forKey: .message)
        var p = c.nestedContainer(keyedBy: ParamKey.self, forKey: .params)
        switch reason {
        case .phasePeriodization(let phase, let confidence):
            try p.encode(phase.rawValue, forKey: .phase)
            try p.encode(confidence, forKey: .cycleConfidence)
        case .ovulatoryImpactCaution(let confidence):
            try p.encode(confidence, forKey: .cycleConfidence)
        case .patternMinimumRelaxedUnavailable(let available):
            try p.encode(available, forKey: .available)
        case .patternMinimumRelaxedByTime(let fitted):
            try p.encode(fitted, forKey: .fitted)
        case .patternMinimumRelaxedByLimit(let fitted, let limit):
            try p.encode(fitted, forKey: .fitted)
            try p.encode(Self.code(for: limit), forKey: .limit)
        case .planRebuilt(let cause):
            try p.encode(RebuildCauseDTO(cause), forKey: .cause)
        case .plannedVolumeLoss(let muscle, let sets, let cause):
            try p.encode(muscle.rawValue, forKey: .muscle)
            try p.encode(sets, forKey: .sets)
            try p.encode(Self.code(for: cause), forKey: .cause)
        case .weekShortfallByTime(let muscle, let sets):
            try p.encode(muscle.rawValue, forKey: .muscle)
            try p.encode(sets, forKey: .sets)
        case .workoutGenerationDisabled, .noFeasibleExercises:
            break
        case .dayVectorMissing(let kind, let accent):
            try p.encode(kind.rawValue, forKey: .kind)
            try p.encodeIfPresent(accent?.rawValue, forKey: .accent)
        case .substitutionKeepsLeadingMuscle(let muscle):
            try p.encode(muscle.rawValue, forKey: .muscle)
        case .substitutionRelievesJoint(let joint, let from, let to):
            try p.encode(joint.rawValue, forKey: .joint)
            try p.encode(from.rawValue, forKey: .from)
            try p.encodeIfPresent(to?.rawValue, forKey: .to)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let code = try c.decode(String.self, forKey: .code)
        let p = try c.nestedContainer(keyedBy: ParamKey.self, forKey: .params)

        func fail(_ what: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: .params, in: c,
                                             debugDescription: "\(code): \(what)")
        }
        func muscle(_ key: ParamKey) throws -> MuscleSlug {
            guard let m = MuscleSlug(rawValue: try p.decode(String.self, forKey: key))
            else { throw fail("неизвестный слаг мышцы") }
            return m
        }

        switch code {
        case "phase_periodization":
            guard let phase = Phase(rawValue: try p.decode(String.self, forKey: .phase))
            else { throw fail("неизвестная фаза") }
            reason = .phasePeriodization(phase: phase,
                                         cycleConfidence: try p.decode(Double.self, forKey: .cycleConfidence))
        case "ovulatory_impact_caution":
            reason = .ovulatoryImpactCaution(cycleConfidence: try p.decode(Double.self, forKey: .cycleConfidence))
        case "pattern_minimum_relaxed_unavailable":
            reason = .patternMinimumRelaxedUnavailable(available: try p.decode(Int.self, forKey: .available))
        case "pattern_minimum_relaxed_by_time":
            reason = .patternMinimumRelaxedByTime(fitted: try p.decode(Int.self, forKey: .fitted))
        case "pattern_minimum_relaxed_by_limit":
            guard let limit = Self.patternLimit(try p.decode(String.self, forKey: .limit))
            else { throw fail("неизвестный лимит сборки") }
            reason = .patternMinimumRelaxedByLimit(fitted: try p.decode(Int.self, forKey: .fitted), limit: limit)
        case "plan_rebuilt":
            reason = .planRebuilt(cause: try p.decode(RebuildCauseDTO.self, forKey: .cause).cause)
        case "planned_volume_loss":
            guard let cause = Self.dayCause(try p.decode(String.self, forKey: .cause))
            else { throw fail("неизвестная причина потери объёма") }
            reason = .plannedVolumeLoss(muscle: try muscle(.muscle),
                                        sets: try p.decode(Int.self, forKey: .sets), cause: cause)
        case "week_shortfall_by_time":
            reason = .weekShortfallByTime(muscle: try muscle(.muscle),
                                          sets: try p.decode(Int.self, forKey: .sets))
        case "workout_generation_disabled":
            reason = .workoutGenerationDisabled
        case "no_feasible_exercises":
            reason = .noFeasibleExercises
        case "day_vector_missing":
            guard let kind = SessionKind(rawValue: try p.decode(String.self, forKey: .kind))
            else { throw fail("неизвестный тип дня") }
            var accent: MuscleSlug?
            if let raw = try p.decodeIfPresent(String.self, forKey: .accent) {
                guard let m = MuscleSlug(rawValue: raw) else { throw fail("неизвестный слаг акцента") }
                accent = m
            }
            reason = .dayVectorMissing(kind: kind, accent: accent)
        case "substitution_keeps_leading_muscle":
            reason = .substitutionKeepsLeadingMuscle(muscle: try muscle(.muscle))
        case "substitution_relieves_joint":
            guard let joint = Joint(rawValue: try p.decode(String.self, forKey: .joint)),
                  let from = JointStressLevel(rawValue: try p.decode(String.self, forKey: .from))
            else { throw fail("неизвестный сустав или степень нагрузки") }
            var to: JointStressLevel?
            if let raw = try p.decodeIfPresent(String.self, forKey: .to) {
                guard let level = JointStressLevel(rawValue: raw) else { throw fail("неизвестная степень нагрузки") }
                to = level
            }
            reason = .substitutionRelievesJoint(joint: joint, from: from, to: to)
        default:
            throw DecodingError.dataCorruptedError(forKey: .code, in: c,
                                                   debugDescription: "неизвестный код причины: \(code)")
        }
        message = try c.decode(String.self, forKey: .message)
    }
}

/// Вложенная причина пересборки — такой же объект `{code, params, message}`,
/// как и внешняя (§20.3). Отдельный тип, потому что `RebuildCause` — отдельный
/// enum ядра, а не случай `ReasonCode`.
public struct RebuildCauseDTO: Sendable, Equatable, Codable {
    public var cause: RebuildCause
    public var message: String

    public init(_ cause: RebuildCause, message: String? = nil) {
        self.cause = cause
        self.message = message ?? ReasonStrings.message(for: cause)
    }

    enum Key: String, CodingKey { case code, params, message }
    enum ParamKey: String, CodingKey { case phase, cycleConfidence = "cycle_confidence" }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(ReasonDTO.code(for: cause), forKey: .code)
        try c.encode(message, forKey: .message)
        var p = c.nestedContainer(keyedBy: ParamKey.self, forKey: .params)
        switch cause {
        case .phaseChanged(let phase, let confidence):
            try p.encodeIfPresent(phase?.rawValue, forKey: .phase)
            try p.encodeIfPresent(confidence, forKey: .cycleConfidence)
        case .cycleConfidenceChanged(let confidence):
            try p.encodeIfPresent(confidence, forKey: .cycleConfidence)
        case .workoutSkipped, .workoutCompleted, .override, .dayEdited, .equipmentChanged:
            break
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let code = try c.decode(String.self, forKey: .code)
        let p = try c.nestedContainer(keyedBy: ParamKey.self, forKey: .params)
        func phase() throws -> Phase? {
            guard let raw = try p.decodeIfPresent(String.self, forKey: .phase) else { return nil }
            guard let phase = Phase(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .phase, in: p,
                                                       debugDescription: "неизвестная фаза")
            }
            return phase
        }
        switch code {
        case "phase_changed":
            cause = .phaseChanged(phase: try phase(),
                                  cycleConfidence: try p.decodeIfPresent(Double.self, forKey: .cycleConfidence))
        case "cycle_confidence_changed":
            cause = .cycleConfidenceChanged(cycleConfidence: try p.decodeIfPresent(Double.self, forKey: .cycleConfidence))
        case "workout_skipped": cause = .workoutSkipped
        case "workout_completed": cause = .workoutCompleted
        case "override": cause = .override
        case "day_edited": cause = .dayEdited
        case "equipment_changed": cause = .equipmentChanged
        default:
            throw DecodingError.dataCorruptedError(forKey: .code, in: c,
                                                   debugDescription: "неизвестная причина пересборки: \(code)")
        }
        message = try c.decode(String.self, forKey: .message)
    }
}
