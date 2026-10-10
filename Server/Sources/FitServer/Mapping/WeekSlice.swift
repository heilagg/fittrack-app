//  Срез недели: `week_plans` и `planned_days` (SPEC §3.1, §7.2, §20.6).
//
//  ── Вектора в схеме нет, и это не упущение ────────────────────────────────
//
//  §20.6, обязанность 15: целевой вектор пары (тип дня, акцент) лежит в
//  `FitContent` (§7.3), а не в колонке. Довод — тот же, по которому §20.11
//  держит разметку в пакете: вектор принадлежит КОНТЕНТУ, и хранить его копию
//  у каждого дня значило бы, что правка таблицы векторов не доезжает до уже
//  сгенерированных недель, а расхождение видно только объёмом.
//
//  ── Пустой вектор — законное значение, а не ошибка слоя ───────────────────
//
//  Дыру в разметке называет ПЛАНИРОВЩИК, а не срез: `classify` отдаёт
//  `.vectorMissing` с причиной `markupMissing`, и строка статуса недели
//  печатается штатно (§7.3, правило 4). Поэтому здесь пара без вектора даёт
//  пустой словарь и молчит — уронить запрос значило бы сделать неделю
//  нечитаемой из-за одной незакрытой пары, а подставить чужой вектор значило бы
//  собрать тренировку не того дня.
//
//  У отдыха и растяжки вектор пуст по построению (`DayVectorTable` их не
//  несёт), и `classify` разбирает их раньше проверки вектора.

import FitCore
import FitContent

extension Mapping {

    /// Строка `planned_days` (§3.1).
    public struct PlannedDayRow: Sendable, Equatable {
        public var id: String
        public var date: CalendarDay
        public var sessionKind: String
        public var accentMuscle: String?
        public var status: String

        public init(id: String, date: CalendarDay, sessionKind: String,
                    accentMuscle: String? = nil, status: String = "planned") {
            self.id = id
            self.date = date
            self.sessionKind = sessionKind
            self.accentMuscle = accentMuscle
            self.status = status
        }
    }

    /// Строки недели → вход планировщика.
    ///
    /// Порядок и дедупликация не делаются: `planRemainingDays` нормализует
    /// неделю сам (`normalizedWeek`), и вторая нормализация здесь была бы вторым
    /// правилом порядка — ровно тем, чего §20.2 избегает.
    ///
    /// День с нераспознанным типом отбрасывается: `SessionKind` закрыт (§3.1), и
    /// день, тип которого мы не понимаем, нельзя ни собрать, ни назвать отдыхом.
    /// Он исчезнет из недели, и это заметно — в отличие от дня, подставленного
    /// наугад.
    public static func plannedDays(from rows: [PlannedDayRow], vectors: DayVectorTable) -> [PlannedDay] {
        rows.compactMap { row in
            guard let kind = SessionKind(rawValue: row.sessionKind) else { return nil }
            let accent = row.accentMuscle.flatMap(MuscleSlug.init(rawValue:))
            return PlannedDay(
                id: row.id,
                date: row.date,
                kind: kind,
                accent: accent,
                // §20.6, обязанность 15. `nil` из таблицы — пустой словарь:
                // про дыру скажет планировщик причиной `markupMissing`.
                vector: vectors.vector(kind: kind, accent: accent) ?? [:],
                status: PlannedDayStatus(rawValue: row.status) ?? .planned
            )
        }
    }
}
