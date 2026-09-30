//  `GET /v1/today` — карточка дня §13.1 (SPEC §20.3, §20.6, §20.7).
//
//  Путь читающий и НИЧЕГО не пишет, включая снимок `last_shown_plan`: §20.6
//  перечисляет четыре пути, которые его пишут, и этого среди них нет. Отсюда и
//  отсутствие `notice` в `TodayCard` — печатать «План обновлён», не записав
//  показанное, значило бы напечатать его второй раз на следующем чтении недели.
//
//  ── Карточка это проекция, а не свой расчёт ───────────────────────────────
//
//  День берётся из `planRemainingDays` по строке `planned_days` с сегодняшней
//  датой — ровно тот же вызов и тот же вход, что у недельных путей. Отдельной
//  «сборки одного дня» в FitCore нет и заводить её незачем (§20.3 о `/preview`,
//  довод тот же): заморозка состояния и момент оценки §7.1 уже внутри.
//
//  ── Три причины, по которым дня может не быть ─────────────────────────────
//
//  Строки `planned_days` под сегодня может не быть, и §20.3 называет два рода
//  такого дня: неделя ещё не сгенерирована (`cause = null`) и дата не
//  тренировочная (`cause = not_a_training_day`). Второй — обычное состояние, а
//  не край: `weekGrid` раздаёт слоты только выбранным дням (§7.2), и при трёх
//  тренировках в неделю таких дат четыре из семи.
//
//  Третий род §20.3 не называет, и он разобран здесь: **профиль неполон**.
//  §20.6 оставил `/today` вне таблицы запретов намеренно — «неполный профиль
//  этого вопроса не создаёт», — то есть путь работает, а не отвечает 409. Но
//  без `goal`, `experience_level` и набора дней `planRemainingDays` вызвать
//  нечем, и карточка отдаёт тот же пустой день с `cause = null`. Готовность,
//  фаза и уверенность при этом считаются: они от четырёх недостающих полей не
//  зависят вовсе, а §20.3 держит `/today` живым именно ради них.
//
//  Случай «профиль разкомплектован ПОСЛЕ генерации недели» (явный `null` в
//  `PATCH /v1/profile` поверх уже сгенерированной недели) сюда же и попадает:
//  неделя в базе есть, а посчитать по ней нечего. Он в SPEC не описан и назван
//  пользователю отдельно.
//
//  ── Причины дня — только недельные ────────────────────────────────────────
//
//  `TodayCard.reasons` это `plan.status_lines` и ничего кроме (§20.3): потеря
//  объёма по мышце и недобор по времени. Фазовые причины сюда не дублируются —
//  они уже в `cycle.periodization.reason`, — а причины сборки лежат внутри
//  `day.session.reasons` и не поднимаются.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

enum TodayRoutes {

    static func register(on routes: any RoutesBuilder, database: Database,
                         library: ContentLibrary) {
        routes.get("today") { request async throws -> Response in
            try await show(request, database: database, library: library)
        }
    }

    static func show(_ request: Request, database: Database,
                     library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            // Всё, что ниже, — уже после проверки токена (§20.5).
            let day = try input.day()
            let profile = try await Mapping.readProfile(tx)
            let cycle = try await Mapping.readCycle(tx, tracking: profile.cycleTracking)
            let (checkin, override) = try await Mapping.readCheckin(tx, on: day.date)

            let cycleState = Cycle.state(events: cycle.events, profile: cycle.profile,
                                         responseProfiles: cycle.responseProfiles, asOf: day.date)
            let readiness = Readiness.value(cycleState: cycleState, override: override,
                                            checkin: checkin)

            func card(day outcome: DayOutcomeDTO, reasons: [ReasonDTO] = []) throws -> Response {
                try WeekPlanRoutes.json(TodayCardDTO(
                    date: Mapping.LocalTime.iso(day.date), readiness: readiness,
                    cycle: CycleStateDTO(cycleState), day: outcome, reasons: reasons))
            }

            let weekStart = Mapping.LocalTime.mondayOfWeek(day.date)
            guard let complete = profile.complete,
                  let week = try await WeekPlanRoutes.loadWeek(tx, weekStart: weekStart)
            else {
                // Неполный профиль или несгенерированная неделя — один и тот же
                // пустой день без причины (§20.3): сказать «сегодня отдых» здесь
                // нельзя, потому что неизвестно, отдых ли это.
                return try card(day: .notBuilt(cause: nil))
            }

            let inputs = try await WeekPlanRoutes.inputs(tx, on: day, profile: profile,
                                                         complete: complete, cycle: cycle,
                                                         checkin: checkin, override: override)
            let context = WeekPlanRoutes.context(
                inputs, weekStart: weekStart, today: day.date, days: week.days,
                isDeload: week.isDeload, library: library,
                userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
            let plan = Planner.planRemainingDays(context)
            let reasons = plan.statusLines.map { ReasonDTO($0) }

            // Строка сегодняшнего дня — и только она: карточка показывает один
            // день, а не ближайший из оставшихся.
            guard let row = week.days.first(where: { $0.date == day.date }),
                  let outcome = plan.days[row.id]
            else {
                return try card(day: .notBuilt(cause: .notATrainingDay), reasons: reasons)
            }
            return try card(day: DayOutcomeDTO(outcome), reasons: reasons)
        }
    }
}
