//  Правило покрытия §20.11 и список заведомо неполных комбинаций.
//
//  Таблица векторов в каждом тесте содержит только нужные пары: валидатор
//  строит сессию лишь там, где вектор есть, поэтому набор проверяемых
//  комбинаций задаётся таблицей. Так тест утверждает про одну комбинацию, а не
//  про триста.

import XCTest
import FitCore
import FitContent
import ContentValidator

final class CoverageCheckTests: XCTestCase {

    private func run(_ library: ContentLibrary) -> [Finding] {
        let collector = FindingCollector()
        _ = CoverageCheck.run(library, into: collector)
        return collector.findings
    }

    private func summary(_ library: ContentLibrary) -> CoverageCheck.Summary {
        CoverageCheck.run(library, into: FindingCollector())
    }

    // MARK: - Пустая библиотека

    func test_emptyLibraryIsReported() {
        let found = run(Fixtures.library([], [Fixtures.vector(.lower, nil, Fixtures.lowerShares)]))
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("библиотека пуста"), found[0].message)
    }

    // MARK: - Полное правило

    func test_lowerDayPassesOnEveryLevel() {
        // Шесть упражнений на собственном весе: пять паттернов, пять семей —
        // хватает и на пустом профиле, значит и на двух остальных (§20.11).
        // Сборка отдаёт три упражнения с тремя паттернами, и это ПОЛНЫЙ проход:
        // числового порога у правила нет (§20.11).
        let library = Fixtures.library(Fixtures.bodyweightLower,
                                       [Fixtures.vector(.lower, nil, Fixtures.lowerShares)])
        XCTAssertEqual(run(library), [])
        XCTAssertEqual(summary(library).passed, EquipmentLevel.allCases.count,
                       "по одной сборке на уровень, и все полные")
    }

    func test_pushDayPassesOnEveryLevel() {
        let library = Fixtures.library(Fixtures.bodyweightPush + Fixtures.bodyweightLower,
                                       [Fixtures.vector(.push, nil, Fixtures.pushShares)])
        XCTAssertEqual(run(library), [])
    }

    // MARK: - Ослабление вне списка исключений

    func test_relaxationOutsideTheDeclaredListIsReported() {
        // День низа на двух упражнениях одного паттерна: трёх паттернов нет, и
        // (lower, любой уровень) в списке §20.11 не объявлен.
        let thin = [
            Fixtures.exercise("squat_a", pattern: .squat, contributions: [.quads: 1.0]),
            Fixtures.exercise("squat_b", pattern: .squat, contributions: [.gluteMax: 1.0]),
        ]
        let library = Fixtures.library(thin,
                                       [Fixtures.vector(.lower, nil, Fixtures.lowerShares)])
        let found = run(library)
        XCTAssertFalse(found.isEmpty, "правило покрытия обязано упасть")
        XCTAssertTrue(found.allSatisfy { $0.rule == "§20.11" })
        XCTAssertTrue(found.contains { $0.subject.contains("home_bodyweight") },
                      "падает в том числе на нижнем профиле: \(found.map(\.subject))")
    }

    // MARK: - Список заведомо неполных комбинаций

    func test_relaxationInsideTheDeclaredListIsAccepted() {
        // Тяга без турника и без гантелей недостижима физически: (pull,
        // home_bodyweight) объявлен заведомо неполным (§20.11). На двух верхних
        // уровнях тот же день обязан собираться полностью.
        let library = Fixtures.library(Fixtures.full,
                                       [Fixtures.vector(.pull, nil, Fixtures.pullShares)])
        let found = run(library)
        XCTAssertEqual(found.filter { $0.subject.contains("home_bodyweight") }, [],
                       "ослабление на объявленной комбинации ошибкой не является")
        XCTAssertGreaterThan(summary(library).relaxedInDeclared, 0,
                            "ослабление посчитано, а не потеряно")
    }

    func test_declaredCombinationWithoutVectorsIsNotCalledRedundant() {
        // У (pull, home_bodyweight) исключение объявлено, но вектора тяги в
        // таблице нет — ни одна сборка не запускалась, и «проходит полностью»
        // утверждать нечем. Дыру в таблице называет VectorChecks, и второй раз,
        // да ещё требованием убрать исключение, она называться не должна.
        let library = Fixtures.library(Fixtures.full,
                                       [Fixtures.vector(.lower, nil, Fixtures.lowerShares)])
        XCTAssertFalse(run(library).contains { $0.message.contains("строку пора убрать") },
                       "исключение без сборок лишним не объявляется")
    }

    func test_declaredCombinationThatFullyPassesIsReported() {
        // Тяга на собственном весе вдруг набирает три паттерна — значит строке
        // (pull, home_bodyweight) больше нечего оправдывать, и §20.11 требует
        // её убрать. Физиологичность этих упражнений здесь не при чём:
        // проверяется реакция валидатора на устаревшее исключение.
        var exercises = Fixtures.bodyweightLower + Fixtures.bodyweightPush
        exercises += [
            Fixtures.exercise("towel_row", pattern: .pullH,
                              contributions: [.lats: 0.5, .trapsMid: 0.3, .biceps: 0.2]),
            Fixtures.exercise("prone_y_raise", pattern: .pullV,
                              contributions: [.trapsMid: 0.5, .rearDelts: 0.5]),
            Fixtures.exercise("prone_curl", pattern: .isolation,
                              contributions: [.biceps: 0.8, .forearms: 0.2]),
        ]
        let library = Fixtures.library(exercises,
                                       [Fixtures.vector(.pull, nil, Fixtures.pullShares)])
        let found = run(library)
        XCTAssertTrue(found.contains { $0.message.contains("строку пора убрать") },
                      "устаревшее исключение обязано быть названо: \(found.map(\.line))")
    }

    func test_emptySessionIsReportedEvenInsideTheDeclaredList() {
        // На пустом профиле гантельная тяга невыполнима, и кроме неё в
        // библиотеке ничего нет: тренировки нет вовсе. Пустая тренировка не
        // допускается нигде, включая объявленно неполные комбинации.
        let library = Fixtures.library(Fixtures.pull,
                                       [Fixtures.vector(.pull, nil, Fixtures.pullShares)])
        let found = run(library)
        XCTAssertTrue(found.contains {
            $0.subject.contains("home_bodyweight") && $0.message.contains("не собралась")
        }, "ожидалась находка о пустой тренировке: \(found.map(\.line))")
    }

    // MARK: - Оси правила

    func test_coverageRunsEveryLevelForEveryPairWithAVector() {
        let rows = [Fixtures.vector(.lower, nil, Fixtures.lowerShares),
                    Fixtures.vector(.lower, .gluteMax,
                                    [.gluteMax: 0.4, .quads: 0.25, .hamstrings: 0.25,
                                     .gluteMed: 0.10])]
        let library = Fixtures.library(Fixtures.bodyweightLower, rows)
        XCTAssertEqual(summary(library).builds, rows.count * EquipmentLevel.allCases.count,
                       "сборка идёт по всем трём осям правила")
    }

    func test_declaredIncompleteListMatchesTheSpecTable() {
        // Список — копия §20.11, и расти он обязан только правкой SPEC.
        XCTAssertEqual(CoverageCheck.declaredIncomplete, [
            .init(kind: .pull, level: .bodyweight),
            .init(kind: .upper, level: .bodyweight),
            .init(kind: .fullBody, level: .bodyweight),
        ])
    }
}
