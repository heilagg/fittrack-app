//  Поза растяжки или кардио и шаблон самостоятельной сессии (SPEC §12.2,
//  §12.3).
//
//  Отдельный тип, а не упражнение с признаком, — решение §12.3: планировщик
//  берёт библиотеку упражнений целиком (§7.5), и поза ребёнка, лежащая среди
//  упражнений, попала бы в силовой день и в недельный объём. Здесь это
//  свойство построения: `ContentLibrary.candidates` строится только из
//  `exercises`, а позы живут в другом каталоге и другом поле.
//
//  Как и у упражнения, тип отвергает только непредставимое (неизвестное
//  значение словаря); всё, что представимо, но неверно (повтор позы в
//  шаблоне, кардио в шаблоне растяжки, неполная карта суставов), ловит
//  валидатор.

import FitCore

/// Поза из `Resources/stretches/poses/` (SPEC §12.3).
public struct PoseSchema: Sendable, Equatable {
    public var slug: String
    public var name: String
    public var kind: PoseKind
    /// Поза делается на каждую сторону: время вдвое, подсказка о смене стороны.
    public var unilateral: Bool
    /// Длительность вне шаблона (автозаминка), на сторону у односторонней.
    public var defaultSeconds: Int
    /// Мышцы §6.4 без долей; шея — `traps_upper`, сгибатели бедра — `quads`.
    public var muscles: [MuscleSlug]
    /// Паттерны §6.3 для подбора разминки §12.1 (пока не реализована).
    public var patterns: [Pattern]
    /// Полная карта семи суставов, как в §6.2; полноту проверяет валидатор.
    public var jointStress: [Joint: JointStressLevel]
    public var cues: [String]
    public var technique: [String]
    public var sources: [ExerciseSource]
    public var illustration: String

    public init(slug: String, name: String, kind: PoseKind, unilateral: Bool = false,
                defaultSeconds: Int, muscles: [MuscleSlug], patterns: [Pattern] = [],
                jointStress: [Joint: JointStressLevel] = [:], cues: [String] = [],
                technique: [String] = [], sources: [ExerciseSource] = [],
                illustration: String) {
        self.slug = slug
        self.name = name
        self.kind = kind
        self.unilateral = unilateral
        self.defaultSeconds = defaultSeconds
        self.muscles = muscles
        self.patterns = patterns
        self.jointStress = jointStress
        self.cues = cues
        self.technique = technique
        self.sources = sources
        self.illustration = illustration
    }
}

extension PoseSchema: Decodable {
    private enum Key: String, CodingKey {
        case slug, name, kind, unilateral
        case defaultSeconds = "default_seconds"
        case muscles, patterns
        case jointStress = "joint_stress"
        case cues, technique, sources, illustration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeRaw(PoseKind.self, forKey: .kind)
        unilateral = try c.decode(Bool.self, forKey: .unilateral)
        defaultSeconds = try c.decode(Int.self, forKey: .defaultSeconds)
        muscles = try c.decode([String].self, forKey: .muscles).map { raw in
            guard let muscle = MuscleSlug(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .muscles, in: c, debugDescription: "мышца вне §6.4: «\(raw)»")
            }
            return muscle
        }
        patterns = try c.decode([String].self, forKey: .patterns).map { raw in
            guard let pattern = Pattern(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .patterns, in: c, debugDescription: "паттерн вне §6.3: «\(raw)»")
            }
            return pattern
        }
        jointStress = try c.decodeKeyed(Joint.self, JointStressLevel.self, forKey: .jointStress)
        cues = try c.decode([String].self, forKey: .cues)
        technique = try c.decode([String].self, forKey: .technique)
        sources = try c.decode([ExerciseSource].self, forKey: .sources)
        illustration = try c.decode(String.self, forKey: .illustration)
    }
}

/// Запись шаблона: поза и её секунды (SPEC §12.2, §12.3). У растяжки —
/// `seconds`; у кардио — интервалы `workSeconds`/`restSeconds` и `rounds`.
/// Какая из двух форм уместна, проверяет валидатор по виду позы.
public struct TemplateItem: Sendable, Equatable, Decodable {
    public var pose: String
    public var seconds: Int?
    public var workSeconds: Int?
    public var restSeconds: Int?
    public var rounds: Int?

    private enum Key: String, CodingKey {
        case pose, seconds
        case workSeconds = "work_seconds"
        case restSeconds = "rest_seconds"
        case rounds
    }

    public init(pose: String, seconds: Int? = nil, workSeconds: Int? = nil,
                restSeconds: Int? = nil, rounds: Int? = nil) {
        self.pose = pose
        self.seconds = seconds
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.rounds = rounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        pose = try c.decode(String.self, forKey: .pose)
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds)
        workSeconds = try c.decodeIfPresent(Int.self, forKey: .workSeconds)
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds)
    }

    /// Интервальная запись — кардио (§12.3).
    public var isInterval: Bool { workSeconds != nil }
}

/// Шаблон из `Resources/stretches/templates/` (SPEC §12.2).
public struct StretchTemplateSchema: Sendable, Equatable, Decodable {
    public var slug: String
    public var name: String
    public var purpose: String
    public var items: [TemplateItem]

    public init(slug: String, name: String, purpose: String, items: [TemplateItem]) {
        self.slug = slug
        self.name = name
        self.purpose = purpose
        self.items = items
    }

    /// Длительность шаблона из поз (§12.2): сумма секунд, односторонняя поза
    /// — дважды, переходы не считаются. У кардио — круги: каждая запись по
    /// очереди, работа и отдых, `rounds` раз; отдых после последнего
    /// интервала сессии не считается. `nil` — запись ссылается на позу,
    /// которой нет, или неполна: это брак разметки, его называет валидатор.
    public func durationSeconds(poses: [String: PoseSchema]) -> Int? {
        var total = 0
        let intervals = items.filter(\.isInterval)
        for item in items where !item.isInterval {
            guard let pose = poses[item.pose], let seconds = item.seconds else { return nil }
            total += seconds * (pose.unilateral ? 2 : 1)
        }
        if !intervals.isEmpty {
            guard let rounds = intervals.first?.rounds,
                  intervals.allSatisfy({ $0.rounds == rounds && $0.restSeconds != nil })
            else { return nil }
            for item in intervals {
                guard let pose = poses[item.pose], let work = item.workSeconds,
                      let rest = item.restSeconds else { return nil }
                total += rounds * (work + rest) * (pose.unilateral ? 2 : 1)
            }
            total -= intervals.last!.restSeconds!
        }
        return total
    }

    /// Минуты для таблицы §12.2: округление до целого, половина вверх.
    public static func minutes(fromSeconds seconds: Int) -> Int {
        (seconds + 30) / 60
    }
}
