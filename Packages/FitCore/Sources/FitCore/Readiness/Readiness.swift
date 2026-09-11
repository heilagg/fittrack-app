//  Readiness — сводный множитель готовности (SPEC §10).
//
//  readiness = clamp(1.0 + phaseTerm + checkinAdj×checkinScale + recoveryAdj,
//                    0.75, 1.10)
//
//  phaseTerm — ОДНО слагаемое, а не два: оверрайд подставляется вместо
//  фазовой поправки, а не складывается с ней, и живёт один день (SPEC §11.4).
//  Иначе одна и та же кнопка значила бы разное в разных фазах.
//
//  checkinScale = 1.0 + 0.6×(1 − confidence); 1.6 в режиме без фаз и когда
//  опорной даты нет. Чем меньше известно о цикле, тем больше веса у сегодняшнего
//  чек-ина. Пропущенный компонент чек-ина — нейтральный (0). Без фазы фазовая
//  составляющая равна нулю, оверрайд действует всё равно.
//
//  `recoveryAdj` — v2-данные HealthKit (HRV, сон), в MVP = 0. К модулю Recovery
//  (§8, утомление мышц) отношения не имеет, несмотря на имя.
//
//  Входы. От Cycle — `CycleState`: `effectivePhaseAdjustment` (неумноженный),
//  `cycleConfidence`, `phaseMode`, `hasAnchor`, `periodization`. От Recovery — его
//  готовый выход `RecoveryAdjustment` по мышцам, параметром, так же как Progression
//  принимает готовое число `weightReadiness` (§9.6). Не `FatigueState`: превратить сырое
//  утомление в поправку — это распад и пороги §8.1, работа Recovery, а не повод её
//  повторять. Функций Recovery этот модуль не вызывает.
//
//  Выход. Кроме самого числа — чистые функции композиции §10, которые Planner
//  вызывает, а не реализует заново:
//   - итоговый RIR: min(фаза + готовность, +1) + надбавка утомления;
//   - volumeFactor: min с fatigueFactor для утомлённой мышцы, иначе плановый
//     срез (фаза в phases, 3+1 без фаз, 1.0 без опорной даты);
//   - поправка подходов на сессию: ±1 по порогам 0.9 / 1.05, +1 — не на
//     упражнение с утомлённой мышцей.
//   - готовность для веса упражнения (`weightReadiness`): надбавка выше 1.0
//     срезается, если хоть одна нагруженная мышца получила от утомления
//     надбавку RIR (§8.2, fatigue > 1.8). Вес следует порогу RIR, подходы —
//     порогу объёма. Planner проставляет результат в
//     `workout_exercises.weight_readiness` тем же расчётом, что и
//     `prescribed_kg`; оттуда FitData собирает `ExerciseSession.weightReadiness`
//     для Progression (§7.6). Дневное `value()` в Progression напрямую не идёт.
//  Композиция живёт здесь, рядом с §10, а не в Planner: сценарии 25, 25a, 25b
//  (§18) — чистые правила над числами, и тестировать их через весь подбор
//  тренировки было бы и дольше, и слабее.
//
//  Порядок: готовность первой, утомление — на её результат. Утомление режет
//  числа (объём и RIR, §8.2: «не блокирует»), и готовность не может поднять
//  срезанное; варианты отсекает только флаг боли (§8.4). Поэтому push не снимает
//  защиту утомления (сценарий 25).
//
//  Границы теста с SPEC §18: этот модуль закрывает 23, 23a (часть — «на
//  готовность действует»), 23b (часть — сама формула замены), 24a, 25, 25a,
//  25b, 25c — см. doc-комментарий Cycle.swift о разделении. 24b/24c проверены
//  в CycleTests: это чистая функция фазы × уверенность без чек-ина/оверрайда,
//  формула §10 им не нужна.
public enum Readiness {}

extension Readiness {

    /// SPEC §10: границы `clamp` итоговой готовности.
    public static let range = 0.75...1.10

    /// SPEC §10: `push`/`ease` → числовая поправка `phaseTerm`. `rest`
    /// численно приравнен к `ease` — если пользователь всё же начинает
    /// тренировку в день `rest`, готовность обязана на что-то опереться, хотя
    /// планировщик в этот день предлагает растяжку, а не тренировку.
    static func overrideAdjustment(_ override: Override) -> Double {
        switch override {
        case .push: return 0.08
        case .ease, .rest: return -0.10
        }
    }

    /// SPEC §10: `checkinAdjustment` — отсутствующий компонент нейтрален
    /// (эквивалентен ответу 3), поэтому пропущенный чек-ин или строка без
    /// него дают 0, а не штраф.
    static func checkinAdjustment(_ checkin: DailyCheckin) -> Double {
        Double((checkin.energy ?? 3) - 3) * 0.020
            + Double(3 - (checkin.soreness ?? 3)) * 0.015
            + Double((checkin.sleepQuality ?? 3) - 3) * 0.015
            + Double(3 - (checkin.stress ?? 3)) * 0.010
    }

    /// SPEC §10: `phaseUnknown` — режим без фаз или отсутствие опорной даты
    /// в режиме `phases`. Оба состояния возвращают `CycleState` с
    /// `periodization == nil`, но проверка идёт по `phaseMode`/`hasAnchor`
    /// напрямую — так же, как это сделано в `CycleState`, а не по `nil`
    /// производного поля, которое могло бы стать `nil` по другой причине.
    static func phaseUnknown(_ cycleState: CycleState) -> Bool {
        cycleState.phaseMode == .noPhases || !cycleState.hasAnchor
    }

    /// SPEC §10: `checkinScale` — растёт по мере падения уверенности; режим
    /// без фаз и отсутствие опорной даты (`phaseUnknown`) — предельный
    /// случай той же формулы (`confidence → 0`), а не отдельная ветка
    /// (сценарий 24a).
    static func checkinScale(cycleState: CycleState) -> Double {
        phaseUnknown(cycleState)
            ? 1.6
            : 1.0 + 0.6 * (1 - (cycleState.cycleConfidence ?? 0))
    }

    /// SPEC §10: сводное число готовности на день.
    ///
    /// `recoveryAdjustment` (HRV, сон — SPEC §15, v2) — не параметр: в MVP
    /// данных HealthKit ещё нет, добавлять пустой аргумент под будущую
    /// функциональность значило бы держать в публичном API вход, который
    /// сегодня ничего не может передать, кроме 0.
    public static func value(
        cycleState: CycleState,
        override: Override?,
        checkin: DailyCheckin
    ) -> Double {
        let phaseUnknown = phaseUnknown(cycleState)

        let phaseTerm: Double
        if let override {
            // §11.4: оверрайд ЗАМЕНЯЕТ фазовую поправку, не складывается с
            // ней, и проверяется раньше phaseUnknown — он действует и без
            // опорной даты, и в режиме без фаз (сценарий 23a).
            phaseTerm = overrideAdjustment(override)
        } else if phaseUnknown {
            phaseTerm = 0
        } else {
            phaseTerm = (cycleState.effectivePhaseAdjustment ?? 0) * (cycleState.cycleConfidence ?? 0)
        }

        let recoveryAdjustment = 0.0 // v2, SPEC §15 — HealthKit ещё не подключён
        let raw = 1.0
            + phaseTerm
            + checkinAdjustment(checkin) * checkinScale(cycleState: cycleState)
            + recoveryAdjustment

        return min(range.upperBound, max(range.lowerBound, raw))
    }
}
