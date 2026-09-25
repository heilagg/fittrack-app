//  Загрузчик и индексы (SPEC §6, §7.3). Строятся один раз при старте процесса
//  — так же, как считается `ETag` (§20.11): контент за время жизни процесса не
//  меняется, потому что правка контента требует деплоя.
//
//  Два входа намеренно:
//    `load(from:)`      — каталог на диске. Им пользуются тесты и валидатор:
//                         оба работают с файлами репозитория, а не с бандлом.
//    `loadBundled()`    — ресурсы пакета. Им пользуется сервер.
//  Разделение не ради тестов: валидатор обязан проверять ТЕ файлы, что лежат в
//  репозитории, а бандл — их копия, собранная сборкой, и сверять копию значило
//  бы пропускать файл, который в сборку не попал.
//
//  Порядок упражнений в `exercises` — по слагу, а не по порядку файлов в
//  каталоге. Планировщик от порядка среза не зависит (§7.3, «проверено
//  прогоном»), но `ETag` §20.11 зависит от байтов, а обход каталога
//  файловой системой не обязан быть стабильным между машинами.

import Foundation
import FitCore

/// Что пошло не так при загрузке — уровень файлов и набора, а не полей.
/// Ошибки полей остаются `DecodingError`: у них есть путь до поля.
public enum ContentError: Error, Equatable, CustomStringConvertible {
    case directoryUnreadable(path: String)
    case fileUnreadable(path: String)
    case malformedFile(path: String, reason: String)
    case duplicateSlug(String, path: String)
    case duplicateVectorKey(kind: String, accent: String?)
    case resourcesMissing

    public var description: String {
        switch self {
        case .directoryUnreadable(let path):
            return "каталог контента не читается: \(path)"
        case .fileUnreadable(let path):
            return "файл контента не читается: \(path)"
        case .malformedFile(let path, let reason):
            return "\(path): \(reason)"
        case .duplicateSlug(let slug, let path):
            return "слаг «\(slug)» встречается второй раз: \(path)"
        case .duplicateVectorKey(let kind, let accent):
            return "пара (\(kind), \(accent ?? "без акцента")) задана дважды"
        case .resourcesMissing:
            return "ресурсы пакета FitContent недоступны"
        }
    }
}

/// Библиотека упражнений с предвычисленными индексами и таблица векторов.
public struct ContentLibrary: Sendable {
    /// Все упражнения, отсортированные по слагу.
    public let exercises: [ExerciseSchema]
    /// Срез §7.5 в том же порядке — то, что уходит в планировщик целиком,
    /// без предварительного отбора.
    public let candidates: [ExerciseCandidate]
    public let vectors: DayVectorTable
    public let stretches: [StretchSchema]

    public let bySlug: [String: ExerciseSchema]
    /// Слаги упражнений с НЕНУЛЕВЫМ вкладом в мышцу (§7.3: «нагруженные»).
    public let byMuscle: [MuscleSlug: [String]]
    public let byPattern: [Pattern: [String]]
    /// Слаги по требованию инвентаря. Упражнение с пустым `equipment` не
    /// попадает ни в одну ячейку — оно не требует ничего.
    public let byEquipment: [EquipmentRequirement: [String]]

    init(exercises: [ExerciseSchema], vectors: DayVectorTable, stretches: [StretchSchema]) {
        let sorted = exercises.sorted { $0.slug < $1.slug }
        self.exercises = sorted
        self.candidates = sorted.map(\.candidate)
        self.vectors = vectors
        self.stretches = stretches

        var bySlug: [String: ExerciseSchema] = [:]
        var byMuscle: [MuscleSlug: [String]] = [:]
        var byPattern: [Pattern: [String]] = [:]
        var byEquipment: [EquipmentRequirement: [String]] = [:]
        for exercise in sorted {
            bySlug[exercise.slug] = exercise
            byPattern[exercise.pattern, default: []].append(exercise.slug)
            for (muscle, share) in exercise.muscleContributions where share > 0 {
                byMuscle[muscle, default: []].append(exercise.slug)
            }
            for requirement in exercise.equipment {
                byEquipment[requirement, default: []].append(exercise.slug)
            }
        }
        // Значения индексов тоже по слагу: `byMuscle` обходит словарь вкладов,
        // порядок которого между запусками не определён.
        self.bySlug = bySlug
        self.byMuscle = byMuscle.mapValues { $0.sorted() }
        self.byPattern = byPattern.mapValues { $0.sorted() }
        self.byEquipment = byEquipment.mapValues { $0.sorted() }
    }
}

