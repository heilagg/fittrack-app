//  Фасад валидатора: один вызов, один отчёт.
//
//  Существует затем, чтобы порядок проверок был свойством библиотеки, а не
//  исполняемого файла: порядок несущий — покрытие §20.11 вызывает сборку, и
//  запускать её по разметке, которая не прошла §6.2, значит собирать тренировку
//  из заведомо кривых кандидатов и получать находки, не имеющие отношения к
//  покрытию.

import FitContent

public struct ValidationReport: Sendable {
    public let findings: [Finding]
    public let coverage: CoverageCheck.Summary
    public let exerciseCount: Int
    public let vectorCount: Int
    public let stretchCount: Int

    public var passed: Bool { findings.isEmpty }
    /// Строки для вывода, отсортированные: порядок находок обязан не зависеть
    /// от обхода словарей, иначе два прогона на одной разметке дают разный diff.
    public var lines: [String] { findings.map(\.line).sorted() }
}

public enum Validator {

    public static func run(_ library: ContentLibrary) -> ValidationReport {
        let findings = FindingCollector()
        SchemaChecks.run(library, into: findings)
        VectorChecks.run(library, into: findings)
        let coverage = CoverageCheck.run(library, into: findings)
        return ValidationReport(
            findings: findings.findings,
            coverage: coverage,
            exerciseCount: library.exercises.count,
            vectorCount: library.vectors.vectors.count,
            stretchCount: library.stretches.count)
    }
}
