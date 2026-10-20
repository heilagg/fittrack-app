//  Растяжка (SPEC §12.2, §12.3): автозаминка и предложенный шаблон.
//
//  В FitCore, а не на сервере, по прецеденту замены §13.4: заминка
//  предлагается на экране завершения тренировки, а на iOS тренировка идёт без
//  сети (§4.3). Логика в `Server/` была бы второй реализацией для iOS.
//
//  Вход — срез, как у планировщика (§7.5): `StretchPose` несёт только то, что
//  читают правила подбора. Название, подсказки и картинка — показ, они живут в
//  `FitContent` и сюда не едут.
//
//  Заминка (§12.2, правило 1–5):
//    мышцы — по убыванию эффективных подходов тренировки (§7.4); на мышцу —
//    одна статическая поза, ещё не выбранная, из подходящих — с наибольшей
//    суммой подходов по своим мышцам; первые три позы при любом объёме,
//    четвёртая и пятая — только для мышцы с не меньше чем 4 эффективными
//    подходами; ограничения §14.4 — как у упражнений. Заминка бывает короче
//    трёх поз: мышце без статической позы ответить нечем, а чужая поза
//    добором не делается (решение §12.2).
//
//  Порог 4 выбран прогоном на 600 сборках реальной библиотеки (§12.2,
//  таблица): наибольший, при котором ни одна мышца с ≥ 4 подходами не
//  остаётся без позы.

/// Срез позы для подбора (§12.3).
public struct StretchPose: Sendable, Equatable {
    public var slug: String
    public var kind: PoseKind
    public var unilateral: Bool
    public var defaultSeconds: Int
    public var muscles: [MuscleSlug]
    public var jointStress: [Joint: JointStressLevel]

    public init(slug: String, kind: PoseKind, unilateral: Bool, defaultSeconds: Int,
                muscles: [MuscleSlug], jointStress: [Joint: JointStressLevel]) {
        self.slug = slug
        self.kind = kind
        self.unilateral = unilateral
        self.defaultSeconds = defaultSeconds
        self.muscles = muscles
        self.jointStress = jointStress
    }
}

/// Поза заминки: слаг и секунды на сторону (у односторонней — на каждую).
public struct CooldownPose: Sendable, Equatable {
    public var slug: String
    public var seconds: Int

    public init(slug: String, seconds: Int) {
        self.slug = slug
        self.seconds = seconds
    }
}

/// Шаблон, который §12.2 предлагает первым. Значение — слаг шаблона в
/// `FitContent`; что такие шаблоны есть, проверяет тест FitContent.
public enum SuggestedTemplate: String, Sendable, Equatable, CaseIterable {
    case menstrualGentle = "menstrual_gentle"
    case lowerBackPelvis = "lower_back_pelvis"
    case neckThoracic = "neck_thoracic"
    case fullStretch = "full_stretch"
    case morningMobility = "morning_mobility"
}

public enum Stretching {
    /// Минимум поз, который заминка набирает при любом объёме (§12.2, п.3).
    public static let cooldownBasePoses = 3
    /// Больше пяти поз заминка не даёт (§12.2).
    public static let cooldownMaxPoses = 5
    /// Порог эффективных подходов для четвёртой и пятой позы (§12.2, прогон).
    public static let cooldownExtraThreshold = 4.0

    /// Автозаминка по выполненным подходам тренировки (§12.2).
    ///
    /// `setsBySlug` — завершённые подходы по упражнениям, `library` — срез §7.5
    /// для их вкладов. Пусто — заминки нет.
    public static func cooldown(
        setsBySlug: [String: Int],
        library: [String: ExerciseCandidate],
        poses: [StretchPose],
        restrictions: [UserRestriction]
    ) -> [CooldownPose] {
        let items = setsBySlug.sorted { $0.key < $1.key }.compactMap { slug, sets -> (ExerciseCandidate, Int)? in
            guard sets > 0, let candidate = library[slug] else { return nil }
            return (candidate, sets)
        }
        let volume = Planner.effectiveVolume(items)
        let usable = poses
            .filter { $0.kind == .static && allowed($0, restrictions: restrictions) }
            .sorted { $0.slug < $1.slug }

        var chosen: [StretchPose] = []
        var covered = Set<MuscleSlug>()
        let muscles = volume.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        for (muscle, sets) in muscles {
            if chosen.count >= cooldownMaxPoses { break }
            if covered.contains(muscle) { continue }
            let candidates = usable.filter { pose in
                pose.muscles.contains(muscle) && !chosen.contains { $0.slug == pose.slug }
            }
            guard !candidates.isEmpty else { continue }
            if chosen.count >= cooldownBasePoses && sets < cooldownExtraThreshold { break }
            let best = candidates.max { a, b in
                let sa = a.muscles.reduce(0) { $0 + (volume[$1] ?? 0) }
                let sb = b.muscles.reduce(0) { $0 + (volume[$1] ?? 0) }
                return sa != sb ? sa < sb : a.slug > b.slug
            }!
            chosen.append(best)
            covered.formUnion(best.muscles)
        }
        return chosen.map { CooldownPose(slug: $0.slug, seconds: $0.defaultSeconds) }
    }

    /// §14.4 для позы — тот же порог, что у упражнения (`passesHardConstraints`):
    /// `avoid` исключает `medium` и `high`, `careful` — `high`.
    static func allowed(_ pose: StretchPose, restrictions: [UserRestriction]) -> Bool {
        for restriction in restrictions {
            let stress = pose.jointStress[restriction.joint] ?? .none
            switch restriction.severity {
            case .avoid where stress >= .medium: return false
            case .careful where stress == .high: return false
            default: continue
            }
        }
        return true
    }

    /// Предложенный шаблон дня (§12.2, «Выбор шаблона»).
    ///
    /// Фаза — категориальное решение, поэтому гейтится порогом §11.2, а не
    /// масштабируется (cycle-phase-domain §3). `lastStrengthKind` — тип
    /// последней завершённой силовой тренировки, `nil` — их не было.
    public static func suggestedTemplate(
        phase: Phase?, cycleConfidence: Double?, lastStrengthKind: SessionKind?
    ) -> SuggestedTemplate {
        if phase == .menstrual, let confidence = cycleConfidence,
           confidence >= Cycle.categoricalConfidenceThreshold {
            return .menstrualGentle
        }
        switch lastStrengthKind {
        case .lower: return .lowerBackPelvis
        case .upper, .push, .pull: return .neckThoracic
        case .fullBody: return .fullStretch
        case .stretch, .rest, nil: return .morningMobility
        }
    }
}
