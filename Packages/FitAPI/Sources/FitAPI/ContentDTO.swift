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

    enum CodingKeys: String, CodingKey {
        case slug, name, cues
        case commonErrors = "common_errors"
        case illustration
        case defaultRestSeconds = "default_rest_seconds"
    }

    public init(slug: String, name: String, cues: [String], commonErrors: [String],
                illustration: String, defaultRestSeconds: Int) {
        self.slug = slug
        self.name = name
        self.cues = cues
        self.commonErrors = commonErrors
        self.illustration = illustration
        self.defaultRestSeconds = defaultRestSeconds
    }
}

/// Шаблон самостоятельной сессии растяжки (§12.2).
///
/// До этапа В3 путь отдаёт пустой массив: схема ПОЗЫ не определена
/// (content-domain §2 п.7), а таблица §12.2 задаёт только эти четыре поля.
/// Тип существует затем, чтобы пустой ответ был валидным ответом, а не
/// отсутствием формы.
public struct StretchContentDTO: Sendable, Equatable, Codable {
    public var slug: String
    public var name: String
    public var durationMinutes: Int
    public var purpose: String

    enum CodingKeys: String, CodingKey {
        case slug, name
        case durationMinutes = "duration_minutes"
        case purpose
    }

    public init(slug: String, name: String, durationMinutes: Int, purpose: String) {
        self.slug = slug
        self.name = name
        self.durationMinutes = durationMinutes
        self.purpose = purpose
    }
}
