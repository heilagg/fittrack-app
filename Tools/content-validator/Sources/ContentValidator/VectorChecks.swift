//  Проверки таблицы целевых векторов (SPEC §7.3, правила 1–4; §20.11).

import FitCore
import FitContent

public enum VectorChecks {

    /// Тот же допуск, что у вкладов: §7.3 п.1 прямо говорит «сумма ≈ 1.0, как у
    /// muscle_contributions (§6.3)».
    public static let shareSumTolerance = SchemaChecks.contributionSumTolerance

    public static func run(_ library: ContentLibrary, into findings: FindingCollector) {
        let table = library.vectors

        // §7.3 п.4 и §20.11: вектор есть у каждой из ста пар.
        let missing = DayVectorTable.allKeys.filter { table.vectors[$0] == nil }
        if !missing.isEmpty {
            findings.add(rule: "§20.11", subject: "таблица векторов",
                         "нет вектора у \(missing.count) пар из \(DayVectorTable.allKeys.count); "
                         + "первые: " + missing.prefix(5).map(name).joined(separator: ", "))
        }

        for (key, shares) in table.vectors.sorted(by: { name($0.key) < name($1.key) }) {
            let subject = name(key)

            // `rest` и `stretch` вектора не несут (§7.2): у них пустой вектор по
            // построению `PlannedDay.isStrength`, и строка таблицы для них
            // означает, что размечали не тот день.
            if !DayVectorTable.vectorBearingKinds.contains(key.kind) {
                findings.add(rule: "§7.2", subject: subject,
                             "тип дня \(key.kind.rawValue) вектора не несёт")
                continue
            }

            checkShares(shares, subject: subject, into: findings)
            checkAccentIsLargest(key: key, shares: shares, subject: subject, into: findings)
        }
    }

    // MARK: - §7.3 п.1

    private static func checkShares(
        _ shares: [MuscleSlug: Double], subject: String, into findings: FindingCollector
    ) {
        guard !shares.isEmpty else {
            return findings.add(rule: "§7.3", subject: subject, "вектор пуст")
        }
        for (muscle, share) in shares.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where share < 0 {
            findings.add(rule: "§7.3", subject: subject,
                         "отрицательная доля \(muscle.rawValue): \(SchemaChecks.rounded(share))")
        }
        let sum = shares.values.reduce(0, +)
        if abs(sum - 1.0) > shareSumTolerance {
            findings.add(rule: "§7.3", subject: subject,
                         "сумма долей \(SchemaChecks.rounded(sum)) вместо ≈ 1.0")
        }
    }

    // MARK: - §7.3 п.2

    /// «У вектора с акцентом доля акцентной мышцы — наибольшая». Ничья читается
    /// как нарушение: правило существует затем, чтобы ведущей мышцей дня была
    /// акцентная и от её доли считался `S_эфф`, а при равенстве «наибольших»
    /// двое, и масштаб сессии перестаёт быть определён однозначно.
    private static func checkAccentIsLargest(
        key: DayVectorKey, shares: [MuscleSlug: Double], subject: String,
        into findings: FindingCollector
    ) {
        guard let accent = key.accent else { return }
        guard let accentShare = shares[accent], accentShare > 0 else {
            return findings.add(rule: "§7.3", subject: subject,
                                "акцентная мышца \(accent.rawValue) в своём же векторе "
                                + "отсутствует или нулевая")
        }
        let rivals = shares.filter { $0.key != accent && $0.value >= accentShare }
        guard !rivals.isEmpty else { return }
        let names = rivals.keys.map(\.rawValue).sorted().joined(separator: ", ")
        findings.add(rule: "§7.3", subject: subject,
                     "доля акцента \(SchemaChecks.rounded(accentShare)) не наибольшая: "
                     + "не меньше у \(names)")
    }

    public static func name(_ key: DayVectorKey) -> String {
        "(\(key.kind.rawValue), \(key.accent?.rawValue ?? "без акцента"))"
    }
}
