//  Проверки одного упражнения и связей между упражнениями (SPEC §6.2, §6.3, §6.6).
//
//  Сюда попадает всё, что загрузчик FitContent пропускает намеренно: он падает
//  только на непредставимом (неизвестный слаг мышцы, значение вне словаря
//  §6.6), а правила — здесь, потому что гейт правил — CI, а не рантайм сервера
//  (§20.11).

import Foundation
import FitCore
import FitContent

public enum SchemaChecks {

    /// Допуск на «сумма ≈ 1.0» (§6.3). SPEC числа не даёт; 0.01 выбран по
    /// разметке примера §6.2 — вклады записаны с двумя знаками, и сумма
    /// двух знаков не может разойтись с 1.0 больше чем на округление.
    public static let contributionSumTolerance = 0.01

    /// Число шагов `technique` (§6.2): меньше трёх — не описание, а подсказка,
    /// больше шести — уже не помещается на экран упражнения одним взглядом.
    public static let techniqueSteps = 3...6

    /// Закрытый список каталогов `sources` (§6.2). Строка, а не enum в схеме,
    /// по той же причине, что слаг тренажёра: опечатка представима и
    /// ловится здесь, с именем упражнения.
    public static let sourceCatalogs: Set<String> = ["free-exercise-db", "wger", "exercisedb"]

    public static func run(_ library: ContentLibrary, into findings: FindingCollector) {
        let machineSlugs = Set(EquipmentLevel.machineSlugs)
        var familySizes: [String: Int] = [:]
        var nameCounts: [String: Int] = [:]
        for exercise in library.exercises {
            familySizes[exercise.progressionFamily, default: 0] += 1
            nameCounts[exercise.name, default: 0] += 1
        }

        for exercise in library.exercises {
            let slug = exercise.slug
            checkContributions(exercise, slug: slug, into: findings)
            checkJointMap(exercise, slug: slug, into: findings)
            checkEquipment(exercise, slug: slug, machineSlugs: machineSlugs, into: findings)
            checkLoadTypeNamesItsGear(exercise, slug: slug, into: findings)
            checkAlternatives(exercise, slug: slug, library: library, into: findings)
            checkFamily(exercise, slug: slug, familySizes: familySizes, into: findings)
            checkSanity(exercise, slug: slug, into: findings)
            checkName(exercise.name, slug: slug, nameCounts: nameCounts, into: findings)
            checkTechnique(exercise.technique, slug: slug, into: findings)
            checkSources(exercise.sources, slug: slug, into: findings)
        }
    }

    // MARK: - §6.2: техника и источники

    static func checkTechnique(
        _ steps: [String], slug: String, into findings: FindingCollector
    ) {
        if !techniqueSteps.contains(steps.count) {
            findings.add(rule: "§6.2", subject: slug,
                         "technique: \(steps.count) шагов, нужно от \(techniqueSteps.lowerBound) "
                         + "до \(techniqueSteps.upperBound)")
        }
        for (index, step) in steps.enumerated() {
            let number = index + 1
            if step.trimmingCharacters(in: .whitespaces).isEmpty {
                findings.add(rule: "§6.2", subject: slug, "technique: шаг \(number) пустой")
            }
            if containsLatin(step) {
                findings.add(rule: "§6.2", subject: slug,
                             "technique: шаг \(number) содержит латиницу: «\(step)»")
            }
        }
    }

    static func checkSources(
        _ sources: [ExerciseSource], slug: String, into findings: FindingCollector
    ) {
        var seen: Set<ExerciseSource> = []
        for source in sources {
            if !sourceCatalogs.contains(source.catalog) {
                findings.add(rule: "§6.2", subject: slug,
                             "sources: каталог «\(source.catalog)» вне закрытого списка")
            }
            if source.id.trimmingCharacters(in: .whitespaces).isEmpty {
                findings.add(rule: "§6.2", subject: slug,
                             "sources: пустой id у каталога «\(source.catalog)»")
            }
            if !seen.insert(source).inserted {
                findings.add(rule: "§6.2", subject: slug,
                             "sources: повтор «\(source.catalog)» / «\(source.id)»")
            }
        }
    }

