//  Правила §7.3 пп. 1–4 и требование §20.11 о ста парах.

import XCTest
import FitCore
import FitContent
import ContentValidator

final class VectorChecksTests: XCTestCase {

    private func findings(_ rows: [DayVector]) -> [Finding] {
        let collector = FindingCollector()
        VectorChecks.run(Fixtures.library([], rows), into: collector)
        return collector.findings
    }

    /// Все сто пар: у каждой один и тот же вектор, у акцентных — акцент сверху.
    /// Содержательной разметкой это не является и быть не должно; проверяется
    /// только то, что полный набор пар правило о полноте проходит.
    private var allHundredPairs: [DayVector] {
        DayVectorTable.allKeys.map { key in
            guard let accent = key.accent else {
                return DayVector(key: key, shares: [.quads: 0.5, .gluteMax: 0.5])
            }
            var shares: [MuscleSlug: Double] = [accent: 0.6]
            let filler: MuscleSlug = accent == .quads ? .gluteMax : .quads
            shares[filler] = 0.4
            return DayVector(key: key, shares: shares)
        }
    }

    // MARK: - §20.11, полнота таблицы

    func test_theHundredPairsPassCompleteness() {
        XCTAssertEqual(findings(allHundredPairs), [])
    }

    func test_missingPairsAreReportedWithACount() {
        let rows = Array(allHundredPairs.dropLast(3))
        let found = findings(rows).filter { $0.rule == "§20.11" }
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("нет вектора у 3 пар из 100"), found[0].message)
    }

    // MARK: - §7.3 п.1

    func test_sharesMustSumToOne() {
        let rows = [Fixtures.vector(.lower, nil, [.quads: 0.5, .gluteMax: 0.2])]
        XCTAssertTrue(findings(rows).contains {
            $0.rule == "§7.3" && $0.message.contains("сумма долей")
        })
    }

    func test_negativeShareIsReported() {
        let rows = [Fixtures.vector(.lower, nil, [.quads: 1.2, .gluteMax: -0.2])]
        XCTAssertTrue(findings(rows).contains { $0.message.contains("отрицательная доля") })
    }

    func test_emptyVectorIsReported() {
        let rows = [Fixtures.vector(.lower, nil, [:])]
        XCTAssertTrue(findings(rows).contains { $0.message.contains("вектор пуст") })
    }

    // MARK: - §7.3 п.2, акцент наибольший

    func test_accentShareBelowAnotherIsReported() {
        let rows = [Fixtures.vector(.lower, .gluteMax,
                                    [.gluteMax: 0.3, .quads: 0.5, .hamstrings: 0.2])]
        let found = findings(rows).filter { $0.rule == "§7.3" }
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("не наибольшая"), found[0].message)
        XCTAssertTrue(found[0].message.contains("quads"), found[0].message)
    }

    func test_accentTieIsReportedToo() {
        // Ничья читается как нарушение: при двух «наибольших» масштаб сессии
        // перестаёт быть определён однозначно (§7.3 п.2).
        let rows = [Fixtures.vector(.lower, .gluteMax, [.gluteMax: 0.5, .quads: 0.5])]
        XCTAssertTrue(findings(rows).contains { $0.message.contains("не наибольшая") })
    }

    func test_accentMissingFromItsOwnVectorIsReported() {
        let rows = [Fixtures.vector(.lower, .calves, [.quads: 0.6, .gluteMax: 0.4])]
        XCTAssertTrue(findings(rows).contains {
            $0.message.contains("отсутствует или нулевая")
        })
    }

    func test_accentLargestPasses() {
        let rows = [Fixtures.vector(.lower, .gluteMax,
                                    [.gluteMax: 0.5, .quads: 0.3, .hamstrings: 0.2])]
        XCTAssertEqual(findings(rows).filter { $0.rule == "§7.3" }, [])
    }

    // MARK: - §7.2, типы без вектора

    func test_vectorForRestOrStretchIsReported() {
        let rows = [Fixtures.vector(.stretch, nil, [.quads: 1.0]),
                    Fixtures.vector(.rest, nil, [.quads: 1.0])]
        let found = findings(rows).filter { $0.rule == "§7.2" }
        XCTAssertEqual(found.count, 2, "ни отдых, ни растяжка вектора не несут")
    }
}
