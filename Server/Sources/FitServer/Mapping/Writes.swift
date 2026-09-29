//  Запись домена: типы FitCore → схема §3.1 (SPEC §20.4, §20.6).
//
//  ── Почему запись тоже здесь, а не в роутах ───────────────────────────────
//
//  §20.2 называет `Mapping/` единственным местом, где соответствие схемы и
//  типов FitCore существует. Направление в этой фразе не оговорено, и оговорка
//  была бы вредной: `planned_days` читаются и пишутся ОДНИМИ И ТЕМИ ЖЕ
//  колонками, и разведи их по слоям — получишь два описания одной строки,
//  которые обязаны совпадать и ничем не связаны. Та же причина, по которой
//  §20.2 держит исходящие DTO в `FitAPI`, а не в сервере.
//
//  Роутам остаётся то, что действительно их: ЧТО записать и КОГДА. Порядок
//  вызовов, момент снимка, что считать до записи, а что после — решения §20.3 и
//  §20.6, и они принадлежат пути, а не слою.
//
//  ── `user_id` подставляется явно, хотя RLS его и проверит ─────────────────
//
//  На чтении фильтра нет — его ставит политика (§3.2). На записи политика
//  проверяет `with check`, но подставить значение не может: колонка `not null`,
//  и без неё `insert` просто не пройдёт. Поэтому `sub` проверенного токена
//  уходит в запрос параметром — не как модель доступа, а как значение колонки.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import PostgresNIO

extension Mapping {

    // MARK: - Снимок входа генерации

    /// `week_plans.input_digest` (§3.1, §20.6).
    ///
    /// Назначение — отладка и воспроизводимость: «какой именно вход дал этот
    /// план». Причину пересборки он НЕ определяет и определять не может —
    /// строку §7.1 даёт `Planner.rebuildNotice`, а она сравнивает два ВЫХОДА и
    /// дайджеста не читает.
    ///
    /// **Состав выбран, а не выведен: §20.6 требует «полный снимок входа» и не
    /// перечисляет полей.** Взято то, что меняет результат и при этом не
    /// восстанавливается из других таблиц задним числом, — инвентарь после
    /// правки не остаётся в базе прежним (§20.6), а утомление и `неделя[m]`
    /// уничтожаются следующей же выполненной тренировкой. Библиотека
    /// упражнений в снимок не идёт: она приезжает из `FitContent` версией
    /// сервера, и её слепок был бы копией пакета в каждой строке.
    ///
    /// Номер версии обязателен с первой записи — правило то же, что у снимка
    /// плана (§20.6).
    public struct InputDigest: Sendable, Equatable, Codable {
        public static let currentVersion = 1

        public var version: Int
        public var weekStart: String
        public var today: String
        public var goal: String
        public var level: String
        public var sessionMinutes: Int
        public var trainingWeekdays: [Int]
        public var userSeed: String
        public var isDeloadWeek: Bool
        /// Инвентарь на момент генерации: после правки `equipment_profiles`
        /// прежнего в базе не остаётся (§20.6).
        public var equipment: [String: [Double]]
        public var barbellKg: Double?
        public var machineStepKg: Double?
        /// Утомление по мышцам ДО распада, с меткой: следующая выполненная
        /// тренировка его перепишет.
        public var fatigue: [String: Double]
        /// Состояние цикла в том виде, в каком его увидела сборка.
        public var phaseMode: String
        public var noPhaseReason: String?
        public var cycleEvents: [String]

        enum CodingKeys: String, CodingKey {
            case version = "v", weekStart = "week_start", today, goal, level
            case sessionMinutes = "session_minutes", trainingWeekdays = "training_weekdays"
            case userSeed = "user_seed", isDeloadWeek = "is_deload", equipment
            case barbellKg = "barbell_kg", machineStepKg = "machine_step_kg", fatigue
            case phaseMode = "phase_mode", noPhaseReason = "no_phase_reason"
            case cycleEvents = "cycle_events"
        }

        public init(context: WeekContext, profile: CompleteProfile) {
            version = Self.currentVersion
            weekStart = LocalTime.iso(context.weekStart)
            today = LocalTime.iso(context.today)
            goal = context.goal.rawValue
            level = context.safety.level.rawValue
            sessionMinutes = context.sessionMinutes
            trainingWeekdays = profile.trainingWeekdays
            // Строкой, а не числом: `UInt64` не влезает в `Int` JSON у всех
            // читателей, а дайджест читают глазами и чужими инструментами.
            userSeed = String(context.userSeed)
            isDeloadWeek = context.isDeloadWeek
            equipment = [
                "dumbbells_kg": context.equipment.dumbbellsKg,
                "kettlebells_kg": context.equipment.kettlebellsKg,
                "plates_kg": context.equipment.platesKg
            ]
            barbellKg = context.equipment.barbellKg
            machineStepKg = context.equipment.machineStepKg
            fatigue = Dictionary(uniqueKeysWithValues:
                context.fatigue.map { ($0.key.rawValue, $0.value.value) })
            phaseMode = context.cycle.profile.phaseMode.rawValue
            noPhaseReason = context.cycle.profile.noPhaseReason?.rawValue
            cycleEvents = context.cycle.events
                .map { "\($0.kind.rawValue)@\(LocalTime.iso($0.occurredOn))" }
                .sorted()
        }
    }

