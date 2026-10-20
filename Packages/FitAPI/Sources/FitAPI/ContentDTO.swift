//  Тела `GET /v1/content/exercises` и `/v1/content/stretches` (SPEC §20.3, §20.11).
//
//  Форма тела — часть контракта и живёт здесь, а не в роуте (§20.3). Конверта у
//  неё нет: `/v1/content/*` обязан отдавать ровно те байты, от которых считается
//  `ETag`, а `{"data": …}` добавил бы к ним слой, меняющийся вместе с версией
//  сервера.
//
//  ── Почему это СРЕЗ разметки, а не вся она ────────────────────────────────
//
//  §20.3 называет тело «байтами пакета», и буквально это читалось бы как вся
//  схема §6.2. Отдаётся меньше — только то, что клиенту нужно показать, — и
//  причина не в размере:
//
//  1. §20.1: веб-клиент тонкий, решения принимает сервер. `muscle_contributions`,
//     `joint_stress`, `equipment` и `fatigue_cost` — входы подбора (§7.5), и в
//     браузере они нужны ровно для одного: второй реализации подбора. Не
//     отдавать их дешевле, чем потом доказывать, что её нет.
//  2. Второй клиент их и так имеет. iOS линкует `FitContent` пакетом, и замена
//     упражнения посреди тренировки (§13.4) читает разметку локально — §4.3
//     требует, чтобы тренировка шла без сети. Через HTTP полная разметка не
//     нужна никому.
//  3. Единственный источник правды §20.11 этим не нарушается: он про то, что
//     названия и cues приходят из того же пакета, из которого планировщик берёт
//     срез, — а не про то, что по проводу едут все поля.
//
//  Обратная сторона записана здесь же: новому экрану, которому понадобится поле
//  разметки, придётся расширить этот тип и тем самым сменить `ETag`. Это верно
//  (тело действительно другое) и заметно в ревью — в отличие от поля, которое
//  уехало в браузер «на всякий случай».

/// Упражнение в объёме, который показывает экран (§13.2, §6.5).
public struct ExerciseContentDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var name: String
    /// Подсказки по технике и типичные ошибки (§6.2, §6.5).
    public var cues: [String]
    public var commonErrors: [String]
    /// Ключ иллюстрации; файл раздаётся отдельно (§6.5, §20.11).
    public var illustration: String
    /// Длительность таймера отдыха до множителя готовности (§13.3): множитель
    /// клиент накладывает сам по `workouts.readiness`, правило §13.3 задано
    /// текстом и в тело не едет.
    public var defaultRestSeconds: Int
    /// Подписи снаряда под названием упражнения (§6.6, §13.2, §13.4) —
    /// готовые строки, а не `equipment`: предикатов и `load_type` клиент не
    /// получает. Разделитель ставит клиент; пустой массив — строки нет.
    public var equipmentLabels: [String]

    enum CodingKeys: String, CodingKey {
        case slug, name, cues
        case commonErrors = "common_errors"
        case illustration
        case defaultRestSeconds = "default_rest_seconds"
        case equipmentLabels = "equipment_labels"
    }

    public init(slug: String, name: String, cues: [String], commonErrors: [String],
                illustration: String, defaultRestSeconds: Int, equipmentLabels: [String]) {
        self.slug = slug
        self.name = name
        self.cues = cues
        self.commonErrors = commonErrors
        self.illustration = illustration
        self.defaultRestSeconds = defaultRestSeconds
        self.equipmentLabels = equipmentLabels
    }
}

/// Тело `GET /v1/content/stretches` (§12.3, §20.3): объект, а не массив —
/// позы и шаблоны едут одним телом с одним `ETag`, потому что шаблон без своих
/// поз не проигрывается.
public struct StretchContentDTO: Sendable, Equatable, Codable {
    public var poses: [PoseDTO]
    public var templates: [StretchTemplateDTO]

    public init(poses: [PoseDTO], templates: [StretchTemplateDTO]) {
        self.poses = poses
        self.templates = templates
    }
}

/// Поза в объёме показа и проигрывателя (§12.3, §20.11). `muscles`,
/// `patterns` и `joint_stress` — входы подбора, остаются в пакете.
public struct PoseDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var name: String
    /// `dynamic` | `static` | `cardio`.
    public var kind: String
    public var unilateral: Bool
    public var defaultSeconds: Int
    public var cues: [String]
    public var illustration: String

    enum CodingKeys: String, CodingKey {
        case slug, name, kind, unilateral
        case defaultSeconds = "default_seconds"
        case cues, illustration
    }

    public init(slug: String, name: String, kind: String, unilateral: Bool,
                defaultSeconds: Int, cues: [String], illustration: String) {
        self.slug = slug
        self.name = name
        self.kind = kind
        self.unilateral = unilateral
        self.defaultSeconds = defaultSeconds
        self.cues = cues
        self.illustration = illustration
    }
}

/// Шаблон с посчитанной длительностью (§12.2): `duration_seconds` и `minutes`
/// считает сервер из поз — клиент формулу §12.2 у себя не повторяет.
public struct StretchTemplateDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var name: String
    public var purpose: String
    public var durationSeconds: Int
    public var minutes: Int
    public var items: [TemplateItemDTO]

    enum CodingKeys: String, CodingKey {
        case slug, name, purpose
        case durationSeconds = "duration_seconds"
        case minutes, items
    }

    public init(slug: String, name: String, purpose: String, durationSeconds: Int,
                minutes: Int, items: [TemplateItemDTO]) {
        self.slug = slug
        self.name = name
        self.purpose = purpose
        self.durationSeconds = durationSeconds
        self.minutes = minutes
        self.items = items
    }
}

/// Запись шаблона: у растяжки `seconds`, у кардио интервалы и круги (§12.3).
public struct TemplateItemDTO: Sendable, Equatable, Codable {
    public var pose: String
    public var seconds: Int?
    public var workSeconds: Int?
    public var restSeconds: Int?
    public var rounds: Int?

    enum CodingKeys: String, CodingKey {
        case pose, seconds
        case workSeconds = "work_seconds"
        case restSeconds = "rest_seconds"
        case rounds
    }

    public init(pose: String, seconds: Int? = nil, workSeconds: Int? = nil,
                restSeconds: Int? = nil, rounds: Int? = nil) {
        self.pose = pose
        self.seconds = seconds
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.rounds = rounds
    }
}
