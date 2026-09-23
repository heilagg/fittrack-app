//  Снимок последнего показанного плана недели — `week_plans.last_shown_plan`
//  (SPEC §3.1, §20.6).
//
//  Единственный потребитель — `Planner.rebuildNotice`: она сравнивает два
//  ВЫХОДА планировщика и без предыдущего не может решить, печатать ли «План
//  обновлён» (§7.1), а молчаливая пересборка там объявлена недопустимой.
//  Хранить состав будущего дня больше негде (строки `workouts` у него нет), и
//  пересчитать «как было» нельзя: выполненная тренировка необратимо меняет
//  утомление и `неделя[m]`, а старого инвентаря после правки
//  `equipment_profiles` в базе не остаётся.
//
//  **Тип свой и узкий, а не `WeekPlanDTO`.** Сравнение (`Planner.isPlanChange`)
//  читает ровно три вещи на день: `kind`, `cause` и состав (слаг →
//  `target_sets`). `WeekPlanDTO` несёт сверх этого `estimated_seconds`,
//  `reasons` и `status_lines` и привязал бы формат ХРАНЕНИЯ к форме ОТВЕТА:
//  правка §20.3 стала бы правкой данных у всех живых пользователей.
//
//  **Это единственное место пакета, которое читает НАЗАД в значения FitCore.**
//  Остальной FitAPI — односторонний: типы ядра наружу. Здесь направление
//  обратное по необходимости, и тот же код понадобится iOS, где пересборка та
//  же самая.

import FitCore

/// Снимок плана недели в том виде, в каком он лежит в `jsonb`.
public struct WeekPlanSnapshot: Sendable, Equatable {

    /// Номер версии формата. Обязателен с первой записи — правило то же, что у
    /// `input_digest` (§3.1), а причина сильнее: дайджест читают глазами при
    /// отладке, снимок читают кодом.
    public static let currentVersion = 1

    public struct Day: Sendable, Equatable, Codable {
        public var kind: String
        public var cause: String?
        /// Слаг → `target_sets`. `nil` у дня без собранной тренировки: отличать
        /// «сессии не было» от «сессия была пустой» обязательно — второе
        /// изменение плана, а первое нет.
        public var composition: [String: Int]?

        public init(kind: String, cause: String?, composition: [String: Int]?) {
            self.kind = kind
            self.cause = cause
            self.composition = composition
        }
    }

    public var version: Int
    public var days: [String: Day]

    public init(_ plan: WeekPlan) {
        version = Self.currentVersion
        days = plan.days.mapValues { outcome in
            Day(kind: ReasonDTO.code(for: outcome.kind),
                cause: outcome.cause.map(ReasonDTO.code(for:)),
                composition: outcome.session?.composition)
        }
    }

    /// План в том виде, в каком его принимает `Planner.rebuildNotice`.
    ///
    /// **Годен ТОЛЬКО для сравнения.** Восстановлены три величины, которые
    /// читает `isPlanChange`: `kind`, `cause` и состав. Всё остальное
    /// намеренно вырождено — `estimatedSeconds` и `scale` нули,
    /// `effectiveVolume` и `reasons` пусты, `losesPlannedVolume` ложь, у
    /// упражнений нет ни весов, ни диапазонов. Показывать такой план
    /// пользовательнице нельзя, и вырожденные значения выбраны затем, чтобы
    /// попытка это сделать была видна сразу, а не выглядела правдоподобно.
    ///
    /// `nil` — снимок не разбирается (неизвестный `kind` или `cause`), и
    /// вызывающая сторона обязана считать это отсутствием снимка: одна
    /// пересборка пройдёт молча, что лучше, чем сравнение с выдуманным планом.
    public func restoredForComparison() -> WeekPlan? {
        var outcomes: [String: DayOutcome] = [:]
        for (dayID, day) in days {
            guard let kind = ReasonDTO.dayKind(day.kind) else { return nil }
            var cause: DayOutcome.Cause?
            if let raw = day.cause {
                guard let decoded = ReasonDTO.dayCause(raw) else { return nil }
                cause = decoded
            }
            let session = day.composition.map { composition in
                BuiltSession(
                    dayID: dayID,
                    // Порядок восстановлению не подлежит и сравнению не нужен:
                    // `composition` — словарь, и `isPlanChange` сравнивает
                    // словари. Слаги сортируются ради воспроизводимости.
                    exercises: composition.keys.sorted().map { slug in
                        PrescribedExercise(slug: slug, orderIndex: 0, targetSets: composition[slug] ?? 0,
                                           targetRepMin: 0, targetRepMax: 0, targetRIR: 0,
                                           prescribedKg: nil, weightReadiness: 0)
                    },
                    estimatedSeconds: 0, effectiveVolume: [:], leadingMuscle: nil, scale: 0, reasons: [])
            }
            outcomes[dayID] = DayOutcome(dayID: dayID, kind: kind, cause: cause,
                                         losesPlannedVolume: false, session: session)
        }
        return WeekPlan(days: outcomes, statusLines: [])
    }
}

extension WeekPlanSnapshot: Codable {
    enum CodingKeys: String, CodingKey { case version = "v", days }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            // Бросаем, а не молчим: разобрать чужую версию нечем, и вызывающая
            // сторона обязана увидеть это явно, чтобы обойтись с ней как с
            // отсутствующим снимком (§20.6).
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "версия снимка \(version), поддерживается \(Self.currentVersion)")
        }
        days = try c.decode([String: Day].self, forKey: .days)
    }
}
