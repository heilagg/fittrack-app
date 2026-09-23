//  Тела запросов `/v1` (SPEC §20.3).
//
//  `date` и `tz` есть почти везде не по инерции: §20.7 требует их всюду, где
//  день имеет значение, и сервер валидирует их до любой записи — присланная
//  дата, расходящаяся с серверной больше чем на сутки, даёт `date_skew` (20d).

import FitCore

/// Локальный день и зона клиента (§20.7).
public struct DayContext: Sendable, Equatable, Codable {
    /// Локальная дата клиента, ISO `yyyy-mm-dd`.
    public var date: String
    /// IANA-зона, например `Europe/Moscow`.
    public var tz: String

    public init(date: String, tz: String) {
        self.date = date
        self.tz = tz
    }
}

/// `POST /v1/week-plans`. Конкретные дни недели в теле НЕ принимаются — сервер
/// берёт их из `profiles.training_weekdays` (§20.3, §7.2).
public struct GenerateWeekPlanRequest: Sendable, Equatable, Codable {
    /// Понедельник недели, ISO `yyyy-mm-dd`. Принимаются текущая и ближайшая
    /// следующая (§20.3).
    public var weekStart: String
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start", date, tz
    }

    public init(weekStart: String, day: DayContext) {
        self.weekStart = weekStart
        self.date = day.date
        self.tz = day.tz
    }
}

/// `PATCH /v1/week-plans/{week_start}/days/{day_id}` — акцент, тип дня и
/// отметка статуса (§20.3). Причину пересборки (`dayEdited`) проставляет
/// сервер, клиент её не называет.
public struct PatchPlannedDayRequest: Sendable, Equatable, Codable {
    public var accentMuscle: MuscleSlug??
    public var sessionKind: SessionKind?
    public var status: PlannedDayStatus?
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case accentMuscle = "accent_muscle", sessionKind = "session_kind", status, date, tz
    }

    public init(accentMuscle: MuscleSlug?? = nil, sessionKind: SessionKind? = nil,
                status: PlannedDayStatus? = nil, day: DayContext) {
        self.accentMuscle = accentMuscle
        self.sessionKind = sessionKind
        self.status = status
        self.date = day.date
        self.tz = day.tz
    }

    // Двойная опциональность `accentMuscle` несущая: отсутствие ключа означает
    // «не трогать», явный null — «снять акцент». Снятие акцента — плановое
    // решение (§7.2), и отличать его от «поле не прислали» обязательно.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accentMuscle = c.contains(.accentMuscle)
            ? .some(try c.decodeRawIfPresent(MuscleSlug.self, forKey: .accentMuscle))
            : nil
        sessionKind = try c.decodeRawIfPresent(SessionKind.self, forKey: .sessionKind)
        status = try c.decodeRawIfPresent(PlannedDayStatus.self, forKey: .status)
        date = try c.decode(String.self, forKey: .date)
        tz = try c.decode(String.self, forKey: .tz)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let accentMuscle { try c.encodeRawIfPresent(accentMuscle, forKey: .accentMuscle) }
        try c.encodeRawIfPresent(sessionKind, forKey: .sessionKind)
        try c.encodeRawIfPresent(status, forKey: .status)
        try c.encode(date, forKey: .date)
        try c.encode(tz, forKey: .tz)
    }
}

/// Причина пересборки, которую вправе назвать клиент (§20.3). Только две:
/// остальные триггеры §7.1 — собственные эндпоинты сервера, и он наблюдает их
/// сам. Эти две происходят мимо него, потому что `equipment_profiles` и
/// `cycle_events` фронтенд пишет напрямую (§20.6).
public enum ClientRebuildCause: String, Sendable, Equatable, CaseIterable, Codable {
    case equipmentChanged = "equipment_changed"
    case cycleEventAdded = "cycle_event_added"
}

/// `POST /v1/week-plans/{week_start}/rebuild`.
public struct RebuildWeekPlanRequest: Sendable, Equatable, Codable {
    public var cause: ClientRebuildCause
    public var date: String
    public var tz: String

