//  Раздача контента с `ETag` (SPEC §20.11, §20.3).
//
//  `FitContent` линкуется в сервер, и `Content/` — единственное место, где
//  разметка превращается в байты ответа. Байты и `ETag` считаются ОДИН РАЗ при
//  старте процесса: контент за время жизни процесса не меняется, потому что его
//  правка требует деплоя.
//
//  ── Почему здесь нет Vapor ────────────────────────────────────────────────
//
//  По той же причине, по которой его нет в `Auth/` и `DB/`: его не зовёт этот
//  код. §20.11 — утверждение про БАЙТЫ и их хеш, а не про HTTP: чем именно
//  ответ доедет до клиента, на состав байт и на значение `ETag` не влияет.
//  Store остаётся чистым значением, его тесты — тестами пакета без HTTP-обвязки,
//  а роут (`Routes/`, §20.3) сведётся к передаче заголовка сюда и ответа
//  обратно. Заодно решение об авторизации `/v1/content/*` не приходится
//  принимать здесь: оно принадлежит роутеру.
//
//  ── Три свойства §20.11, ради которых всё это ─────────────────────────────
//
//  1. Правка контента `ETag` меняет обязательно — опечатка в cue обязана
//     доезжать до клиента.
//  2. Передеплой без правок контента `ETag` НЕ меняет — иначе «долгий кеш»
//     ничего не значит. Отсюда требование к кодированию: одна и та же разметка
//     обязана давать байт в байт один результат между запусками.
//  3. У двух путей свой `ETag` — правка шаблона растяжки не сбрасывает кеш
//     библиотеки упражнений.
//
//  Свойство 2 — единственное, что накладывает требование на кодировщик:
//  `sortedKeys` убирает зависимость от порядка обхода словаря, порядок массива
//  задаёт `ContentLibrary` (сортировка по слагу), и чисел с плавающей точкой в
//  теле нет вовсе — формат их печати был бы третьим источником расхождения.

import Foundation
import Crypto
import FitAPI
import FitContent

/// Готовый ответ одного пути: байты и их `ETag`.
public struct ContentPayload: Sendable, Equatable {
    public let bytes: Data
    /// Сильный валидатор в кавычках, без префикса `W/` (§20.11).
    public let etag: String

    init(bytes: Data) {
        self.bytes = bytes
        let digest = SHA256.hash(data: bytes)
        self.etag = "\"" + digest.map { String(format: "%02x", $0) }.joined() + "\""
    }
}

/// Что вернуть на запрос пути контента.
public enum ContentResult: Sendable, Equatable {
    /// 200: тело и его `ETag`.
    case body(Data, etag: String)
    /// 304: у клиента актуальная копия, тело не передаётся.
    case notModified(etag: String)
}

public struct ContentStore: Sendable {
    public let exercises: ContentPayload
    public let stretches: ContentPayload

    /// Заголовок `Cache-Control` для обоих путей.
    ///
    /// `no-cache`, а не `max-age=<много>`, и это не противоречит «долгому кешу»
    /// §20.11, а единственный способ его получить: `no-cache` разрешает хранить
    /// копию сколь угодно долго и требует лишь сверить `ETag` перед
    /// использованием. Сверка стоит один 304 без тела. С `max-age` клиент не
    /// пошёл бы спрашивать вовсе, и правка опечатки в cue не доехала бы до него
    /// до истечения срока — прямо против первого свойства §20.11.
    public static let cacheControl = "no-cache"

    /// Кодировщик тел. `sortedKeys` — ради свойства 2 (см. шапку файла).
    /// `withoutEscapingSlashes` — чтобы ключи иллюстраций не превращались в
    /// `\/` и байты не зависели от того, есть ли в строке слеш.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public init(library: ContentLibrary) throws {
        let encoder = Self.encoder()
        let exerciseDTOs = library.exercises.map(ExerciseContentDTO.init(_:))
        let stretchDTOs = library.stretches.map(StretchContentDTO.init(_:))
        exercises = ContentPayload(bytes: try encoder.encode(exerciseDTOs))
        stretches = ContentPayload(bytes: try encoder.encode(stretchDTOs))
    }

    /// Ответ на условный запрос. `ifNoneMatch` — сырое значение заголовка.
    public func result(for path: ContentPath, ifNoneMatch: String?) -> ContentResult {
        let payload = self[path]
        guard let ifNoneMatch, Self.matches(ifNoneMatch, payload.etag) else {
            return .body(payload.bytes, etag: payload.etag)
        }
        return .notModified(etag: payload.etag)
    }

    public subscript(path: ContentPath) -> ContentPayload {
        switch path {
        case .exercises: return exercises
        case .stretches: return stretches
        }
    }

    /// Сверка `If-None-Match` по RFC 9110: список через запятую, `*` совпадает
    /// с чем угодно, сравнение СЛАБОЕ — то есть `W/"x"` от клиента совпадает с
    /// нашим сильным `"x"`. Сильный валидатор мы выдаём потому, что §20.11
    /// требует его на выдаче; принимать по слабому правилу — это та же
    /// спецификация, а не послабление.
    static func matches(_ header: String, _ etag: String) -> Bool {
        for candidate in header.split(separator: ",") {
            var value = candidate.trimmingCharacters(in: .whitespaces)
            if value == "*" { return true }
            if value.hasPrefix("W/") { value.removeFirst(2) }
            if value == etag { return true }
        }
        return false
    }
}

/// Два пути контента (§20.3). Закрытый список: третьего пути нет, и роут
/// выбирает из значения, а не из строки.
public enum ContentPath: String, Sendable, CaseIterable {
    case exercises
    case stretches

    public var route: String { "/v1/content/\(rawValue)" }
}

extension ExerciseContentDTO {
    init(_ exercise: ExerciseSchema) {
        self.init(slug: exercise.slug, name: exercise.name, cues: exercise.cues,
                  commonErrors: exercise.commonErrors, illustration: exercise.illustration,
                  defaultRestSeconds: exercise.defaultRestSeconds)
    }
}

extension StretchContentDTO {
    init(_ stretch: StretchSchema) {
        self.init(slug: stretch.slug, name: stretch.name,
                  durationMinutes: stretch.durationMinutes, purpose: stretch.purpose)
    }
}
