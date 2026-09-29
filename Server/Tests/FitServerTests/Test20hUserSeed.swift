//  Тест 20h (§20.15): `userSeed`, вычисленный по §20.8, совпадает со значением,
//  вычисленным независимой реализацией на другом языке.
//
//  Формулировка §20.15 названа «защитой контракта хеша», и слово «независимой»
//  здесь несущее. Сверка нашей реализации с собой доказывает только то, что она
//  не поменялась с прошлого запуска, — а §20.8 обещает больше: сменить seed
//  невозможно НИКОГДА, потому что любая правка любого шага разом изменит подбор
//  упражнений у всех существующих пользователей без единой видимой причины.
//
//  Поэтому ожидаемые значения не вычисляются здесь и не берутся из Swift-кода.
//  Они посчитаны `Tools/user-seed-reference/user_seed.py` — реализацией,
//  написанной из текста §20.8 и не заимствующей у нашей ни шага, — и сверены
//  третьим инструментом (`openssl dgst -sha256`), чтобы «независимая» не
//  означало «одна другая». Числа вморожены в этот файл: скрипт, вызываемый из
//  теста, сделал бы `swift test` зависимым от наличия Python, а §20.15 требует
//  сверки, а не запуска.
//
//  Переcчитать набор: `python3 Tools/user-seed-reference/user_seed.py`.
//  Если хоть одна строка разойдётся — это не падение теста, это смена
//  контракта, и чинить нужно не число здесь.

import Testing
import Foundation
import FitCore
@testable import FitServer

@Suite("20h: userSeed против независимой реализации (§20.8, §20.15)")
struct Test20hUserSeed {

    /// Вектора и их значения — вывод `Tools/user-seed-reference/user_seed.py`.
    /// Границы (`nil`, максимум) стоят первыми: они ловят порядок байт, ради
    /// которого §20.8 называет big-endian явно.
    static let vectors: [(uuid: String, seed: UInt64)] = [
        ("00000000-0000-0000-0000-000000000000", 1_349_170_572_285_598_868),
        ("ffffffff-ffff-ffff-ffff-ffffffffffff", 1_411_960_639_344_678_146),
        ("0f7a1c3e-2b4d-4a6f-8c9e-1d2f3a4b5c6d", 75_365_949_381_845_203),
        ("a1b2c3d4-e5f6-4789-abcd-ef0123456789", 2_465_803_210_542_115_537),
        ("7c9e6679-7425-40de-944b-e07fc1f90ae7", 7_140_140_672_758_920_158)
    ]

    @Test("совпадает с независимой реализацией на каждом векторе",
          arguments: Test20hUserSeed.vectors)
    func matchesReferenceImplementation(vector: (uuid: String, seed: UInt64)) {
        #expect(Mapping.userSeed(canonicalUUID: vector.uuid) == vector.seed)
    }

    @Test("UUID приводится к нижнему регистру, а не берётся как есть")
    func lowercasesUUID() {
        // `UUID.uuidString` печатает ВЕРХНИЙ регистр, Postgres — нижний.
        // Если бы регистр не приводился, один и тот же пользователь получал бы
        // разный подбор в зависимости от того, чьей стороной посчитан seed.
        let uuid = UUID(uuidString: "7c9e6679-7425-40de-944b-e07fc1f90ae7")!
        #expect(uuid.uuidString == uuid.uuidString.uppercased())
        #expect(Mapping.userSeed(userID: uuid) == 7_140_140_672_758_920_158)
    }

    @Test("верхний регистр на входе даёт ДРУГОЙ seed")
    func caseChangesSeed() {
        // Утверждение обратное предыдущему и нужно отдельно: без него
        // «приводится к нижнему» прошло бы и у реализации, которая регистр
        // игнорирует вовсе, — а такая реализация тихо разошлась бы с §20.8
        // на первом же клиенте, который канонизирует иначе.
        let upper = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
        #expect(Mapping.userSeed(canonicalUUID: upper) != 7_140_140_672_758_920_158)
    }

    @Test("seed доезжает до Planner.daySeed без потери разрядов")
    func feedsDaySeed() {
        // §20.8 существует ради одного потребителя. Разные пользователи в один
        // день обязаны получать разные seed дня — иначе детерминизм §18 33a
        // есть, а различимости пользователей нет.
        let day = CalendarDay(year: 2026, month: 9, day: 29)
        let a = Planner.daySeed(userSeed: Mapping.userSeed(canonicalUUID: Self.vectors[0].uuid), day: day)
        let b = Planner.daySeed(userSeed: Mapping.userSeed(canonicalUUID: Self.vectors[1].uuid), day: day)
        #expect(a != b)
    }
}