    public init(cause: ClientRebuildCause, day: DayContext) {
        self.cause = cause
        self.date = day.date
        self.tz = day.tz
    }
}

/// `POST /v1/workouts`.
public struct StartWorkoutRequest: Sendable, Equatable, Codable {
    public var plannedDayID: String
    /// `nil` — берётся профиль с `is_default` (§20.3).
    public var equipmentProfileID: String?
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case plannedDayID = "planned_day_id", equipmentProfileID = "equipment_profile_id", date, tz
    }

    public init(plannedDayID: String, equipmentProfileID: String? = nil, day: DayContext) {
        self.plannedDayID = plannedDayID
        self.equipmentProfileID = equipmentProfileID
        self.date = day.date
        self.tz = day.tz
    }
}

/// `POST /v1/workouts/{id}/exercises/{we_id}/sets`.
///
/// `id` обязателен и генерируется клиентом ДО отправки (§20.6): это и есть
/// механизм идемпотентности 20e. Тело без `id` отклоняется кодом
/// `set_id_required`, а не получает ключ от сервера — сгенерированный сервером
/// ключ снял бы саму возможность отличить ретрай от нового подхода.
public struct LogSetRequest: Sendable, Equatable, Codable {
    public var id: String
    public var setIndex: Int
    public var prescribedKg: Double?
    public var prescribedReps: Int
    public var actualKg: Double?
    public var actualReps: Int?
    public var feedback: Feedback?
    public var painFlag: Bool
    public var restSeconds: Int?
    /// Момент завершения подхода, ISO 8601 с зоной. Настоящий момент, не
    /// значение шкалы FitCore (§20.7).
    public var completedAt: String?
    public var skipped: Bool
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case id, setIndex = "set_index", prescribedKg = "prescribed_kg",
             prescribedReps = "prescribed_reps", actualKg = "actual_kg",
             actualReps = "actual_reps", feedback, painFlag = "pain_flag",
             restSeconds = "rest_seconds", completedAt = "completed_at",
             skipped, date, tz
    }

    public init(id: String, setIndex: Int, prescribedKg: Double? = nil, prescribedReps: Int,
                actualKg: Double? = nil, actualReps: Int? = nil, feedback: Feedback? = nil,
                painFlag: Bool = false, restSeconds: Int? = nil, completedAt: String? = nil,
                skipped: Bool = false, day: DayContext) {
        self.id = id
        self.setIndex = setIndex
        self.prescribedKg = prescribedKg
        self.prescribedReps = prescribedReps
        self.actualKg = actualKg
        self.actualReps = actualReps
        self.feedback = feedback
        self.painFlag = painFlag
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.skipped = skipped
        self.date = day.date
        self.tz = day.tz
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
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        date = try c.decode(String.self, forKey: .date)
        tz = try c.decode(String.self, forKey: .tz)
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
        try c.encodeIfPresent(restSeconds, forKey: .restSeconds)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(date, forKey: .date)
        try c.encode(tz, forKey: .tz)
    }
}

/// `POST /v1/workouts/{id}/exercises/{we_id}/substitute`. Словарь причин — из
/// `workout_exercises.substitution_reason` (§3.1).
public enum SubstitutionReason: String, Sendable, Equatable, CaseIterable, Codable {
    case equipment
    case pain
    case userChoice = "user_choice"
    case occupied
}

public struct SubstituteExerciseRequest: Sendable, Equatable, Codable {
    public var toSlug: String
    public var reason: SubstitutionReason
    public var date: String
    public var tz: String

    enum CodingKeys: String, CodingKey {
        case toSlug = "to_slug", reason, date, tz
    }

    public init(toSlug: String, reason: SubstitutionReason, day: DayContext) {
        self.toSlug = toSlug
        self.reason = reason
        self.date = day.date
        self.tz = day.tz
    }
}

/// `POST /v1/workouts/{id}/finish`.
public struct FinishWorkoutRequest: Sendable, Equatable, Codable {
    public var date: String
    public var tz: String

    public init(day: DayContext) {
        self.date = day.date
        self.tz = day.tz
    }
}
