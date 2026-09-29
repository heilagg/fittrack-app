//  Тесты FitContent: загрузка JSON, построение индексов, срез §7.5.
//
//  Номерных сценариев §18 за контентом не закреплено (content-domain §4),
//  поэтому тесты здесь — на контракт загрузчика, а не на разметку. Проверки
//  самой разметки (суммы вкладов, полнота карты суставов, покрытие) живут в
//  Tools/content-validator и прогоняются на реальных файлах: тест, знающий
//  конкретные числа разметки, ломался бы при каждой переразметке и защищал бы
//  копию данных, а не алгоритм.
//
//  Данные тесты пишут во временный каталог, а не в ресурсы пакета: библиотеки
//  ещё нет, и фикстура в `Resources/` попала бы в бандл, который сервер
//  раздаёт как контент.

import XCTest
import FitCore
@testable import FitContent

final class FitContentTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fitcontent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    /// Канонический пример §6.2 — ровно тот, что лежит в `_schema.example.json`.
    private func hipThrust(slug: String = "hip_thrust_barbell") -> String {
        """
        {
          "slug": "\(slug)",
          "name": "Ягодичный мостик со штангой",
          "pattern": "hinge",
          "muscle_contributions": {
            "glute_max": 0.60, "hamstrings": 0.20, "quads": 0.10, "erectors": 0.10
          },
          "equipment": ["bench_flat"],
          "equipment_optional": ["pad"],
          "load_type": "barbell",
          "unilateral": false,
          "joint_stress": {
            "knee": "low", "lower_back": "medium", "shoulder": "none",
            "wrist": "none", "neck": "none", "hip": "medium", "ankle": "none"
          },
          "impact": "none",
          "skill_level": "intermediate",
          "default_rest_seconds": 120,
          "fatigue_cost": 1.0,
          "alternatives": ["glute_bridge_bw"],
          "progression_family": "hip_thrust",
          "family_load_ratio": 1.0,
          "setup_seconds": 90,
          "cues": ["Подбородок к груди"],
          "common_errors": ["Переразгибание поясницы"],
          "illustration": "\(slug)"
        }
        """
    }

    // MARK: - Схема §6.2

    func test_decodesTheCanonicalExampleFieldForField() throws {
        try write(hipThrust(), to: "exercises/hip_thrust_barbell.json")
        let library = try Content.load(from: root)

        let exercise = try XCTUnwrap(library.bySlug["hip_thrust_barbell"])
        XCTAssertEqual(exercise.pattern, .hinge)
        XCTAssertEqual(exercise.loadType, .barbell)
        XCTAssertEqual(exercise.skillLevel, .intermediate)
        XCTAssertEqual(exercise.impact, ExerciseImpact.none)
        XCTAssertEqual(exercise.muscleContributions[.gluteMax], 0.60)
        XCTAssertEqual(exercise.jointStress[.lowerBack], .medium)
        XCTAssertEqual(exercise.equipment, [.benchFlat])
        XCTAssertEqual(exercise.equipmentOptional, ["pad"])
        XCTAssertEqual(exercise.defaultRestSeconds, 120)
        XCTAssertEqual(exercise.familyLoadRatio, 1.0)
    }

    func test_jointStressCarriesAllSevenJointsIncludingNone() throws {
        try write(hipThrust(), to: "exercises/hip_thrust_barbell.json")
        let library = try Content.load(from: root)

        let exercise = try XCTUnwrap(library.bySlug["hip_thrust_barbell"])
        XCTAssertEqual(exercise.jointStress.count, Joint.allCases.count,
                       "§6.2: карта полная, все семь суставов")
        XCTAssertEqual(exercise.jointStress[.shoulder], JointStressLevel.none,
                       "«не грузит» — значение none, а не отсутствие ключа")
    }

    func test_restDefaultsToNinetySecondsWhenOmitted() throws {
        // §19.2 п.3 закрыт: 90 с — дефолт поля, разметка поднимает его по причине.
        let json = hipThrust().replacingOccurrences(of: "\"default_rest_seconds\": 120,",
                                                    with: "")
        try write(json, to: "exercises/hip_thrust_barbell.json")
        let library = try Content.load(from: root)

        XCTAssertEqual(library.bySlug["hip_thrust_barbell"]?.defaultRestSeconds, 90)
    }

    func test_machineRequirementKeepsItsSlug() throws {
        let json = hipThrust().replacingOccurrences(of: "[\"bench_flat\"]",
                                                    with: "[\"machine:leg_press\"]")
        try write(json, to: "exercises/hip_thrust_barbell.json")
        let library = try Content.load(from: root)

        XCTAssertEqual(library.bySlug["hip_thrust_barbell"]?.equipment, [.machine("leg_press")])
    }

    // MARK: - Что обязано падать здесь, а что — в валидаторе

    func test_unknownMuscleSlugFailsLoading() throws {
        let json = hipThrust().replacingOccurrences(of: "\"glute_max\"", with: "\"glutes\"")
        try write(json, to: "exercises/broken.json")

        XCTAssertThrowsError(try Content.load(from: root)) { error in
            guard case ContentError.malformedFile(let path, let reason) = error else {
                return XCTFail("ожидалась malformedFile, получено \(error)")
            }
            XCTAssertEqual(path, "exercises/broken.json")
            XCTAssertTrue(reason.contains("glutes"), "в ошибке названо значение: \(reason)")
        }
    }

    func test_equipmentValueOutsideTheDictionaryFailsLoading() throws {
        let json = hipThrust().replacingOccurrences(of: "\"bench_flat\"", with: "\"trap_bar\"")
        try write(json, to: "exercises/broken.json")

        XCTAssertThrowsError(try Content.load(from: root)) { error in
            guard case ContentError.malformedFile(_, let reason) = error else {
                return XCTFail("ожидалась malformedFile, получено \(error)")
            }
            XCTAssertTrue(reason.contains("trap_bar"), reason)
        }
    }

    func test_misspelledMachineSlugLoadsAndIsLeftToTheValidator() throws {
        // Опечатка в слаге ПРЕДСТАВИМА, поэтому загрузчик её пропускает:
        // закрытый список §6.6 проверяет валидатор (гейт CI), а не рантайм.
        let json = hipThrust().replacingOccurrences(of: "[\"bench_flat\"]",
                                                    with: "[\"machine:leg_pres\"]")
        try write(json, to: "exercises/typo.json")
        let library = try Content.load(from: root)

        XCTAssertEqual(library.exercises.first?.equipment, [.machine("leg_pres")])
    }

    func test_contributionsThatDoNotSumToOneLoadAndAreLeftToTheValidator() throws {
        let json = hipThrust().replacingOccurrences(of: "\"glute_max\": 0.60",
                                                    with: "\"glute_max\": 0.90")
        try write(json, to: "exercises/unbalanced.json")

        XCTAssertNoThrow(try Content.load(from: root),
                         "сумма вкладов — правило §6.3, его проверяет валидатор")
    }

    func test_duplicateSlugFailsLoading() throws {
        try write(hipThrust(), to: "exercises/a.json")
        try write(hipThrust(), to: "exercises/b.json")

        XCTAssertThrowsError(try Content.load(from: root)) { error in
            guard case ContentError.duplicateSlug(let slug, _) = error else {
                return XCTFail("ожидалась duplicateSlug, получено \(error)")
            }
            XCTAssertEqual(slug, "hip_thrust_barbell")
        }
    }

    func test_fileWithUnderscorePrefixIsNotContent() throws {
        try write(hipThrust(), to: "exercises/_schema.example.json")
        let library = try Content.load(from: root)

        XCTAssertTrue(library.exercises.isEmpty,
                      "_schema.example.json — эталон формы, а не упражнение")
    }

    // MARK: - Индексы

    func test_indexesAreBuiltAndOrderedBySlug() throws {
        try write(hipThrust(slug: "zzz_last"), to: "exercises/z.json")
        try write(hipThrust(slug: "aaa_first"), to: "exercises/a.json")
        let library = try Content.load(from: root)

        XCTAssertEqual(library.exercises.map(\.slug), ["aaa_first", "zzz_last"],
                       "порядок по слагу, а не по обходу каталога")
        XCTAssertEqual(library.byPattern[.hinge], ["aaa_first", "zzz_last"])
        XCTAssertEqual(library.byMuscle[.gluteMax], ["aaa_first", "zzz_last"])
        XCTAssertEqual(library.byEquipment[.benchFlat], ["aaa_first", "zzz_last"])
        XCTAssertNil(library.byMuscle[.biceps], "мышца без вклада в индекс не попадает")
    }

    func test_candidatesCarryTheSliceAndNothingElse() throws {
        try write(hipThrust(), to: "exercises/hip_thrust_barbell.json")
        let library = try Content.load(from: root)

        let candidate = try XCTUnwrap(library.candidates.first)
        XCTAssertEqual(candidate.slug, "hip_thrust_barbell")
        XCTAssertEqual(candidate.pattern, .hinge)
        XCTAssertEqual(candidate.setupSeconds, 90)
        XCTAssertEqual(candidate.defaultRestSeconds, 120)
        XCTAssertEqual(candidate.familyLoadRatio, 1.0)
        XCTAssertEqual(candidate.leadingMuscle, .gluteMax)
        XCTAssertEqual(library.candidates.map(\.slug), library.exercises.map(\.slug),
                       "срез идёт в том же порядке, что и библиотека")
    }

    // MARK: - Целевые векторы §7.3

    func test_vectorsAreKeyedByThePairIncludingNoAccent() throws {
        try write("""
        [
          { "session_kind": "lower", "accent_muscle": "glute_max",
            "shares": { "glute_max": 0.40, "hamstrings": 0.20, "quads": 0.18,
                        "glute_med": 0.10, "adductors": 0.06, "calves": 0.06 } },
          { "session_kind": "lower", "accent_muscle": null,
            "shares": { "quads": 0.30, "glute_max": 0.25, "hamstrings": 0.25,
                        "glute_med": 0.08, "adductors": 0.06, "calves": 0.06 } }
        ]
        """, to: "vectors/lower.json")
        let library = try Content.load(from: root)

        XCTAssertEqual(library.vectors.vector(kind: .lower, accent: .gluteMax)?[.gluteMax], 0.40)
        XCTAssertEqual(library.vectors.vector(kind: .lower)?[.quads], 0.30,
                       "«без акцента» — полноправный ключ, а не отсутствие вектора")
        XCTAssertNil(library.vectors.vector(kind: .upper),
                     "дыру в разметке ловит валидатор, загрузчик её не прячет")
    }

    func test_duplicateVectorKeyFailsLoading() throws {
        try write("""
        [
          { "session_kind": "push", "accent_muscle": null, "shares": { "pecs": 1.0 } },
          { "session_kind": "push", "accent_muscle": null, "shares": { "pecs": 1.0 } }
        ]
        """, to: "vectors/push.json")

        XCTAssertThrowsError(try Content.load(from: root)) { error in
            guard case ContentError.duplicateVectorKey = error else {
                return XCTFail("ожидалась duplicateVectorKey, получено \(error)")
            }
        }
    }

    func test_theHundredPairsOfTheSliceAreEnumerable() throws {
        // §20.11: пять типов дня, несущих вектор, на 19 мышц плюс «без акцента».
        XCTAssertEqual(DayVectorTable.allKeys.count, 100)
        XCTAssertFalse(DayVectorTable.vectorBearingKinds.contains(.rest))
        XCTAssertFalse(DayVectorTable.vectorBearingKinds.contains(.stretch))
    }

    // MARK: - Пустые разделы

    func test_missingSectionsLoadAsEmptyRatherThanFailing() throws {
        let library = try Content.load(from: root)

        XCTAssertTrue(library.exercises.isEmpty)
        XCTAssertTrue(library.stretches.isEmpty,
                      "схема позы отложена до В3: раздел пуст, а не сломан (§20.11)")
        XCTAssertTrue(library.vectors.vectors.isEmpty)
    }

    func test_bundledResourcesAreLaidOutWhereTheLoaderLooks() throws {
        // Путь сервера (§20.11) до первой разметки. Проверяется РАСКЛАДКА, а не
        // содержимое: `load(from:)` на отсутствующем каталоге отдаёт пустой
        // раздел, поэтому сломанный путь выглядел бы как «контента пока нет» —
        // то есть как сегодняшняя норма, и молчал бы до самой разметки.
        // Ловит в первую очередь возврат `.process` в Package.swift: она не
        // обязана сохранять структуру каталогов в бандле.
        let root = try XCTUnwrap(Content.bundledRoot)
        let exercises = root.appendingPathComponent("exercises")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exercises.path, isDirectory: &isDirectory),
            "в бандле нет Resources/exercises — загрузчик смотрит не туда")
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: exercises.appendingPathComponent("_schema.example.json").path),
            "эталон схемы не доехал до бандла — каталог пуст не по делу")

        // Каталог векторов появился вместе с первой партией разметки, и его
        // раскладка проверяется по той же причине, что и у упражнений.
        let vectors = root.appendingPathComponent("vectors")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: vectors.path, isDirectory: &isDirectory),
            "в бандле нет Resources/vectors — таблица векторов до сервера не доедет")
        XCTAssertTrue(isDirectory.boolValue)

        // Раньше здесь стояло «бандл пуст»: разметки не существовало, и пустота
        // была единственным, что про него можно было утверждать. С первой
        // партией (§17, этап 2) утверждается то, ради чего тест и написан, —
        // что разметка доезжает до бандла. Сколько именно её там, тест не
        // фиксирует: это данные, и такой тест ломался бы каждой переразметкой.
        let library = try Content.loadBundled()
        XCTAssertFalse(library.exercises.isEmpty,
                       "в бандл не доехало ни одного упражнения")
        XCTAssertFalse(library.vectors.vectors.isEmpty,
                       "в бандл не доехал ни один целевой вектор")
    }
}
