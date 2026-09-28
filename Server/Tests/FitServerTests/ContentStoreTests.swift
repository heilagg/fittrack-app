//  Раздача контента и `ETag` (§20.11).
//
//  Обязательного номерного теста у §20.15 для контента нет, поэтому проверяются
//  ровно те три свойства, которые §20.11 объявляет следствиями своего решения
//  («из этого следуют ровно те три свойства, которые нужны»), плюс условный
//  запрос и состав тела.
//
//  swift-testing, а не XCTest: тот же выбор, что у 20b — XCTest подвешивает
//  async-тесты на Linux, а пакет существует ради Linux.

import Testing
import Foundation
import Crypto
import FitCore
import FitAPI
import FitContent
@testable import FitServer

@Suite("Контент и ETag (§20.11)")
struct ContentStoreTests {

    // MARK: - Фикстуры

    private func exercise(_ slug: String, cues: [String] = ["Рёбра вниз"],
                          rest: Int = 120) -> ExerciseSchema {
        ExerciseSchema(
            slug: slug, name: "Упражнение \(slug)", pattern: .hinge,
            muscleContributions: [.gluteMax: 1.0],
            equipment: [.benchFlat], loadType: .barbell,
            jointStress: Dictionary(uniqueKeysWithValues:
                Joint.allCases.map { ($0, JointStressLevel.none) }),
            defaultRestSeconds: rest, fatigueCost: 1.0,
            progressionFamily: slug, setupSeconds: 90,
            cues: cues, commonErrors: ["Переразгибание поясницы"],
            illustration: slug)
    }

    private func stretch(_ slug: String, minutes: Int = 7) -> StretchSchema {
        StretchSchema(slug: slug, name: "Шаблон \(slug)", durationMinutes: minutes,
                      purpose: "Общая, после сна")
    }

    private func store(_ exercises: [ExerciseSchema],
                       _ stretches: [StretchSchema] = []) throws -> ContentStore {
        try ContentStore(library: ContentLibrary(exercises: exercises,
                                                vectors: DayVectorTable([]),
                                                stretches: stretches))
    }

    // MARK: - Форма ETag

    @Test("ETag — сильный валидатор: SHA-256 отдаваемых байт, в кавычках, без W/")
    func etagIsAStrongSha256OfTheServedBytes() throws {
        let store = try store([exercise("a")])
        let payload = store.exercises

        #expect(!payload.etag.hasPrefix("W/"), "§20.11: сильный, не W/")
        #expect(payload.etag.hasPrefix("\"") && payload.etag.hasSuffix("\""))

        let hex = payload.etag.dropFirst().dropLast()
        #expect(hex.count == 64)
        let expected = SHA256.hash(data: payload.bytes)
            .map { String(format: "%02x", $0) }.joined()
        #expect(String(hex) == expected, "хеш считается от ТЕХ ЖЕ байт, что уходят в тело")
    }

    // MARK: - Свойство 1: правка контента ETag меняет

    @Test("Опечатка в cue меняет ETag — иначе правка не доедет до клиента")
    func aCueEditChangesTheEtag() throws {
        let before = try store([exercise("a", cues: ["Рёбра вниз"])])
        let after = try store([exercise("a", cues: ["Ребра вниз"])])
        #expect(before.exercises.etag != after.exercises.etag)
    }

    @Test("Правка длительности отдыха тоже меняет ETag")
    func aRestEditChangesTheEtag() throws {
        let before = try store([exercise("a", rest: 120)])
        let after = try store([exercise("a", rest: 90)])
        #expect(before.exercises.etag != after.exercises.etag)
    }

    // MARK: - Свойство 2: передеплой без правок ETag не меняет

    @Test("Та же разметка даёт тот же ETag: долгий кеш переживает выкатку")
    func theSameMarkupYieldsTheSameEtagAcrossProcesses() throws {
        let exercises = [exercise("b"), exercise("a"), exercise("c")]
        let first = try store(exercises)
        // Второй store — модель второго запуска процесса: тот же вход, другой
        // порядок файлов на входе, байты обязаны совпасть.
        let second = try store(exercises.reversed())
        #expect(first.exercises.etag == second.exercises.etag)
        #expect(first.exercises.bytes == second.exercises.bytes)
    }

