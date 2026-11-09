//  Недельный блок `/v1/week-plans` (SPEC §7.1, §7.2, §20.3, §20.4, §20.6).
//
//  Четыре пути и одно тело ответа: `GET`, генерация, правка дня и пересборка
//  отдают `WeekPlanResponse`, и различаются они только тем, есть ли что сказать
//  про изменение (§20.3).
//
//  ── Вход читается один раз и одинаково ────────────────────────────────────
//
//  Все четыре читают одно и то же — профиль, инвентарь, безопасность, цикл,
//  чек-ин, утомление, журнал, выполненные тренировки, начатые дни. Поэтому
//  чтение собрано в `inputs(_:on:)`, а не размазано по обработчикам: §20.4
//  обещает СОГЛАСОВАННЫЙ срез, и собранный по кускам в четырёх местах он
//  однажды разойдётся не падением, а разными числами на двух экранах.
//
//  ── Снимок и строка «План обновлён» ───────────────────────────────────────
//
//  Все четыре пути отдают неделю целиком, значит все четыре пишут
//  `last_shown_plan` (§20.6), и во всех порядок несущий: сначала сравнить,
//  потом перезаписать. Причина у строки разная:
//
//    генерация          сравнивать не с чем → notice = null
//    GET                причина не наблюдалась → `plan_changed` (§20.3)
//    PATCH дня          `dayEdited`
//    /rebuild           из тела, и `cycle_event_added` разбирается на два
//
//  ── Транзакция ────────────────────────────────────────────────────────────
//
//  Одна на запрос, `repeatable read`, вход внутри неё (§20.4). Тело
//  `withUserTransaction` может выполниться ДВАЖДЫ — повтор на `40001`, — и оно
//  к этому готово: ничего, кроме запросов, в нём не происходит.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

/// Прочитанный вход недельных путей.
struct WeekPlanInputs: Sendable {
    var complete: Mapping.CompleteProfile
    var sessionMinutes: Int
    var equipment: Mapping.EquipmentSlice
    var safety: SafetyProfile
    var cycle: CycleInputs
    /// Профиль цикла, каким он лежал в базе до применения закрытых циклов.
    var storedCycle: CycleProfile
    /// Применяются ли к нему закрытые циклы (`CycleRead.applies`).
    var cycleApplies: Bool
    var checkin: DailyCheckin
    var override: Override?
    var fatigue: [MuscleSlug: FatigueState]
    var journal: [Mapping.SetRow]
    var completed: [Mapping.CompletedWorkoutRow]
    var completedSets: [String: [Mapping.SetRow]]
    var startedDayIDs: Set<String>
    /// Фактические даты тренировок по `planned_day_id` (§20.3 `performed_on`).
    var workoutDays: [String: CalendarDay]
}

enum WeekPlanRoutes {

    // MARK: - Чтение входа

    /// Весь вход недельных путей одним срезом (§20.4).
    ///
    /// Профиль читается первым и неполный отсекается здесь же: генерация без
    /// четырёх обязательных значений и инвентаря по умолчанию невозможна, а
    /// остальные пути требуют
    /// недели, которой без генерации нет (§20.6).
    ///
    /// `persistCycle` — сохранять ли применённые закрытые циклы (§20.6): `false`
    /// только у `/preview`, который не пишет ничего.
    static func inputs(_ tx: UserTransaction, on day: RequestDay,
                       persistCycle: Bool = true) async throws -> WeekPlanInputs {
        let profile = try await Mapping.readProfile(tx)
        guard let complete = profile.complete else {
            throw APIError(.profileIncomplete, details: [
                "missing": .string(Mapping.missingProfileFields(profile).joined(separator: ","))
            ])
        }
        let cycle = try await Mapping.readCycle(tx, tracking: profile.cycleTracking,
                                                asOf: day.date, persist: persistCycle)
        let (checkin, override) = try await Mapping.readCheckin(tx, on: day.date)
        return try await inputs(tx, on: day, profile: profile, complete: complete, cycle: cycle,
                                checkin: checkin, override: override)
    }

