//  Четыре недельных пути `/v1/week-plans` (SPEC §20.3).
//
//  Обработчики тонкие по построению: читают вход одним срезом
//  (`WeekPlanRoutes.inputs`), зовут FitCore, пишут домен через `Mapping/` и
//  отдают `WeekPlanResponse`. Решений они не принимают — все решения уже в
//  §20.3 и §20.6, а здесь только порядок вызовов, который эти разделы задают.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

extension WeekPlanRoutes {

    static func register(on routes: any RoutesBuilder, database: Database,
                         library: ContentLibrary) {
        let plans = routes.grouped("week-plans")

        plans.post { request async throws -> Response in
            try await generate(request, database: database, library: library)
        }
        plans.get(":week_start") { request async throws -> Response in
            try await show(request, database: database, library: library)
        }
        plans.get(":week_start", "preview") { request async throws -> Response in
            try await preview(request, database: database, library: library)
        }
        plans.patch(":week_start", "days", ":day_id") { request async throws -> Response in
            try await patchDay(request, database: database, library: library)
        }
        plans.post(":week_start", "rebuild") { request async throws -> Response in
            try await rebuild(request, database: database, library: library)
        }
    }

    // MARK: - Общее

    /// Понедельник из пути. Не «любая дата недели»: `week_plans.week_start`
    /// хранит именно понедельник (§3.1), и принимать вторник значило бы завести
    /// два написания одной недели в URL.
    static func weekStart(_ raw: String?) throws -> CalendarDay {
        guard let raw, let day = Mapping.LocalTime.day(iso: raw),
              day == Mapping.LocalTime.mondayOfWeek(day)
        else { throw APIError(.validationFailed, details: ["field": .string("week_start")]) }
        return day
    }

    static func uuid(_ raw: String?, _ name: String) throws -> UUID {
        guard let raw, let id = UUID(uuidString: raw)
        else { throw APIError(.validationFailed, details: ["field": .string(name)]) }
        return id
    }