    @Test("Порядок в теле — по слагу, а не по порядку на входе")
    func bodyOrderFollowsTheSlug() throws {
        let store = try store([exercise("c"), exercise("a"), exercise("b")])
        let decoded = try JSONDecoder().decode([ExerciseContentDTO].self,
                                              from: store.exercises.bytes)
        #expect(decoded.map(\.slug) == ["a", "b", "c"])
    }

    // MARK: - Свойство 3: у каждого пути свой ETag

    @Test("Правка шаблона растяжки не сбрасывает кеш библиотеки упражнений")
    func editingStretchesLeavesTheExercisesEtagAlone() throws {
        let before = try store([exercise("a")], [stretch("morning", minutes: 7)])
        let after = try store([exercise("a")], [stretch("morning", minutes: 10)])

        #expect(before.exercises.etag == after.exercises.etag, "библиотека не менялась")
        #expect(before.stretches.etag != after.stretches.etag, "растяжка менялась")
    }

    // MARK: - Тело

    @Test("Тело — голый массив, без конверта (§20.3)")
    func bodyIsABareArray() throws {
        let store = try store([exercise("a")])
        let text = String(decoding: store.exercises.bytes, as: UTF8.self)
        #expect(text.hasPrefix("["), "конверта нет: \(text.prefix(40))")
        #expect(!text.contains("\"data\""))
    }

    @Test("В тело не едут поля подбора §7.5")
    func bodyCarriesNoSelectionFields() throws {
        let store = try store([exercise("a")])
        let text = String(decoding: store.exercises.bytes, as: UTF8.self)
        for field in ["muscle_contributions", "joint_stress", "equipment",
                      "fatigue_cost", "setup_seconds", "progression_family",
                      "family_load_ratio", "impact", "skill_level", "alternatives"] {
            #expect(!text.contains(field), "\(field) в браузере не нужен (§20.1)")
        }
        #expect(text.contains("\"cues\"") && text.contains("\"common_errors\""))
    }

    @Test("Пустая растяжка — валидный пустой массив со своим ETag (до этапа В3)")
    func emptyStretchesAreAValidBody() throws {
        let store = try store([exercise("a")])
        #expect(String(decoding: store.stretches.bytes, as: UTF8.self) == "[]")
        #expect(store.stretches.etag.count == 66)
    }

    // MARK: - Условный запрос

    @Test("Совпавший If-None-Match даёт 304 без тела")
    func matchingIfNoneMatchYields304() throws {
        let store = try store([exercise("a")])
        let etag = store.exercises.etag
        #expect(store.result(for: .exercises, ifNoneMatch: etag) == .notModified(etag: etag))
    }

    @Test("Отсутствующий или чужой If-None-Match даёт тело")
    func absentOrStaleIfNoneMatchYieldsTheBody() throws {
        let store = try store([exercise("a")])
        let expected = ContentResult.body(store.exercises.bytes, etag: store.exercises.etag)
        #expect(store.result(for: .exercises, ifNoneMatch: nil) == expected)
        #expect(store.result(for: .exercises, ifNoneMatch: "\"00\"") == expected)
    }

    @Test("Сверка по RFC 9110: слабая форма, список, звёздочка")
    func ifNoneMatchFollowsTheRfc() throws {
        let store = try store([exercise("a")])
        let etag = store.exercises.etag
        let bare = String(etag.dropFirst().dropLast())

        // Клиент вправе прислать слабую форму нашего сильного валидатора:
        // If-None-Match сравнивается слабым правилом.
        #expect(ContentStore.matches("W/" + etag, etag))
        #expect(ContentStore.matches("\"other\", " + etag, etag))
        #expect(ContentStore.matches("*", etag))
        #expect(!ContentStore.matches(bare, etag), "без кавычек — не тот валидатор")
        #expect(!ContentStore.matches("", etag))
    }

    @Test("Два пути отвечают каждый своим ETag")
    func eachPathAnswersWithItsOwnEtag() throws {
        let store = try store([exercise("a")], [stretch("morning")])
        for path in ContentPath.allCases {
            guard case .body(_, let etag) = store.result(for: path, ifNoneMatch: nil) else {
                Issue.record("ожидалось тело для \(path.route)")
                continue
            }
            #expect(etag == store[path].etag)
        }
        #expect(store.exercises.etag != store.stretches.etag)
    }
}