    static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }

    // MARK: - §6.2: русские названия, механическая часть правил

    /// Только то, что проверяется машиной (§6.2, «Русские названия», п.7):
    /// латиница, заглавная буква, точка в конце, повтор. Устоявшееся имя,
    /// порядок слов и «с собственным весом» проверяются глазами.
    static func checkName(
        _ name: String, slug: String, nameCounts: [String: Int],
        into findings: FindingCollector
    ) {
        if containsLatin(name) {
            findings.add(rule: "§6.2", subject: slug, "название «\(name)» содержит латиницу")
        }
        if let first = name.first, !(first.isUppercase && first.isLetter) {
            findings.add(rule: "§6.2", subject: slug, "название «\(name)» не начинается с заглавной буквы")
        }
        if name.isEmpty {
            findings.add(rule: "§6.2", subject: slug, "пустое название")
        }
        if name.hasSuffix(".") {
            findings.add(rule: "§6.2", subject: slug, "название «\(name)» кончается точкой")
        }
        if (nameCounts[name] ?? 0) > 1 {
            findings.add(rule: "§6.2", subject: slug, "название «\(name)» повторяется у другого упражнения")
        }
    }

    // MARK: - §6.3: вклады мышц

    private static func checkContributions(
        _ exercise: ExerciseSchema, slug: String, into findings: FindingCollector
    ) {
        let contributions = exercise.muscleContributions
        guard !contributions.isEmpty else {
            return findings.add(rule: "§6.3", subject: slug,
                                "muscle_contributions пуст: упражнение не грузит ничего")
        }
        for (muscle, share) in contributions.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where share < 0 {
            findings.add(rule: "§6.3", subject: slug,
                         "отрицательный вклад в \(muscle.rawValue): \(share)")
        }
        let sum = contributions.values.reduce(0, +)
        if abs(sum - 1.0) > contributionSumTolerance {
            findings.add(rule: "§6.3", subject: slug,
                         "сумма вкладов \(rounded(sum)) вместо ≈ 1.0 "
                         + "(допуск ±\(contributionSumTolerance))")
        }
    }

    // MARK: - §6.2: полная карта суставов

    private static func checkJointMap(
        _ exercise: ExerciseSchema, slug: String, into findings: FindingCollector
    ) {
        let missing = Joint.allCases.filter { exercise.jointStress[$0] == nil }
        guard !missing.isEmpty else { return }
        findings.add(rule: "§6.2", subject: slug,
                     "карта joint_stress неполная, нет суставов: "
                     + missing.map(\.rawValue).joined(separator: ", ")
                     + " — «не грузит» записывается значением none, а не пропуском")
    }

    // MARK: - §6.6: словарь инвентаря

    private static func checkEquipment(
        _ exercise: ExerciseSchema, slug: String, machineSlugs: Set<String>,
        into findings: FindingCollector
    ) {
        for requirement in exercise.equipment {
            guard case .machine(let machine) = requirement else { continue }
            if !machineSlugs.contains(machine) {
                findings.add(rule: "§6.6", subject: slug,
                             "слаг тренажёра «\(machine)» вне закрытого списка")
            }
        }
    }

    /// Весовой `load_type` обязан называть свой снаряд и в `equipment` (§6.6):
    /// лестница отвечает, есть ли веса, но не какой снаряд — у блока и
    /// тренажёров `machine_step_kg` общий.
    private static func checkLoadTypeNamesItsGear(
        _ exercise: ExerciseSchema, slug: String, into findings: FindingCollector
    ) {
        let equipment = exercise.equipment
        switch exercise.loadType {
        case .kettlebell where !equipment.contains(.kettlebells):
            findings.add(rule: "§6.6", subject: slug,
                         "load_type kettlebell без требования kettlebells")
        case .cable where !equipment.contains(.cableMachine):
            findings.add(rule: "§6.6", subject: slug,
                         "load_type cable без требования cable_machine")
        case .machine where !equipment.contains(where: { if case .machine = $0 { true } else { false } }):
            findings.add(rule: "§6.6", subject: slug,
                         "load_type machine без требования machine:<слаг>")
        default:
            break
        }
    }

    // MARK: - §7.5: альтернативы

    private static func checkAlternatives(
        _ exercise: ExerciseSchema, slug: String, library: ContentLibrary,
        into findings: FindingCollector
    ) {
        for alternative in exercise.alternatives {
            if alternative == slug {
                findings.add(rule: "§7.5", subject: slug,
                             "упражнение указано своей же альтернативой")
            } else if library.bySlug[alternative] == nil {
                findings.add(rule: "§7.5", subject: slug,
                             "альтернатива «\(alternative)» в библиотеке отсутствует")
            }
        }
        // Список направленный (§7.5): у A может быть B, а у B нет A, и это не
        // ошибка. Поэтому обратная связь здесь НЕ проверяется.
    }

    // MARK: - §6.3: семья прогрессии

    private static func checkFamily(
        _ exercise: ExerciseSchema, slug: String, familySizes: [String: Int],
        into findings: FindingCollector
    ) {
        let size = familySizes[exercise.progressionFamily] ?? 0
        if size > 1, exercise.familyLoadRatio == nil {
            findings.add(rule: "§6.3", subject: slug,
                         "family_load_ratio обязателен: в семье «\(exercise.progressionFamily)» "
                         + "\(size) упражнения, и без отношения перенос прогресса (§13.4) "
                         + "молча уходит в калибровку")
        }
        if let ratio = exercise.familyLoadRatio, ratio <= 0 {
            findings.add(rule: "§6.3", subject: slug,
                         "family_load_ratio \(rounded(ratio)) должен быть больше нуля")
        }
    }

    // MARK: - Санитарные проверки

    /// Границ этим величинам SPEC не задаёт, поэтому проверяется только то, на
    /// чём расчёт теряет смысл: отрицательное время и неположительная цена
    /// утомления.
    private static func checkSanity(
        _ exercise: ExerciseSchema, slug: String, into findings: FindingCollector
    ) {
        if exercise.fatigueCost <= 0 {
            findings.add(rule: "§6.3", subject: slug,
                         "fatigue_cost \(rounded(exercise.fatigueCost)) не больше нуля")
        }
        if exercise.setupSeconds < 0 {
            findings.add(rule: "§7.3", subject: slug,
                         "setup_seconds \(exercise.setupSeconds) отрицательный")
        }
        if exercise.defaultRestSeconds <= 0 {
            findings.add(rule: "§13.3", subject: slug,
                         "default_rest_seconds \(exercise.defaultRestSeconds) не больше нуля")
        }
    }

    public static func rounded(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