    static func json(_ value: some Encodable) throws -> String {
        // `sortedKeys` — чтобы одинаковый вход давал одинаковые байты: снимок
        // читают глазами и сравнивают дифом.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Генерация недели

    /// Вставляет `week_plans` и возвращает `id`.
    ///
    /// `is_deload` всегда `false`: правило счёта §11.5 открыто (§19.2 п.4), и
    /// признак фиксируется на неделю, а не пересчитывается пересборкой.
    public static func insertWeekPlan(_ tx: UserTransaction, userID: UUID, weekStart: CalendarDay,
                                      digest: InputDigest) async throws -> UUID {
        let id = UUID()
        _ = try await tx.query("""
            insert into week_plans (id, user_id, week_start, generated_at, is_deload, input_digest)
            values (\(id), \(userID), \(LocalTime.iso(weekStart))::date, now(), false,
                    \(try json(digest))::jsonb)
            """)
        return id
    }

    /// Вставляет дни недели. `id` минтит сервер: `Planner.weekGrid` их не даёт
    /// (§20.3), а `planRemainingDays` требует уже существующие строки.
    ///
    /// Возвращает пары (id, слот) в том же порядке, чтобы вызывающая сторона
    /// могла собрать `[PlannedDay]`, не перечитывая таблицу внутри той же
    /// транзакции.
    public static func insertPlannedDays(_ tx: UserTransaction, weekPlanID: UUID,
                                         slots: [GridSlot]) async throws -> [(id: String, slot: GridSlot)] {
        var result: [(id: String, slot: GridSlot)] = []
        for slot in slots {
            let id = UUID()
            _ = try await tx.query("""
                insert into planned_days (id, week_plan_id, planned_date, session_kind,
                                          accent_muscle, status)
                values (\(id), \(weekPlanID), \(LocalTime.iso(slot.date))::date,
                        \(slot.kind.rawValue), null, 'planned')
                """)
            result.append((id.uuidString.lowercased(), slot))
        }
        return result
    }

    // MARK: - Снимок показанного плана

    /// Читает `week_plans.last_shown_plan` (§20.6).
    ///
    /// `nil` — неделя ни разу не показана либо снимок не разбирается. Второе
    /// трактуется как первое намеренно: `WeekPlanSnapshot` бросает на чужой
    /// версии, и одна молчаливая пересборка лучше, чем сравнение с выдуманным
    /// планом (§20.6).
    public static func readLastShownPlan(_ tx: UserTransaction,
                                         weekPlanID: UUID) async throws -> WeekPlan? {
        let rows = try await tx.query("""
            select last_shown_plan::text from week_plans where id = \(weekPlanID)
            """)
        for try await row in rows {
            guard let text = try row.decode(String?.self), let data = text.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(WeekPlanSnapshot.self, from: data)
            else { return nil }
            return snapshot.restoredForComparison()
        }
        return nil
    }

    /// Пишет снимок. Зовут его только пути, отдающие неделю целиком (§20.6):
    /// `GET`, генерация, пересборка и `/finish`.
    public static func writeLastShownPlan(_ tx: UserTransaction, weekPlanID: UUID,
                                          plan: WeekPlan) async throws {
        _ = try await tx.query("""
            update week_plans set last_shown_plan = \(try json(WeekPlanSnapshot(plan)))::jsonb
             where id = \(weekPlanID)
            """)
    }

    // MARK: - Правка дня

    /// `PATCH .../days/{day_id}` (§20.3). Отсутствующее поле не трогается —
    /// `coalesce` по параметру, а не по колонке.
    ///
    /// `accentMuscle` — двойная опциональность до самого SQL: внешний `nil`
    /// означает «не трогать», внутренний — «снять акцент». Разведены они
    /// отдельным флагом, потому что в SQL третьего состояния у параметра нет.
    public static func updatePlannedDay(_ tx: UserTransaction, dayID: UUID,
                                        accent: MuscleSlug??, kind: SessionKind?,
                                        status: PlannedDayStatus?) async throws {
        let touchesAccent = accent != nil
        let accentValue: String? = accent.flatMap { $0?.rawValue }
        _ = try await tx.query("""
            update planned_days
               set accent_muscle = case when \(touchesAccent) then \(accentValue)
                                        else accent_muscle end,
                   session_kind  = coalesce(\(kind?.rawValue), session_kind),
                   status        = coalesce(\(status?.rawValue), status)
             where id = \(dayID)
            """)
    }
}
