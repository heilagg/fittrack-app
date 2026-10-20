//  `stretch_sessions` (SPEC §3.1, §12.2, §20.6) и чтения для прогресса (§13.7).
//
//  Таблицу пишет только сервер (§20.6). `id` — клиентский, повтор с тем же
//  `id` идемпотентен, как у подходов (§20.3). `performed_on` фиксируется при
//  записи из присланного дня (§20.7), а не выводится из `started_at` при чтении.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import PostgresNIO

extension Mapping {

    /// Строка `stretch_sessions` в форме провода.
    static func stretchSession(
        id: String, kind: String, template: String?, performedOn: String,
        startedAt: String, finishedAt: String?, seconds: Double?
    ) -> StretchSessionDTO {
        StretchSessionDTO(id: id, kind: kind, templateSlug: template, performedOn: performedOn,
                          startedAt: startedAt, finishedAt: finishedAt,
                          durationSeconds: finishedAt == nil ? nil : seconds.map { Int($0.rounded()) })
    }

    /// Строка по `id` — своя по RLS; чужая и несуществующая неразличимы.
    public static func readStretchSession(_ tx: UserTransaction, id: UUID) async throws -> StretchSessionDTO? {
        let rows = try await tx.query("""
            select id::text, kind, template_slug, to_char(performed_on, 'YYYY-MM-DD'),
                   to_char(started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   to_char(finished_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   extract(epoch from finished_at - started_at)::float8
              from stretch_sessions where id = \(id) and deleted_at is null
            """)
        for try await row in rows {
            let (sid, kind, template, day, started, finished, seconds) =
                try row.decode((String, String, String?, String, String, String?, Double?).self)
            return stretchSession(id: sid, kind: kind, template: template, performedOn: day,
                                  startedAt: started, finishedAt: finished, seconds: seconds)
        }
        return nil
    }

    /// Вставка начатой сессии. Повтор с тем же `id` строку не трогает: первая
    /// запись и есть факт старта. Вернула ли вставка строку — признак первой
    /// записи (201 против 200, §20.3).
    public static func insertStretchSession(
        _ tx: UserTransaction, id: UUID, userID: UUID, kind: String,
        template: String?, performedOn: CalendarDay
    ) async throws -> Bool {
        let rows = try await tx.query("""
            insert into stretch_sessions (id, user_id, kind, template_slug, performed_on, started_at)
            values (\(id), \(userID), \(kind), \(template), \(LocalTime.iso(performedOn))::date, now())
            on conflict (id) do nothing
            returning id::text
            """)
        for try await _ in rows { return true }
        return false
    }

    /// Завершение: `finished_at` ставится один раз, повтор его не сдвигает.
    public static func finishStretchSession(_ tx: UserTransaction, id: UUID) async throws {
        _ = try await tx.query("""
            update stretch_sessions
               set finished_at = now(), updated_at = now()
             where id = \(id) and finished_at is null and deleted_at is null
            """)
    }

    /// Последние завершённые сессии для истории (§20.3: до 50).
    public static func readStretchHistory(_ tx: UserTransaction, limit: Int = 50) async throws -> [StretchSessionDTO] {
        var result: [StretchSessionDTO] = []
        let rows = try await tx.query("""
            select id::text, kind, template_slug, to_char(performed_on, 'YYYY-MM-DD'),
                   to_char(started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   to_char(finished_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   extract(epoch from finished_at - started_at)::float8
              from stretch_sessions
             where finished_at is not null and deleted_at is null
             order by finished_at desc, id
             limit \(limit)
            """)
        for try await row in rows {
            let (sid, kind, template, day, started, finished, seconds) =
                try row.decode((String, String, String?, String, String, String?, Double?).self)
            result.append(stretchSession(id: sid, kind: kind, template: template, performedOn: day,
                                         startedAt: started, finishedAt: finished, seconds: seconds))
        }
        return result
    }

    /// Дни завершённых сессий растяжки и кардио (§13.7): стрик и календарь.
    public static func readStretchDays(_ tx: UserTransaction) async throws -> Set<CalendarDay> {
        var days = Set<CalendarDay>()
        let rows = try await tx.query("""
            select distinct to_char(performed_on, 'YYYY-MM-DD') from stretch_sessions
             where finished_at is not null and deleted_at is null
            """)
        for try await row in rows {
            days.insert(try day(try row.decode(String.self), column: "stretch_sessions.performed_on"))
        }
        return days
    }

    /// Даты дней сетки со статусом `skipped` в окне (§13.7, «пропуск»).
    public static func readSkippedDays(_ tx: UserTransaction, from: CalendarDay,
                                       to: CalendarDay) async throws -> Set<CalendarDay> {
        var days = Set<CalendarDay>()
        let rows = try await tx.query("""
            select to_char(d.planned_date, 'YYYY-MM-DD')
              from planned_days d join week_plans w on w.id = d.week_plan_id
             where d.status = 'skipped'
               and d.planned_date between \(LocalTime.iso(from))::date and \(LocalTime.iso(to))::date
            """)
        for try await row in rows {
            days.insert(try day(try row.decode(String.self), column: "planned_days.planned_date"))
        }
        return days
    }

    /// Тип последней завершённой силовой тренировки — вход правила §12.2.
    public static func readLastStrengthKind(_ tx: UserTransaction) async throws -> SessionKind? {
        let rows = try await tx.query("""
            select session_kind from workouts
             where finished_at is not null and deleted_at is null
             order by finished_at desc limit 1
            """)
        for try await row in rows {
            return SessionKind(rawValue: try row.decode(String.self))
        }
        return nil
    }
}
