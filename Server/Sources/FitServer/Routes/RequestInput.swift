//  Разбор входа запроса ПОСЛЕ проверки токена (SPEC §20.4, §20.5).
//
//  §20.4 сделала единственную точку входа в транзакцию местом, где проверяется
//  токен, и назвала причину: порядок «сначала проверка, потом всё остальное»
//  обязан быть свойством типа, а не дисциплиной вызывающего. Разбор тела
//  подчиняется тому же правилу и по той же причине.
//
//  Разобранное ДО проверки тело наблюдаемо: клиент без токена, приславший
//  негодный JSON, получал `validation_failed`/422 вместо `unauthorized`/401 —
//  то есть сервер отвечал на вопрос о содержимом раньше, чем на вопрос о праве
//  его задавать. Дыры в данных здесь нет, а порядок есть, и §20.5 его называет.
//
//  Поэтому наружу выносится только ЧТЕНИЕ сырых байт и строк запроса — оно
//  ничего не решает, — а разбор и проверка происходят внутри транзакции, уже
//  после `Auth/`.
//
//  Тело транзакции может выполниться дважды (повтор на `40001`, §20.4). Разбор
//  при этом повторится, и это безвредно: он детерминирован и ничего не пишет.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import Vapor

/// Сырой вход запроса: байты тела и параметры запроса, снятые до проверки
/// токена и не разобранные.
struct RawInput: Sendable {
    var body: ByteBuffer
    var query: [String: String]
    var authorization: String?

    init(_ request: Request) {
        body = request.body.data ?? ByteBuffer()
        authorization = request.headers.bearerAuthorization.map { "Bearer \($0.token)" }
        var parsed: [String: String] = [:]
        for pair in request.url.query?.split(separator: "&") ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first?.removingPercentEncoding else { continue }
            parsed[name] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? "") : ""
        }
        query = parsed
    }

    /// Разбор тела. Зовётся уже внутри транзакции.
    ///
    /// Пустое тело — `validation_failed`, а не пустая структура: у всех тел
    /// §20.3 есть обязательные поля, и «прислали ничего» это не «прислали
    /// значения по умолчанию».
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(buffer: body))
    }

    /// `date` и `tz` из query — форма путей `GET` (§20.3).
    func day(at instant: Date = Date()) throws -> RequestDay {
        guard let date = query["date"] else {
            throw APIError(.validationFailed, details: ["field": .string("date")])
        }
        guard let tz = query["tz"] else {
            throw APIError(.validationFailed, details: ["field": .string("tz")])
        }
        return try RequestDay.validated(date: date, tz: tz, at: instant)
    }
}
