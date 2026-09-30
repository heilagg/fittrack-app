//  Routes/ — эндпоинты `/v1` (SPEC §20.3).
//
//  ── Что смонтировано ───────────────────────────────────────────────────────
//
//  Из ШЕСТНАДЦАТИ путей §20.3 смонтированы десять: два контентных, два
//  профильных, пять недельных (включая `/preview`) и `/today`. Число путей считается по таблице
//  «Тела успешных ответов» §20.3, где строка на путь; здесь и в
//  doc-комментарии модуля раньше стояло «четырнадцать», и остаток не сходился
//  с перечислением ровно на `GET /v1/workouts/{id}`.
//
//  Остальные шесть — `GET /v1/workouts/{id}`, `/alternatives` и тренировочный
//  блок (`POST /v1/workouts`, `…/sets`, `/finish`, `/substitute`) — ждут своей
//  очереди. Пустой каркас под них не заводится:
//  смонтированный путь, отвечающий заглушкой, для клиента неотличим от
//  реализованного.
//
//  ── Версия в пути ──────────────────────────────────────────────────────────
//
//  `/v1` обязателен с первого дня (§20.3): у API будет второй клиент (iOS), и
//  он будет обновляться не синхронно с вебом. Поэтому группа заводится здесь
//  один раз, а не приписывается к каждому пути — приписанная, она однажды
//  окажется не приписанной.
//
//  ── Почему middleware ставится здесь же ────────────────────────────────────
//
//  `register` не только монтирует пути, но и заменяет цепочку middleware на
//  `APIErrorMiddleware`. Разнесённые по двум вызовам, монтаж и конверт однажды
//  разъедутся — и разъедутся в ту сторону, где путь есть, а конверта §20.3 у
//  его отказов нет. Умолчание Vapor при этом именно заменяется, а не
//  дополняется: его `ErrorMiddleware` рисует свой конверт `{"error": true,
//  "reason": …}`, то есть ровно второй формат ошибки на той же границе.

import FitContent
import Vapor

/// Монтаж `/v1` (SPEC §20.3).
public enum Routes {

    /// Ставит конверт ошибок и монтирует всё, что есть, под `/v1`.
    ///
    /// `content` передаётся значением, а не читается из `Application`: store —
    /// это уже посчитанные байты и их `ETag` (§20.11), и владеть ими должен
    /// тот, кто их посчитал при старте.
    public static func register(on application: Application, content: ContentStore,
                                library: ContentLibrary, database: Database) {
        application.middleware = Middlewares()
        application.middleware.use(APIErrorMiddleware())

        let v1 = application.grouped("v1")
        ContentRoutes.register(on: v1, store: content)
        ProfileRoutes.register(on: v1, database: database)
        TodayRoutes.register(on: v1, database: database, library: library)
        WeekPlanRoutes.register(on: v1, database: database, library: library)
    }
}
