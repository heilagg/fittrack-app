//  CycleHistory — журнал `cycle_events` в измеренные длины циклов (SPEC §11.3).
//
//  «Цикл — это интервал, а не событие»: измеренный цикл — расстояние между
//  двумя соседними `period_start`. Здесь же живёт дедупликация (сценарий 22:
//  две записи `period_start` в один день — идемпотентность) и отбрасывание
//  перерывов длиннее 90 дней (сценарий 19a): такой интервал не цикл, а пропуск
//  в записях, и не входит ни в среднее, ни в `dataFactor`.
//
//  Всё здесь работает от полного упорядоченного по дате списка событий, а не
//  от порядка вставки — это даёт бесплатно и идемпотентность (сценарий 22),
//  и корректный пересчёт задним числом (сценарий 21): PhaseResolver и
//  ConfidenceModel видят один и тот же канонический список независимо от
//  того, в каком порядке события пришли с сервера.
extension Cycle {

    /// SPEC §11.3: цикл длиннее этого — перерыв в записях, не цикл.
    public static let breakThresholdDays = 90

    /// Уникальные даты `period_start`, отсортированные по возрастанию.
    static func periodStartDays(from events: [CycleEvent]) -> [CalendarDay] {
        Array(Set(events.filter { $0.kind == .periodStart }.map(\.occurredOn))).sorted()
    }

    /// Все измеренные длины циклов за всё время, за вычетом перерывов
    /// (SPEC §11.3, §19a). Порядок — хронологический (от старого к новому);
    /// нужен и для `dataFactor` (весь список), и как источник окна для
    /// `regularityFactor`/`LengthEstimator` (последние 6, см. `CycleWindow`).
    public static func measuredLengths(from events: [CycleEvent]) -> [Int] {
        let starts = periodStartDays(from: events)
        guard starts.count >= 2 else { return [] }
        return zip(starts, starts.dropFirst()).compactMap { start, next in
            let length = start.days(until: next)
            return length <= breakThresholdDays ? length : nil
        }
    }

    /// SPEC §11.1: `menstrualEnd` для ТЕКУЩЕГО (последнего начатого) цикла —
    /// период по `period_end` после последнего `period_start`, если он есть;
    /// иначе заявленная длительность менструации; иначе 5.
    ///
    /// `period_end` — ПОСЛЕДНИЙ ДЕНЬ КРОВОТЕЧЕНИЯ, а не первый чистый, отсюда
    /// `+ 1` (SPEC §11.1, оговорено там явно: обратное прочтение сдвинуло бы
    /// все последующие границы фаз на день, а по самому полю их не различить).
    public static func menstrualEnd(events: [CycleEvent], profile: CycleProfile) -> Int {
        guard let lastStart = periodStartDays(from: events).last else {
            return profile.typicalPeriodLengthDays ?? 5
        }
        let end = events
            .filter { $0.kind == .periodEnd && $0.occurredOn >= lastStart }
            .map(\.occurredOn)
            .min()
        if let end {
            return max(1, lastStart.days(until: end) + 1)
        }
        return profile.typicalPeriodLengthDays ?? 5
    }

    /// Номер дня в текущем цикле (1 — день `period_start`). `nil`, если
    /// опорной даты нет вовсе (SPEC §11.3, «опорной даты нет»).
    public static func cycleDay(events: [CycleEvent], asOf today: CalendarDay) -> Int? {
        guard let lastStart = periodStartDays(from: events).last else { return nil }
        return max(1, lastStart.days(until: today) + 1)
    }
}
