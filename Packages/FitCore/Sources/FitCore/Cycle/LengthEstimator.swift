//  LengthEstimator — прогноз длины цикла (SPEC §11.3, «Скользящее среднее»).
//
//  Окно — последние 6 измеренных циклов, из которых отбрасываются выбросы
//  дальше 1.5×IQR от квартилей (метод квартилей — линейная интерполяция по
//  порядковым статистикам, R/NumPy default, «type 7»). То же отфильтрованное
//  окно, что и `regularityFactor` (см. SPEC §11.3, «Область подсчёта» —
//  правка, закрывшая этот пробел до реализации).
extension Cycle {

    /// SPEC §11.3: окно скользящего среднего.
    public static let recentCyclesWindow = 6

    /// Квартиль порядка `p` (0...1) методом линейной интерполяции по
    /// порядковым статистикам — R/NumPy default («type 7»). `values`
    /// обязаны быть отсортированы по возрастанию и непусты.
    static func quantile(_ p: Double, of values: [Double]) -> Double {
        guard values.count > 1 else { return values[0] }
        let h = Double(values.count - 1) * p
        let lower = Int(h.rounded(.down))
        let upper = min(lower + 1, values.count - 1)
        return values[lower] + (h - Double(lower)) * (values[upper] - values[lower])
    }

    /// SPEC §11.3: пол полосы отбрасывания — расстояние ОДНОГО значения от
    /// медианы, за которым его ещё нельзя звать выбросом.
    ///
    /// Отдельная константа от `regularSigmaDays`, хотя число сегодня то же:
    /// там σ — разброс всего набора, здесь — расстояние точки до медианы.
    /// Величины разные, и менять их следует независимо (ровно на смешении этих
    /// двух смыслов потолок регулярности и срабатывал на историях, которые
    /// таблица §11.3 называет регулярными).
    public static let outlierBandFloorDays = 2.0

    /// Окно измеренных длин, на котором работают и `expectedLength`, и
    /// `regularityFactor` (SPEC §11.3, «Область подсчёта»).
    ///
    /// `lengths` — то, что осталось после отбрасывания выбросов: по нему
    /// считаются среднее и σ. `unfiltered` — то же окно до отбрасывания: по
    /// нему `regularityFactor` решает, не пора ли применить потолок. Обе
    /// величины нужны вместе, потому что вопросы разные: «какой прогноз» и
    /// «насколько вообще предсказуема эта история».
    public struct CycleWindow: Sendable, Equatable {
        public var lengths: [Int]
        public var unfiltered: [Int]

        public init(lengths: [Int], unfiltered: [Int]) {
            self.lengths = lengths
            self.unfiltered = unfiltered
        }
    }

    /// SPEC §11.3, worked example: {27,28,28,29,45} → Q1=28, Q3=29,
    /// границы [26, 30.5] (нижняя расширена полом, см. ниже), 45 отбрасывается,
    /// 27 остаётся.
    ///
    /// Полоса никогда не уже медианы ± `outlierBandFloorDays` (SPEC §11.3).
    /// Без пола 1.5×IQR вырождается на почти одинаковых окнах: при IQR = 0
    /// границы схлопываются в медиану, и у истории 28, 28, 29, 27, 28, 28
    /// выбросами объявляются и 27, и 29 — то есть обычный разброс в один день
    /// не доезжал бы даже до среднего.
    public static func rejectingOutliers(_ values: [Int]) -> CycleWindow {
        guard values.count > 1 else { return CycleWindow(lengths: values, unfiltered: values) }
        let sorted = values.map(Double.init).sorted()
        let q1 = quantile(0.25, of: sorted)
        let q3 = quantile(0.75, of: sorted)
        let median = quantile(0.5, of: sorted)
        let iqr = q3 - q1
        let lower = min(q1 - 1.5 * iqr, median - outlierBandFloorDays)
        let upper = max(q3 + 1.5 * iqr, median + outlierBandFloorDays)
        let kept = values.filter { Double($0) >= lower && Double($0) <= upper }
        return CycleWindow(lengths: kept, unfiltered: values)
    }

    /// Последние `recentCyclesWindow` измеренных длин (хронологически, от
    /// старого к новому — `measuredLengths` уже в этом порядке) с
    /// отброшенными выбросами. Общий вход для `regularityFactor` и
    /// `expectedLength`.
    public static func recentWindow(_ measuredLengths: [Int]) -> CycleWindow {
        rejectingOutliers(Array(measuredLengths.suffix(recentCyclesWindow)))
    }

    /// SPEC §11.1/§11.3: ожидаемая длина цикла — среднее по отфильтрованному
    /// окну, если есть хотя бы один измеренный цикл; иначе заявленная на
    /// онбординге длина; иначе 28 (правка, закрывшая этот пробел до
    /// реализации — см. SPEC §11.1).
    public static func expectedLength(measuredLengths: [Int], profile: CycleProfile) -> Int {
        let filtered = recentWindow(measuredLengths).lengths
        guard !filtered.isEmpty else {
            return profile.typicalCycleLengthDays ?? 28
        }
        return Int(mean(of: filtered).rounded())
    }
}
