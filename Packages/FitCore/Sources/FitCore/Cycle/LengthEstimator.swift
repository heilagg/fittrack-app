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

    /// SPEC §11.3, worked example: {27,28,28,29,45} → Q1=28, Q3=29,
    /// границы [26.5, 30.5], 45 отбрасывается, 27 остаётся.
    static func rejectingOutliers(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return values }
        let sorted = values.map(Double.init).sorted()
        let q1 = quantile(0.25, of: sorted)
        let q3 = quantile(0.75, of: sorted)
        let iqr = q3 - q1
        let lower = q1 - 1.5 * iqr
        let upper = q3 + 1.5 * iqr
        return values.filter { Double($0) >= lower && Double($0) <= upper }
    }

    /// Последние `recentCyclesWindow` измеренных длин (хронологически, от
    /// старого к новому — `measuredLengths` уже в этом порядке) с
    /// отброшенными выбросами. Общий вход для `regularityFactor` и
    /// `expectedLength`.
    static func recentFilteredLengths(_ measuredLengths: [Int]) -> [Int] {
        rejectingOutliers(Array(measuredLengths.suffix(recentCyclesWindow)))
    }

    /// SPEC §11.1/§11.3: ожидаемая длина цикла — среднее по отфильтрованному
    /// окну, если есть хотя бы один измеренный цикл; иначе заявленная на
    /// онбординге длина; иначе 28 (правка, закрывшая этот пробел до
    /// реализации — см. SPEC §11.1).
    public static func expectedLength(measuredLengths: [Int], profile: CycleProfile) -> Int {
        let filtered = recentFilteredLengths(measuredLengths)
        guard !filtered.isEmpty else {
            return profile.typicalCycleLengthDays ?? 28
        }
        let mean = Double(filtered.reduce(0, +)) / Double(filtered.count)
        return Int(mean.rounded())
    }
}