public enum Content {
    /// Файл, чьё имя начинается с `_`, содержимым библиотеки не является:
    /// `_schema.example.json` — эталон формы для разметки, а не упражнение.
    static let ignoredFilePrefix = "_"

    /// Загрузка из каталога: `<root>/exercises/*.json`, `<root>/vectors/*.json`,
    /// `<root>/stretches/*.json`.
    public static func load(from root: URL) throws -> ContentLibrary {
        let exercises: [ExerciseSchema] = try decodeAll(in: root, subdirectory: "exercises")
        var seen: [String: String] = [:]
        for exercise in exercises {
            if seen[exercise.slug] != nil {
                throw ContentError.duplicateSlug(exercise.slug, path: "exercises")
            }
            seen[exercise.slug] = exercise.slug
        }

        // Векторы лежат списками: пар сто, и файл на пару означал бы сто
        // файлов ради одной таблицы.
        let vectorRows: [[DayVector]] = try decodeAll(in: root, subdirectory: "vectors")
        let rows = vectorRows.flatMap { $0 }
        var keys = Set<DayVectorKey>()
        for row in rows where !keys.insert(row.key).inserted {
            throw ContentError.duplicateVectorKey(kind: row.key.kind.rawValue,
                                                  accent: row.key.accent?.rawValue)
        }

        let stretches: [StretchSchema] = try decodeAll(in: root, subdirectory: "stretches")

        return ContentLibrary(exercises: exercises,
                              vectors: DayVectorTable(rows),
                              stretches: stretches)
    }

    /// Корень ресурсов пакета. Отдельно от `loadBundled()`, чтобы тест мог
    /// проверить саму раскладку: `load(from:)` на несуществующем каталоге
    /// возвращает пустой раздел, и сломанный путь иначе выглядел бы как
    /// «контента пока нет» — то есть как сегодняшняя норма.
    static var bundledRoot: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Resources")
    }

    /// Загрузка из ресурсов пакета — путь сервера (§20.11).
    public static func loadBundled() throws -> ContentLibrary {
        guard let root = bundledRoot else { throw ContentError.resourcesMissing }
        return try load(from: root)
    }

    private static func decodeAll<T: Decodable>(in root: URL, subdirectory: String) throws -> [T] {
        let directory = root.appendingPathComponent(subdirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            // Каталога нет — это пустой раздел контента, а не поломка:
            // `stretches/` пуст до этапа В3 (§20.11), а на раннем срезе
            // пустым может быть и `vectors/`. Недостачу ловит валидатор.
            return []
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let decoder = JSONDecoder()
        return try names.sorted()
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(ignoredFilePrefix) }
            .map { name in
                let url = directory.appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    throw ContentError.fileUnreadable(path: "\(subdirectory)/\(name)")
                }
                do {
                    return try decoder.decode(T.self, from: data)
                } catch let error as DecodingError {
                    throw ContentError.malformedFile(path: "\(subdirectory)/\(name)",
                                                     reason: Self.explain(error))
                }
            }
    }

    /// `DecodingError` в одну строку: без этого в CI приезжает многострочный
    /// дамп контекста, по которому не видно, какое поле какого файла виновато.
    static func explain(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let prefix = path(context)
            return "нет обязательного поля «\(prefix.isEmpty ? key.stringValue : "\(prefix).\(key.stringValue)")»"
        case .typeMismatch(let type, let context):
            return "поле «\(path(context))»: ожидался \(type)"
        case .valueNotFound(let type, let context):
            return "поле «\(path(context))»: пустое значение вместо \(type)"
        case .dataCorrupted(let context):
            let prefix = path(context)
            return prefix.isEmpty ? context.debugDescription
                                  : "поле «\(prefix)»: \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