    static func json(_ body: some Encodable, status: HTTPResponseStatus = .ok) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers,
                        body: .init(data: try JSONEncoder().encode(body)))
    }

    /// Неделя и её строки. `nil` — недели нет.
    static func loadWeek(_ tx: UserTransaction, weekStart: CalendarDay) async throws
        -> (id: UUID, isDeload: Bool, days: [Mapping.PlannedDayRow])? {
        guard let plan = try await Mapping.readWeekPlan(tx, weekStart: weekStart) else { return nil }
        return (plan.id, plan.isDeload, try await Mapping.readPlannedDays(tx, weekPlanID: plan.id))
    }

    // MARK: - POST /v1/week-plans

    /// Генерация недели — два вызова FitCore, а не один (§20.3).
    ///
    /// `weekGrid` отдаёт только пары (дата, тип): ни `id`, ни вектора в них нет,
    /// а `planRemainingDays` требует уже существующие `planned_days` и ничего не
    /// создаёт. Отсюда последовательность: сетка → вставка строк → план.
    static func generate(_ request: Request, database: Database,
                         library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            // Всё, что ниже, — уже после проверки токена (§20.5).
            let body = try input.decode(GenerateWeekPlanRequest.self)
            let day = try RequestDay.validated(date: body.date, tz: body.tz)
            guard let weekStart = Mapping.LocalTime.day(iso: body.weekStart),
                  weekStart == Mapping.LocalTime.mondayOfWeek(weekStart)
            else { throw APIError(.validationFailed, details: ["field": .string("week_start")]) }

            // §20.3: принимаются только текущая и ближайшая следующая. Прошлые
            // не генерируются вовсе, дальние не имеют смысла, пока набор дней
            // может смениться (§7.1).
            let thisWeek = Mapping.LocalTime.mondayOfWeek(day.date)
            guard weekStart == thisWeek || weekStart == thisWeek.adding(days: 7) else {
                throw APIError(.validationFailed, details: [
                    "field": .string("week_start"),
                    "this_week": .string(Mapping.LocalTime.iso(thisWeek))
                ])
            }

            let inputs = try await self.inputs(tx, on: day)
            let userSeed = Mapping.userSeed(canonicalUUID: tx.token.subject)
            let slots = Planner.weekGrid(
                days: Mapping.trainingDates(weekStart: weekStart,
                                            weekdays: inputs.complete.trainingWeekdays),
                level: inputs.complete.level)

            if let existing = try await loadWeek(tx, weekStart: weekStart) {
                // Идемпотентность §20.3: повтор С ТЕМИ ЖЕ параметрами отдаёт
                // неделю как есть. Параметры здесь — не тело (в нём только
                // `week_start`), а сетка, которую дал бы профиль СЕЙЧАС: смена
                // `training_weekdays` делает повтор просьбой перегенерировать, а
                // §7.1 уже сгенерированную неделю трогать запрещает.
                let stored = Set(existing.days.map { "\(Mapping.LocalTime.iso($0.date)):\($0.sessionKind)" })
                let wanted = Set(slots.map { "\(Mapping.LocalTime.iso($0.date)):\($0.kind.rawValue)" })
                guard stored == wanted else {
                    throw APIError(.weekExists, details: [
                        "week_start": .string(Mapping.LocalTime.iso(weekStart))
                    ])
                }
                let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                           days: existing.days, isDeload: existing.isDeload,
                                           library: library, userSeed: userSeed)
                let (plan, notice) = try await planAndNotice(tx, weekPlanID: existing.id,
                                                             context: context, cause: nil)
                return try json(response(plan, notice: notice))
            }

            guard let userID = UUID(uuidString: tx.token.subject) else {
                throw APIError(.internal)
            }
            let digestContext = self.context(inputs, weekStart: weekStart, today: day.date,
                                             days: [], isDeload: false,
                                             library: library, userSeed: userSeed)
            let weekPlanID = try await Mapping.insertWeekPlan(
                tx, userID: userID, weekStart: weekStart,
                digest: Mapping.InputDigest(context: digestContext, profile: inputs.complete))
            let inserted = try await Mapping.insertPlannedDays(tx, weekPlanID: weekPlanID, slots: slots)
            let rows = inserted.map {
                Mapping.PlannedDayRow(id: $0.id, date: $0.slot.date,
                                      sessionKind: $0.slot.kind.rawValue, status: "planned")
            }
            let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                       days: rows, isDeload: false,
                                       library: library, userSeed: userSeed)
            let plan = Planner.planRemainingDays(context)
            // Первая генерация: сравнивать не с чем, строка не печатается
            // (§20.3), но снимок пишется — со следующим показом сравнивать уже
            // будет с чем.
            try await Mapping.writeLastShownPlan(tx, weekPlanID: weekPlanID, plan: plan)
            return try json(response(plan, notice: nil), status: .created)
        }
    }

    // MARK: - GET /v1/week-plans/{week_start}

    /// Чтение недели — ПИШУЩИЙ запрос (§20.6): он перезаписывает снимок, и
    /// перед этим сравнивает. Причины у него нет, поэтому строка — `plan_changed`.
    static func show(_ request: Request, database: Database,
                     library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let path = request.parameters.get("week_start")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let weekStart = try self.weekStart(path)
            let day = try input.day()
            guard let week = try await loadWeek(tx, weekStart: weekStart) else {
                throw APIError(.notFound, details: [
                    "week_start": .string(Mapping.LocalTime.iso(weekStart))
                ])
            }
            let inputs = try await self.inputs(tx, on: day)
            let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                       days: week.days, isDeload: week.isDeload, library: library,
                                       userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
            let (plan, notice) = try await planAndNotice(tx, weekPlanID: week.id,
                                                         context: context, cause: nil)
            return try json(response(plan, notice: notice))
        }
    }

    // MARK: - GET /v1/week-plans/{week_start}/preview

    /// Дата среза — параметр `day`, а не `date` (§20.3).
    ///
    /// Две даты у одного пути существуют по необходимости: `date` израсходован
    /// на «сегодня» планировщика, а `week_start` в пути позволяет спросить не
    /// текущую неделю, куда присланная дата не попадает вовсе.
    ///
    /// Несоответствие неделе — `validation_failed`, а не пустой срез: пустой
    /// ответ здесь неотличим от законного дня отдыха.
    static func sliceDate(_ input: RawInput, weekStart: CalendarDay) throws -> CalendarDay {
        guard let raw = input.query["day"], let target = Mapping.LocalTime.day(iso: raw) else {
            throw APIError(.validationFailed, details: ["field": .string("day")])
        }
        guard target >= weekStart, target < weekStart.adding(days: 7) else {
            throw APIError(.validationFailed, details: [
                "field": .string("day"),
                "week_start": .string(Mapping.LocalTime.iso(weekStart))
            ])
        }
        return target
    }

    /// Проекция недели на один день (§20.3).
    ///
    /// Своего расчёта нет и не нужно: заморозка состояния будущего дня (§18,
    /// 31b) уже внутри `planRemainingDays` — готовность считается от состояния
    /// цикла на дату дня без check-in и оверрайда, утомление с распадом до
    /// момента оценки ЭТОГО дня. Здесь остаётся только срез.
    ///
    /// **Снимок не пишется — ни целиком, ни частью** (§20.6). Срез по одной
    /// дате, положенный в снимок, заставил бы следующую пересборку счесть
    /// исчезнувшими все остальные дни и напечатать «План обновлён» там, где
    /// ничего не менялось. Отсюда же `notice` — всегда `null`: путь, который не
    /// записал показанное, не вправе о нём и сообщать, иначе строка повторится
    /// на следующем чтении недели.
    ///
    /// `status_lines` — недельные, без фильтрации (§20.3): потеря объёма и
    /// недобор по времени считаются по ВСЕЙ неделе, и отфильтрованное число не
    /// совпало бы с недельным экраном.
    static func preview(_ request: Request, database: Database,
                        library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let path = request.parameters.get("week_start")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let weekStart = try self.weekStart(path)
            let day = try input.day()
            let target = try self.sliceDate(input, weekStart: weekStart)

            guard let week = try await loadWeek(tx, weekStart: weekStart) else {
                // §20.3: срезать нечего. Не 404 — неделя не «не найдена», её
                // просто ещё не генерировали, и это законное состояние.
                return try json(response(WeekPlan(days: [:], statusLines: []), notice: nil))
            }
            // `/preview` не пишет ничего, включая счётчик цикла (§20.6).
            let inputs = try await self.inputs(tx, on: day, persistCycle: false)
            let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                       days: week.days, isDeload: week.isDeload, library: library,
                                       userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
            let plan = Planner.planRemainingDays(context)

            // Дней с одной датой в неделе не больше одного — это держит схема
            // (`unique (week_plan_id, planned_date)`), — но срез написан через
            // множество, а не через `first`: полагаться здесь на уникальность
            // значило бы отдать клиенту один день из двух молча.
            let ids = Set(week.days.filter { $0.date == target }.map(\.id))
            let sliced = WeekPlan(days: plan.days.filter { ids.contains($0.key) },
                                  statusLines: plan.statusLines)
            return try json(response(sliced, notice: nil))
        }
    }

    // MARK: - PATCH /v1/week-plans/{week_start}/days/{day_id}

    /// Акцент, тип дня и отметка статуса (§7.2, §20.3).
    ///
    /// Причину пересборки (`dayEdited`) проставляет сервер по тому, что
    /// изменилось в теле; клиент её не называет.
    static func patchDay(_ request: Request, database: Database,
                         library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let path = request.parameters.get("week_start")
        let rawDayID = request.parameters.get("day_id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let weekStart = try self.weekStart(path)
            let dayID = try self.uuid(rawDayID, "day_id")
            let body = try input.decode(PatchPlannedDayRequest.self)
            let day = try RequestDay.validated(date: body.date, tz: body.tz)

            // §20.3: `rest` этим путём не ставится — день отдыха живёт
            // оверрайдом §11.4, один день и без перебалансировки недели.
            if body.sessionKind == .rest {
                throw APIError(.validationFailed, details: ["field": .string("session_kind")])
            }
            // §20.3: `done` ставит только `/finish`, вместе с закрытием
            // тренировки; `replaced` не производит ни один путь.
            if let status = body.status, status != .planned, status != .skipped {
                throw APIError(.validationFailed, details: ["field": .string("status")])
            }

            guard let week = try await loadWeek(tx, weekStart: weekStart),
                  let target = week.days.first(where: { $0.id == dayID.uuidString.lowercased() })
            else { throw APIError(.notFound, details: ["day_id": .string(dayID.uuidString)]) }
            // §20.3: `done` — факт исполнения от `/finish`, и править такой день
            // нельзя ничем: возврат в `planned` отдал бы его `classify` заново.
            if target.status == PlannedDayStatus.done.rawValue {
                throw APIError(.dayNotPlanned, details: [
                    "day_id": .string(dayID.uuidString), "status": .string(target.status)
                ])
            }

            try await Mapping.updatePlannedDay(tx, dayID: dayID, accent: body.accentMuscle,
                                               kind: body.sessionKind, status: body.status)
            let days = try await Mapping.readPlannedDays(tx, weekPlanID: week.id)
            let inputs = try await self.inputs(tx, on: day)
            let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                       days: days, isDeload: week.isDeload, library: library,
                                       userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
            let (plan, notice) = try await planAndNotice(tx, weekPlanID: week.id,
                                                         context: context, cause: .dayEdited)
            return try json(response(plan, notice: notice))
        }
    }

    // MARK: - POST /v1/week-plans/{week_start}/rebuild

    /// Пересборка по причине, которую сервер наблюдать не мог (§20.3).
    ///
    /// Две причины, и вторая разбирается на две: по `cycle_event_added` сервер
    /// сам решает, смена это фазы или уверенности, сравнив состояние цикла до и
    /// после. «До» вычисляется отбрасыванием последнего по `occurred_on`
    /// события — хранить его негде, `cycle_events` пишет фронтенд напрямую.
    static func rebuild(_ request: Request, database: Database,
                        library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let path = request.parameters.get("week_start")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let weekStart = try self.weekStart(path)
            let body = try input.decode(RebuildWeekPlanRequest.self)
            let day = try RequestDay.validated(date: body.date, tz: body.tz)

            guard let week = try await loadWeek(tx, weekStart: weekStart) else {
                throw APIError(.notFound, details: [
                    "week_start": .string(Mapping.LocalTime.iso(weekStart))
                ])
            }
            let inputs = try await self.inputs(tx, on: day)
            let cause = self.cause(for: body.cause, cycle: inputs.cycle, stored: inputs.storedCycle,
                                   applies: inputs.cycleApplies, on: day.date)
            let context = self.context(inputs, weekStart: weekStart, today: day.date,
                                       days: week.days, isDeload: week.isDeload, library: library,
                                       userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
            let (plan, notice) = try await planAndNotice(tx, weekPlanID: week.id,
                                                         context: context, cause: cause)
            return try json(response(plan, notice: notice))
        }
    }

    /// Причина из клиентской (§20.3).
    ///
    /// `equipment_changed` едет один к одному. `cycle_event_added` различается
    /// сравнением состояний: отбрасываем последнее событие и смотрим, сменилась
    /// фаза или только уверенность. Если событий нет вовсе — сменилась
    /// уверенность: фазе меняться не с чего.
    ///
    /// Оба состояния проходят через `applyingClosedCycles` (§20.3, §11.5):
    /// «после» — `cycle` уже применён по всем событиям, «до» — сохранённый
    /// профиль `stored` применяется к оставшимся. Иначе автопереход режима,
    /// вызванный как раз этим событием, терялся бы в причине.
    static func cause(for client: ClientRebuildCause, cycle: CycleInputs,
                      stored: CycleProfile, applies: Bool,
                      on today: CalendarDay) -> RebuildCause {
        switch client {
        case .equipmentChanged:
            return .equipmentChanged
        case .cycleEventAdded:
            let after = Cycle.state(events: cycle.events, profile: cycle.profile,
                                    responseProfiles: cycle.responseProfiles, asOf: today)
            let latest = cycle.events.max { $0.occurredOn < $1.occurredOn }
            var remaining = cycle.events
            if let latest, let index = remaining.firstIndex(of: latest) { remaining.remove(at: index) }
            let beforeInputs = Mapping.applyingClosedCycles(
                to: CycleInputs(events: remaining, profile: stored,
                                responseProfiles: cycle.responseProfiles),
                applies: applies, asOf: today)
            let before = Cycle.state(events: remaining, profile: beforeInputs.profile,
                                     responseProfiles: cycle.responseProfiles, asOf: today)
            return before.phase != after.phase
                ? .phaseChanged(phase: after.phase, cycleConfidence: after.cycleConfidence)
                : .cycleConfidenceChanged(cycleConfidence: after.cycleConfidence)
        }
    }
}