    /// Тот же вход, но с уже прочитанными профилем, циклом и чек-ином.
    ///
    /// Нужен `/today` (§20.3): он обязан ответить и на НЕПОЛНОМ профиле, то есть
    /// принять решение о полноте сам, а не получить `profile_incomplete` из
    /// общего чтения. Читать те же три среза во второй раз значило бы держать в
    /// одной транзакции два их экземпляра — §20.4 обещает согласованный срез, и
    /// дважды прочитанное `daily_checkins` этому обещанию не противоречит лишь
    /// до первой правки.
    static func inputs(_ tx: UserTransaction, on day: RequestDay,
                       profile: Mapping.ProfileSlice, complete: Mapping.CompleteProfile,
                       cycle: Mapping.CycleRead, checkin: DailyCheckin,
                       override: Override?) async throws -> WeekPlanInputs {
        let equipment = try await Mapping.readEquipment(tx, id: nil)
        let safety = try await Mapping.readSafety(tx, level: complete.level, timeZone: day.timeZone)
        let fatigue = try await Mapping.readFatigue(tx)
        // Граница журнала не назначена (§9 сворачивает всю историю), поэтому
        // `nil` — см. `readSets`.
        let journal = try await Mapping.readSets(tx, since: nil, timeZone: day.timeZone)
        let completed = try await Mapping.readCompleted(tx, since: nil, timeZone: day.timeZone)
        let started = try await Mapping.readStartedDayIDs(tx)
        let workoutDays = try await Mapping.readWorkoutDays(tx, timeZone: day.timeZone)

        return WeekPlanInputs(
            complete: complete, sessionMinutes: profile.sessionMinutes, equipment: equipment,
            safety: safety, cycle: cycle.inputs, storedCycle: cycle.stored, cycleApplies: cycle.applies, checkin: checkin, override: override, fatigue: fatigue,
            journal: journal, completed: completed.rows, completedSets: completed.sets,
            startedDayIDs: started, workoutDays: workoutDays)
    }

    /// Контекст планировщика из входа и строк недели.
    static func context(_ inputs: WeekPlanInputs, weekStart: CalendarDay, today: CalendarDay,
                        days: [Mapping.PlannedDayRow], isDeload: Bool,
                        library: ContentLibrary, userSeed: UInt64) -> WeekContext {
        Mapping.weekContext(
            weekStart: weekStart, today: today, days: days, vectors: library.vectors,
            library: library.candidates, profile: inputs.complete,
            sessionMinutes: inputs.sessionMinutes, equipment: inputs.equipment,
            safety: inputs.safety, cycle: inputs.cycle, checkin: inputs.checkin,
            override: inputs.override, fatigue: inputs.fatigue, journal: inputs.journal,
            completed: inputs.completed, completedSets: inputs.completedSets,
            startedDayIDs: inputs.startedDayIDs, isDeloadWeek: isDeload, userSeed: userSeed)
    }

    // MARK: - Сравнение и снимок

    /// Считает план, сравнивает со снимком и перезаписывает его (§20.6).
    ///
    /// Порядок здесь и есть правило: переставленный местами он даёт молчание
    /// всегда — снимок сравнился бы с только что посчитанным планом сам с собой.
    ///
    /// `cause` — `nil` у `GET`, где причина не наблюдалась: строка тогда
    /// `plan_changed` (§20.3). На генерации сравнивать не с чем, и вызывающая
    /// сторона снимок пишет, а строку не печатает.
    static func planAndNotice(_ tx: UserTransaction, weekPlanID: UUID, context: WeekContext,
                              cause: RebuildCause?) async throws -> (WeekPlan, ReasonCode?) {
        let plan = Planner.planRemainingDays(context)
        let previous = try await Mapping.readLastShownPlan(tx, weekPlanID: weekPlanID)

        var notice: ReasonCode?
        if let previous {
            if let cause {
                notice = Planner.rebuildNotice(previous: previous, current: plan, cause: cause)
            } else if Planner.planChanged(previous: previous, current: plan) {
                notice = .planChanged
            }
        }

        try await Mapping.writeLastShownPlan(tx, weekPlanID: weekPlanID, plan: plan)
        return (plan, notice)
    }

    /// `week` — строки недели, из которых посчитан `plan`: у каждого дня ответа
    /// дата и тип (§20.3, `WeekDay`). Дата переводится в ISO здесь, в `Mapping/`
    /// (§20.7), а не в `FitAPI`.
    ///
    /// `workoutDays` — фактические даты тренировок (§20.3 `performed_on`).
    static func response(_ plan: WeekPlan, week: [PlannedDay], notice: ReasonCode?,
                         workoutDays: [String: CalendarDay]) -> WeekPlanResponseDTO {
        WeekPlanResponseDTO(
            plan: WeekPlanDTO(plan, week: week.map { (day: $0, isoDate: Mapping.LocalTime.iso($0.date)) },
                              performedOn: workoutDays.mapValues(Mapping.LocalTime.iso)),
            notice: notice.map { ReasonDTO($0) })
    }
}
