//  PhaseResolver — на какой день цикла какая фаза (SPEC §11.1).
//
//  Границы разрешаются в порядке объявления Phase.allCases, и фаза не может
//  начаться раньше, чем закончилась предыдущая: на коротких циклах
//  фолликулярная схлопывается первой (сценарий 18a, цикл 21 день). Алгоритм —
//  скользящий курсор: у каждой фазы номинальный диапазон из формулы §11.1,
//  но фактический старт — не раньше конца предыдущей фазы, а фактический
//  конец — не раньше фактического старта минус один (пустой диапазон —
//  допустимый результат). Курсор всегда продвигается вперёд, поэтому
//  покрытие дней остаётся сплошным и без пересечений при любой длине цикла.
//
//  Поздняя лютеиновая — единственная фаза без верхней границы по смыслу
//  (SPEC §11.1: «до начала менструации»); `expectedLength` — это ПРОГНОЗ, не
//  жёсткий потолок, поэтому дни просрочки (SPEC §11.3, recencyFactor) по-прежнему
//  разрешаются в позднюю лютеиновую, а не в неопределённость. Именно
//  recencyFactor, а не PhaseResolver, снижает уверенность в такие дни.
extension Cycle {

    /// Фаза для дня `day` (1 — день `period_start`) цикла ожидаемой длины
    /// `expectedLength` с менструацией длиной `menstrualEnd` дней.
    /// `day < 1` защитно приводится к 1 — день `period_start` есть всегда,
    /// раз фаза вообще вычисляется.
    public static func phase(forDay day: Int, expectedLength: Int, menstrualEnd: Int) -> Phase {
        let day = max(1, day)
        let ovulationDay = expectedLength - 14

        let nominal: [(Phase, Int, Int)] = [
            (.menstrual, 1, menstrualEnd),
            (.follicular, menstrualEnd + 1, ovulationDay - 2),
            (.ovulatory, ovulationDay - 1, ovulationDay + 2),
            (.earlyLuteal, ovulationDay + 3, ovulationDay + 9),
            (.lateLuteal, ovulationDay + 10, expectedLength),
        ]

        var cursor = 1
        var last: (phase: Phase, start: Int, end: Int) = (.lateLuteal, 1, 0)
        for (phase, nominalStart, nominalEnd) in nominal {
            let actualStart = max(nominalStart, cursor)
            let actualEnd = max(nominalEnd, actualStart - 1)
            if actualStart <= actualEnd, day >= actualStart, day <= actualEnd {
                return phase
            }
            last = (phase, actualStart, actualEnd)
            cursor = actualEnd + 1
        }
        // Просрочка: день дальше последней разрешённой границы (обычно
        // поздней лютеиновой) — фаза не сбрасывается в неопределённость,
        // остаётся последней; recencyFactor отдельно роняет уверенность.
        return last.phase
    }
}
