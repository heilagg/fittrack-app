//  Конверт ошибки `/v1` и его middleware (SPEC §20.3).
//
//  §20.3: ошибка — ВСЕГДА `{"error": {"code", "message", "details"}}`, словарь
//  `code` закрыт, а пара (код, HTTP-статус) — часть контракта. Обе половины уже
//  живут в `FitAPI` (`APIErrorCode.httpStatus`, `APIErrorEnvelope`), и здесь
//  ничего не выбирается заново: файл только доставляет их наружу.
//
//  ── Почему middleware, а не возврат из роута ───────────────────────────────
//
//  По тому же доводу, по которому `DB/` сделал единственный вход в транзакцию
//  (§20.4): конверт, собираемый в каждом обработчике, — дисциплина, которую
//  новый роут нарушает молча, отдав голый 500 Vapor'а. Здесь он становится
//  свойством цепочки: пройти мимо нельзя, потому что бросок — единственный
//  способ роута отказать.
//
//  Отсюда же требование ставить middleware вместе с монтажом путей
//  (`Routes.register`), а не отдельным шагом конфигурации: разнесённые, они
//  однажды разъедутся, и разъедутся в ту сторону, где путь смонтирован, а
//  конверт нет.
//
//  ── Формулировку роут не пишет ─────────────────────────────────────────────
//
//  У `APIError` нет поля `message`, и это не упущение. §20.2 и §20.3: русские
//  строки живут в `FitAPI`, чтобы iOS в офлайне читал тот же каталог, а не
//  писал второй. Поле для переопределения здесь означало бы ровно тот каталог,
//  размноженный по роутам.
//
//  ── Чужие ошибки ───────────────────────────────────────────────────────────
//
//  Словарь §20.3 закрыт, поэтому ошибка, у которой своего кода нет, его не
//  получает — она схлопывается в ближайший, на который клиент реагирует так же:
//  «тело не прошло схему» либо «наша поломка». Признак заведения нового кода —
//  различимое поведение клиента (§20.3), и статус, который Vapor придумал сам,
//  таким признаком не является.
//
//  Внутрь `message` и `details` при этом не попадает ничего из текста
//  исключения: `details` машинный и открытый, но он едет клиенту, а причина
//  падения — в лог.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import Vapor

/// Отказ с кодом из закрытого словаря §20.3.
///
/// `details` — машинный и открытый: путь к невалидному полю, конфликтующий
/// `id`, присланная и серверная даты. Пользовательнице не показывается
/// никогда, поэтому русского текста здесь не бывает.
public struct APIError: Error, Equatable, Sendable {
    public let code: APIErrorCode
    public let details: [String: APIDetailValue]?

    public init(_ code: APIErrorCode, details: [String: APIDetailValue]? = nil) {
        self.code = code
        self.details = details
    }

    /// Тело ответа. Формулировку подставляет каталог `FitAPI` по коду.
    public var envelope: APIErrorEnvelope {
        APIErrorEnvelope(code: code, details: details)
    }
}

/// Единственный переводчик брошенного в ответ `/v1` (§20.3).
public struct APIErrorMiddleware: AsyncMiddleware {

    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let api = Self.apiError(for: error)
            // Логируется только то, чего клиент по коду не узнает. У остальных
            // кодов причина уже названа в ответе, и второй её экземпляр в логе
            // — шум на критическом пути §19.1.
            if api.code == .internal {
                request.logger.report(error: error)
            }
            return Self.response(for: api, on: request)
        }
    }

    /// Сведение любого броска к закрытому словарю §20.3.
    static func apiError(for error: any Error) -> APIError {
        switch error {
        case let api as APIError:
            return api
        // Оба уже несут свой код: `Auth/` различает 401, 503 и 403 (§20.5),
        // `DB/` относит свои отказы к `internal` (§20.4).
        case let failure as AuthFailure:
            return APIError(failure.code)
        case let failure as DatabaseFailure:
            return APIError(failure.code)
        // §20.3 требует класть в `details` путь к невалидному полю, и
        // единственное место, где этот путь вообще существует, — здесь.
        case let decoding as DecodingError:
            return APIError(.validationFailed, details: fieldPath(decoding).map { ["field": .string($0)] })
        case let abort as any AbortError:
            return APIError(abort.status == .notFound ? .notFound
                            : (400..<500).contains(Int(abort.status.code)) ? .validationFailed
                            : .internal)
        default:
            return APIError(.internal)
        }
    }

    /// Путь к полю в том же виде, в каком его печатает JSON-указатель тела:
    /// `exercises.0.target_sets`. Ключ отсутствующего поля в `codingPath` не
    /// лежит — его добавляет сам случай, поэтому он разобран отдельно.
    static func fieldPath(_ error: DecodingError) -> String? {
        var path: [any CodingKey]
        switch error {
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        @unknown default:
            return nil
        }
        guard !path.isEmpty else { return nil }
        return path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    static func response(for error: APIError, on request: Request) -> Response {
        let status = HTTPResponseStatus(statusCode: error.code.httpStatus)
        var headers = HTTPHeaders()
        headers.contentType = .json
        do {
            let body = try JSONEncoder().encode(error.envelope)
            return Response(status: status, headers: headers, body: .init(data: body))
        } catch {
            // Сюда попасть нечем: конверт — четыре поля из строк и чисел. Но
            // молчаливый пустой ответ на этом месте выглядел бы как успех с
            // пустым телом, а §20.3 обещает конверт всегда.
            request.logger.report(error: error)
            return Response(status: .internalServerError, headers: headers,
                            body: .init(string: #"{"error":{"code":"internal","message":""}}"#))
        }
    }
}
