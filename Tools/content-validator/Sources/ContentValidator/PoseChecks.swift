import FitCore
import FitContent

/// Позы растяжки и кардио и шаблоны сессий (SPEC §12.2, §12.3).
///
/// Словари `kind`, мышц и паттернов проверяет уже загрузчик: значение вне них
/// непредставимо. Здесь — то, что представимо, но неверно: неполная карта
/// суставов, пустой список мышц, техника и источники по правилам упражнений,
/// ссылки шаблона, повтор позы в шаблоне, кардио не в своём шаблоне.
///
/// Совпадение вычисленных минут с таблицей §12.2 — не здесь: таблица живёт в
/// SPEC, и сверяет её тест сценария 40 (`FitContentTests`).
public enum PoseChecks {

    public static func run(_ library: ContentLibrary, into findings: FindingCollector) {
        var nameCounts: [String: Int] = [:]
        for pose in library.poses { nameCounts[pose.name, default: 0] += 1 }

        for pose in library.poses {
            let slug = pose.slug
            SchemaChecks.checkName(pose.name, slug: slug, nameCounts: nameCounts, into: findings)
            SchemaChecks.checkTechnique(pose.technique, slug: slug, into: findings)
            SchemaChecks.checkSources(pose.sources, slug: slug, into: findings)
            let missing = Joint.allCases.filter { pose.jointStress[$0] == nil }
            if !missing.isEmpty {
                findings.add(rule: "§12.3", subject: slug,
                             "карта joint_stress неполная, нет суставов: "
                             + missing.map(\.rawValue).joined(separator: ", "))
            }
            if pose.muscles.isEmpty {
                findings.add(rule: "§12.3", subject: slug, "muscles пуст: позе нечему отвечать")
            }
            if Set(pose.muscles).count != pose.muscles.count {
                findings.add(rule: "§12.3", subject: slug, "muscles: мышца повторяется")
            }
            if pose.defaultSeconds <= 0 {
                findings.add(rule: "§12.3", subject: slug, "default_seconds должен быть больше нуля")
            }
            if pose.cues.isEmpty {
                findings.add(rule: "§12.3", subject: slug, "cues пуст")
            }
            if pose.illustration.isEmpty {
                findings.add(rule: "§6.5", subject: slug, "пустой ключ illustration")
            }
        }

        for template in library.templates {
            checkTemplate(template, poses: library.poseBySlug, into: findings)
        }
    }

    static func checkTemplate(
        _ template: StretchTemplateSchema, poses: [String: PoseSchema], into findings: FindingCollector
    ) {
        let slug = template.slug
        if template.items.isEmpty {
            return findings.add(rule: "§12.2", subject: slug, "шаблон без поз")
        }
        var seen = Set<String>()
        for item in template.items where !seen.insert(item.pose).inserted {
            findings.add(rule: "§12.2", subject: slug, "поза «\(item.pose)» повторяется в шаблоне")
        }
        for item in template.items where poses[item.pose] == nil {
            findings.add(rule: "§12.3", subject: slug, "позы «\(item.pose)» нет в каталоге")
        }

        let cardio = template.items.contains { poses[$0.pose]?.kind == .cardio }
        if cardio {
            for item in template.items {
                if let pose = poses[item.pose], pose.kind != .cardio {
                    findings.add(rule: "§12.3", subject: slug,
                                 "в кардио-шаблоне поза «\(item.pose)» вида \(pose.kind.rawValue)")
                }
                if !(item.workSeconds ?? 0 > 0 && item.restSeconds ?? -1 >= 0 && item.rounds ?? 0 > 0)
                    || item.seconds != nil {
                    findings.add(rule: "§12.3", subject: slug,
                                 "«\(item.pose)»: у кардио нужны work_seconds, rest_seconds и rounds, без seconds")
                }
            }
            if Set(template.items.compactMap(\.rounds)).count > 1 {
                findings.add(rule: "§12.3", subject: slug, "rounds у записей кардио-шаблона различаются")
            }
        } else {
            for item in template.items where !(item.seconds ?? 0 > 0) || item.isInterval {
                findings.add(rule: "§12.3", subject: slug,
                             "«\(item.pose)»: у растяжки нужно seconds больше нуля и нет интервалов")
            }
        }
        if template.durationSeconds(poses: poses) == nil, template.items.allSatisfy({ poses[$0.pose] != nil }) {
            findings.add(rule: "§12.2", subject: slug, "длительность шаблона не вычисляется")
        }
    }
}
