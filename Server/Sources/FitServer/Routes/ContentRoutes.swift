//  `GET /v1/content/exercises` и `/v1/content/stretches` (SPEC §20.3, §20.11).
//
//  Роут сведён к передаче `If-None-Match` внутрь и результата обратно — ровно
//  так, как обещал doc-комментарий `Content/ContentStore.swift`. Ни байт тела,
//  ни `ETag` здесь не считаются: и то и другое посчитано один раз при старте
//  процесса, потому что правка контента требует деплоя (§20.11).
//
//  ── Токена здесь нет, и это не послабление ─────────────────────────────────
//
//  §20.5: оба пути публичные. Контент у всех один и тот же, пользовательских
//  строк не несёт и к `auth.uid()` не обращается ни одним полем; требовать
//  токен значило бы платить долгим кешем — ответ с `Authorization` не кеширует
//  ни один общий слой. Отсюда следствие, которое стоит назвать прямо: `401` на
//  этих путях не бывает НИКОГДА, даже если токен прислан и он негоден.
//  Механически это обеспечено тем, что заголовок здесь не читается вовсе, а
//  `Database` в эти роуты не передаётся.
//
//  Ни `unlinked_account`, ни `forbidden` на них тоже не бывает: линковка к
//  контенту отношения не имеет, а RLS здесь нечего применять.
//
//  ── 304 несёт заголовки 200 ────────────────────────────────────────────────
//
//  `ETag` и `Cache-Control` ставятся и на 304: по RFC 9110 ответ 304 обязан
//  нести те же валидирующие и кеширующие заголовки, что и 200, иначе клиент
//  теряет основание считать копию свежей и на следующем запросе приходит за
//  телом — то есть долгий кеш §20.11 перестаёт работать ровно там, где он и
//  должен был сработать.

import FitAPI
import Vapor

/// Два пути контента (§20.3). Список закрыт: третьего нет, и роут выбирает из
/// значения `ContentPath`, а не из строки.
enum ContentRoutes {

    static func register(on routes: any RoutesBuilder, store: ContentStore) {
        let content = routes.grouped("content")
        for path in ContentPath.allCases {
            content.get(.constant(path.rawValue)) { request async -> Response in
                response(for: store.result(for: path,
                                           ifNoneMatch: request.headers.first(name: .ifNoneMatch)))
            }
        }
    }

    static func response(for result: ContentResult) -> Response {
        switch result {
        case .body(let bytes, let etag):
            return Response(status: .ok, headers: headers(etag: etag), body: .init(data: bytes))
        case .notModified(let etag):
            return Response(status: .notModified, headers: headers(etag: etag))
        }
    }

    private static func headers(etag: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.contentType = .json
        // `ETag` уже приходит сильным и в кавычках (§20.11) — здесь его не
        // переупаковывают: любая правка формы валидатора обязана быть правкой
        // того места, где считаются байты, а не этого.
        headers.replaceOrAdd(name: .eTag, value: etag)
        headers.replaceOrAdd(name: .cacheControl, value: ContentStore.cacheControl)
        return headers
    }
}
