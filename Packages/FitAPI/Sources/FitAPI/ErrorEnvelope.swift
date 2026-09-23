//  Конверт ошибки и закрытый словарь кодов (SPEC §20.3).

/// Закрытый словарь `code` (§20.3). Новый код добавляется правкой §20.3, а не
/// решением в роуте; признак заведения — различимое поведение клиента, а не
/// различимая причина в логе.
public enum APIErrorCode: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case unauthorized
    case jwksUnavailable = "jwks_unavailable"
    case forbidden
    case notFound = "not_found"
    case dateSkew = "date_skew"
    case validationFailed = "validation_failed"
    case weekExists = "week_exists"
    case setIDRequired = "set_id_required"
    case setImmutable = "set_immutable"
    case workoutNotStarted = "workout_not_started"
    case workoutFinished = "workout_finished"
    case dayNotPlanned = "day_not_planned"
    case generatorDisabled = "generator_disabled"
    case `internal`

    /// HTTP-статус из таблицы §20.3. Держится рядом с кодом, чтобы роут не мог
    /// выбрать другой: пара (код, статус) — часть контракта, а не деталь
    /// обработчика.
    public var httpStatus: Int {
        switch self {
        case .unauthorized: return 401
        case .jwksUnavailable: return 503
        case .forbidden: return 403
        case .notFound: return 404
        case .dateSkew, .validationFailed, .setIDRequired: return 422
        case .weekExists, .setImmutable, .workoutNotStarted,
             .workoutFinished, .dayNotPlanned, .generatorDisabled: return 409
        case .internal: return 500
        }
    }
}

/// Значение внутри `details` — машиночитаемое и открытое, в отличие от `code`.
/// Пользовательнице не показывается никогда (§20.3), поэтому русского текста
/// здесь не бывает.
public enum APIDetailValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

/// `{"error": {"code", "message", "details"}}` (§20.3).
public struct APIErrorEnvelope: Sendable, Equatable, Codable {
    public struct Body: Sendable, Equatable, Codable {
        public var code: APIErrorCode
        public var message: String
        public var details: [String: APIDetailValue]?

        public init(code: APIErrorCode, message: String, details: [String: APIDetailValue]? = nil) {
            self.code = code
            self.message = message
            self.details = details
        }
    }

    public var error: Body

    public init(code: APIErrorCode, message: String? = nil, details: [String: APIDetailValue]? = nil) {
        self.error = Body(code: code, message: message ?? ReasonStrings.message(for: code), details: details)
    }
}
