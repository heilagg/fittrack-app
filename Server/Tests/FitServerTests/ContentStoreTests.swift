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

    /// Поза и шаблон из одной позы (§12.3).
    private func stretch(_ slug: String, seconds: Int = 60) -> (PoseSchema, StretchTemplateSchema) {
        let pose = PoseSchema(slug: "pose_\(slug)", name: "Поза", kind: .static, unilateral: true,
                              defaultSeconds: 30, muscles: [.gluteMax], patterns: [.hinge],
                              jointStress: [.knee: .medium], cues: ["Ровно"], illustration: "placeholder/stretch/x")
        let template = StretchTemplateSchema(slug: slug, name: "Шаблон", purpose: "Общая, после сна",
                                             items: [TemplateItem(pose: pose.slug, seconds: seconds)])
        return (pose, template)
    }

    private func store(_ exercises: [ExerciseSchema],
                       _ stretches: [(PoseSchema, StretchTemplateSchema)] = []) throws -> ContentStore {
        try ContentStore(library: ContentLibrary(exercises: exercises,
                                                vectors: DayVectorTable([]),
                                                poses: stretches.map(\.0),
                                                templates: stretches.map(\.1)))
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
        let before = try store([exercise("a")], [stretch("morning", seconds: 60)])
        let after = try store([exercise("a")], [stretch("morning", seconds: 90)])

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
        // Ключ в кавычках, а не подстрока: `equipment_labels` — поле показа
        // (§6.6), и слово `equipment` в нём законно; сам `equipment` — нет.
        for field in ["muscle_contributions", "joint_stress", "equipment", "load_type",
                      "fatigue_cost", "setup_seconds", "progression_family",
                      "family_load_ratio", "impact", "skill_level", "alternatives"] {
            #expect(!text.contains("\"\(field)\""), "\(field) в браузере не нужен (§20.1)")
        }
        #expect(text.contains("\"cues\"") && text.contains("\"common_errors\""))
    }

    @Test("Тело растяжки — объект {poses, templates}; без контента — оба пусты")
    func emptyStretchesAreAValidBody() throws {
        let store = try store([exercise("a")])
        #expect(String(decoding: store.stretches.bytes, as: UTF8.self) == #"{"poses":[],"templates":[]}"#)
        #expect(store.stretches.etag.count == 66)
    }

    @Test("Шаблон несёт длительность из поз; входы подбора поз наружу не едут (§12.3, §20.11)")
    func stretchBodyCarriesComputedDurationAndNoSelectionFields() throws {
        let store = try store([exercise("a")], [stretch("morning", seconds: 45)])
        let body = try JSONDecoder().decode(StretchContentDTO.self, from: store.stretches.bytes)
        #expect(body.templates.first?.durationSeconds == 90, "односторонняя поза — дважды")
        #expect(body.templates.first?.minutes == 2, "1.5 минуты — половина вверх")
        #expect(body.poses.first?.kind == "static")
        let text = String(decoding: store.stretches.bytes, as: UTF8.self)
        for field in ["muscles", "patterns", "joint_stress", "technique", "sources"] {
            #expect(!text.contains("\"\(field)\""), "\(field) — вход подбора, в браузер не едет")
        }
    }

    @Test("Реальные шаблоны: длительности из таблицы §12.2")
    func bundledTemplateMinutes() throws {
        let store = try ContentStore(library: try Content.loadBundled())
        let body = try JSONDecoder().decode(StretchContentDTO.self, from: store.stretches.bytes)
        let minutes = Dictionary(uniqueKeysWithValues: body.templates.map { ($0.slug, $0.minutes) })
        #expect(minutes == ["morning_mobility": 7, "evening_relax": 10, "neck_thoracic": 8, "hip_opening": 12,
                            "lower_back_pelvis": 10, "menstrual_gentle": 12, "full_stretch": 20,
                            "cardio_intervals": 9])
        #expect(body.poses.count == 18)
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

    // MARK: - Подпись снаряда (§6.6)

    @Test("Тело несёт equipment_labels из load_type и equipment (§6.6, §20.11)")
    func bodyCarriesEquipmentLabels() throws {
        let store = try store([exercise("a")])
        let decoded = try JSONDecoder().decode([ExerciseContentDTO].self, from: store.exercises.bytes)
        #expect(decoded.first?.equipmentLabels == ["Штанга", "Скамья"])
        let raw = try #require(String(data: store.exercises.bytes, encoding: .utf8))
        #expect(raw.contains("\"equipment_labels\""))
    }

    /// Слаги тренажёров — строки, и полноту каталога FitAPI против закрытого
    /// списка FitContent компилятор не проверит: проверяется здесь, где
    /// линкуются оба пакета. Заодно — на всей библиотеке: у каждой подписи нет
    /// голого слага (запасного пути `label(.machine)`), Смит подписан только
    /// тренажёром, у упражнений без снаряда подписей нет.
    @Test("Подписи на реальной библиотеке: каталог полон, Смит и собственный вес")
    func bundledLibraryLabels() throws {
        #expect(Set(EquipmentLabels.machineNames.keys) == Set(EquipmentLevel.machineSlugs))
        let library = try Content.loadBundled()
        let store = try ContentStore(library: library)
        let decoded = try JSONDecoder().decode([ExerciseContentDTO].self, from: store.exercises.bytes)
        #expect(decoded.count == library.exercises.count)
        let bySlug = Dictionary(uniqueKeysWithValues: decoded.map { ($0.slug, $0.equipmentLabels) })
        for c in library.candidates {
            let labels = try #require(bySlug[c.slug])
            #expect(!labels.contains { EquipmentLevel.machineSlugs.contains($0) }, "голый слаг у \(c.slug)")
            if c.equipment.isEmpty && (c.loadType == .bodyweight || c.loadType == .bodyweightLoaded) {
                #expect(labels.isEmpty, "\(c.slug): без снаряда строки нет")
            } else {
                #expect(!labels.isEmpty, "\(c.slug): снаряд есть, подписи нет")
            }
        }
        #expect(bySlug["squat_smith"] == ["Тренажёр Смита"])
        #expect(bySlug["cable_crossover"] == ["Блочный тренажёр (кроссовер)"])
        #expect(bySlug["pullup_band"] == ["Турник", "Резинка"])
        #expect(bySlug["pullup_assisted_machine"] == ["Гравитрон"])
    }
}
