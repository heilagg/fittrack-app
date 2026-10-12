//  Эталонные JSON пресетов инвентаря (SPEC §5 шаг 7, §6.6) для веб-клиента.
//
//  Источник правды — `EquipmentLevel`: три уровня одновременно пресеты
//  онбординга и оси правила покрытия §20.11. Веб пишет строку
//  `equipment_profiles` напрямую (§20.6), и копия пресетов в TS не должна
//  разойтись с тем, на чём валидатор проверяет покрытие. Файлы
//  `Contract/fixtures/equipment_preset_*.json` — это строка таблицы без `id` и
//  `user_id`; TS-тест `presets.test.ts` читает их и сверяет с построителем.
//
//  Перевыгрузка: FITCONTENT_REGENERATE_FIXTURES=1 swift test --filter EquipmentPresetFixtureTests

import XCTest
import Foundation
import FitCore
@testable import FitContent

final class EquipmentPresetFixtureTests: XCTestCase {

    private struct Row: Codable, Equatable {
        var name: String
        var isDefault: Bool
        var dumbbellsKg: [Double]
        var platesKg: [Double]
        var barbellKg: Double?
        var machineStepKg: Double?
        var hasKettlebells: Bool
        var kettlebellsKg: [Double]
        var bands: Bool
        var pullupBar: Bool
        var bench: String?
        var stepPlatform: Bool
        var plyoBox: Bool
        var cableMachine: Bool
        var machines: [String]

        enum CodingKeys: String, CodingKey {
            case name, isDefault = "is_default", dumbbellsKg = "dumbbells_kg",
                 platesKg = "plates_kg", barbellKg = "barbell_kg",
                 machineStepKg = "machine_step_kg", hasKettlebells = "has_kettlebells",
                 kettlebellsKg = "kettlebells_kg", bands, pullupBar = "pullup_bar", bench,
                 stepPlatform = "step_platform", plyoBox = "plyo_box",
                 cableMachine = "cable_machine", machines
        }

        init(_ level: EquipmentLevel) {
            let w = level.equipment, a = level.availability
            name = level.title
            isDefault = true
            dumbbellsKg = w.dumbbellsKg
            platesKg = w.platesKg
            barbellKg = w.barbellKg
            machineStepKg = w.machineStepKg
            hasKettlebells = a.hasKettlebells
            kettlebellsKg = a.hasKettlebells ? w.kettlebellsKg : []
            bands = a.bands
            pullupBar = a.pullupBar
            bench = a.bench?.rawValue
            stepPlatform = a.stepPlatform
            plyoBox = a.plyoBox
            cableMachine = a.cableMachine
            machines = a.machines.sorted()
        }
    }

    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FitContentTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // FitContent
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // корень
            .appendingPathComponent("Contract/fixtures", isDirectory: true)
    }

    private func encode(_ row: Row) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(row) + Data("\n".utf8)
    }

    func test_presetsMatchFixtures() throws {
        let regenerate = ProcessInfo.processInfo.environment["FITCONTENT_REGENERATE_FIXTURES"] == "1"
        for level in EquipmentLevel.allCases {
            let url = Self.directory.appendingPathComponent("equipment_preset_\(level.rawValue).json")
            let fresh = try encode(Row(level))
            if regenerate {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try fresh.write(to: url)
                continue
            }
            let stored = try XCTUnwrap(try? Data(contentsOf: url),
                                       "нет эталона \(url.lastPathComponent); FITCONTENT_REGENERATE_FIXTURES=1")
            XCTAssertEqual(String(decoding: stored, as: UTF8.self), String(decoding: fresh, as: UTF8.self),
                           "эталон \(url.lastPathComponent) устарел: пресет изменился, а файл нет")
        }
    }
}
