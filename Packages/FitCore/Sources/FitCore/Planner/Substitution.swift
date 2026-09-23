//  Замена упражнения (SPEC §13.4) и альтернативы по флагу боли (SPEC §8.4, п.2).
//
//  Почему это живёт в FitCore, а не на сервере (SPEC §13.4, §20.1): замена
//  случается посреди тренировки, а §4.3 требует, чтобы на iOS тренировка шла
//  без сети. Логика в `Server/` в подвале недоступна, и iOS написал бы её
//  второй раз.
//
//  Поля под неё лежали в срезе §7.5 с самого начала (`alternatives`,
//  `familyLoadRatio`) и не читались ни одной функцией — до этого файла.
//
//  Разделение с контентом: `alternatives` из разметки — это ПУЛ кандидатов, а
//  не ответ. Ранжирование зависит от пользователя (инвентарь §6.6, ограничения
//  §14.4, флаги боли §8.4), поэтому считается на вызове, поверх тех же жёстких
//  ограничений §7.3, что и обычный подбор.
//
//  Перенос веса держится здесь, а не в Equipment/: `WeightLadder` ни от чего не
//  зависит по построению, и вводить туда знание об упражнении значило бы это
//  свойство потерять. Лестница остаётся параметром.

/// Зачем показываются альтернативы — от этого зависит отбор (SPEC §13.4 против
/// §8.4, п.2).
public enum SubstitutionPurpose: Sendable, Equatable {
    /// Замена в один тап (§13.4): ограничений по суставам сверх обычных нет.
    case userChoice
    /// Боль на упражнении (§8.4, п.2): альтернатива обязана грузить названные
    /// суставы СТРОГО меньше, чем заменяемое. Без этого условия «похожий
    /// профиль вклада» приводит к упражнению с той же нагрузкой на тот же
    /// сустав — то есть ровно к повторению того, из-за чего замена и идёт.
    case pain(joints: Set<Joint>)
}

/// Одна альтернатива с машинными основаниями пригодности (SPEC §13.4).
/// Формулировку собирает слой представления (§14.6), здесь только коды.
public struct ExerciseAlternative: Sendable, Equatable {
    public var slug: String
    public var reasons: [ReasonCode]

    public init(slug: String, reasons: [ReasonCode]) {
        self.slug = slug
        self.reasons = reasons
    }
}

extension Planner {

    /// SPEC §13.4 показывает три альтернативы; число — параметр, потому что
    /// §8.4 п.2 просит столько же, а вызывающий экран может захотеть меньше.
    public static let alternativesShown = 3

    /// Альтернативы замене `exercise`, отсортированные по близости профиля
    /// вклада мышц (SPEC §13.4).
    ///
    /// Пул — объявленные в контенте `exercise.alternatives`, из них остаются
    /// те, что проходят жёсткие ограничения §7.3 на день `day` (инвентарь,
    /// травмы, флаги боли, `skill_level`, консервативный режим) и, для
    /// `.pain`, строго разгружают названные суставы.
    ///
    /// **Может вернуть меньше трёх, и это не ошибка.** Пул задаёт разметка, а
    /// сузить его до пустого способны инвентарь и ограничения конкретной
    /// пользовательницы. Добирать до трёх чем-то помимо объявленных
    /// альтернатив эта функция не станет: «похоже по вкладу мышц» из всей
    /// библиотеки — это другой подбор, и решать за разметку он не вправе.
    /// Достаточность пула — забота валидатора контента (§17, этап 2).
    ///
    /// Близость считается по СЫРЫМ вкладам (`muscleContributions`), а не по
    /// эффективным: сырые нормированы (сумма ≈ 1.0, §6.3) и потому сравнимы
    /// между упражнениями, тогда как эффективные — это доли от ведущей мышцы
    /// каждого упражнения по отдельности, и у двух упражнений с разными
    /// ведущими мышцами их расстояние ничего не означает.
    public static func alternatives(
        to exercise: ExerciseCandidate,
        purpose: SubstitutionPurpose = .userChoice,
        library: [ExerciseCandidate],
        safety: SafetyProfile,
        availability: EquipmentAvailability,
        equipment: EquipmentProfile,
        on day: CalendarDay,
        limit: Int = alternativesShown
    ) -> [ExerciseAlternative] {
        let pool = Set(exercise.alternatives)
        guard !pool.isEmpty, limit > 0 else { return [] }

        var seen = Set<String>()
        let feasible = library.filter { candidate in
            candidate.slug != exercise.slug
                && pool.contains(candidate.slug)
                && seen.insert(candidate.slug).inserted
                && passesHardConstraints(candidate, safety: safety, availability: availability,
                                         equipment: equipment, on: day)
                && relievesPainJoints(candidate, from: exercise, purpose: purpose)
        }

        // Ничьи по расстоянию разрешаются слагом: порядок обязан быть
        // воспроизводимым, иначе один и тот же экран показывает разные тройки.
        return feasible
            .map { (candidate: $0, distance: profileDistance($0, exercise)) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance
                                                 : $0.candidate.slug < $1.candidate.slug }
            .prefix(limit)
            .map { ExerciseAlternative(slug: $0.candidate.slug,
                                       reasons: fitReasons($0.candidate, replacing: exercise, safety: safety)) }
    }

    /// Манхэттенское расстояние между профилями вкладов. Оба нормированы, так
    /// что величина сравнима между парами.
    static func profileDistance(_ a: ExerciseCandidate, _ b: ExerciseCandidate) -> Double {
        MuscleSlug.allCases.reduce(0.0) { sum, m in
            sum + abs((a.muscleContributions[m] ?? 0) - (b.muscleContributions[m] ?? 0))
        }
    }

    /// Степень нагрузки как число, где «сустава нет в разметке» строго ниже
    /// `.low`: отсутствие записи — это не та же нагрузка, что низкая.
    static func stressRank(_ level: JointStressLevel?) -> Int {
        switch level {
        case .none: return -1
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func relievesPainJoints(
        _ candidate: ExerciseCandidate,
        from exercise: ExerciseCandidate,
        purpose: SubstitutionPurpose
    ) -> Bool {
        guard case .pain(let joints) = purpose else { return true }
        return joints.allSatisfy { joint in
            stressRank(candidate.jointStress[joint]) < stressRank(exercise.jointStress[joint])
        }
    }

    /// Машинные основания пригодности (SPEC §13.4): та же ведущая мышца и
    /// разгруженные суставы, по которым у пользователя ограничение §14.4 или
    /// недавний флаг боли §8.4. Именно из этой пары собирается пример SPEC
    /// «тот же акцент на ягодицы, без нагрузки на колено».
    ///
    /// Про суставы без ограничения и без боли молчим: «грузит колено меньше»
    /// там, где колено здорово, не является доводом и засоряет экран.
    static func fitReasons(
        _ candidate: ExerciseCandidate,
        replacing exercise: ExerciseCandidate,
        safety: SafetyProfile
    ) -> [ReasonCode] {
        var reasons: [ReasonCode] = []
        if let muscle = exercise.leadingMuscle, candidate.leadingMuscle == muscle {
            reasons.append(.substitutionKeepsLeadingMuscle(muscle: muscle))
        }
        var concerning = Set(safety.restrictions.map(\.joint))
        for event in safety.painEvents { concerning.formUnion(event.joints) }
        for joint in Joint.allCases where concerning.contains(joint) {
            let before = exercise.jointStress[joint]
            let after = candidate.jointStress[joint]
            guard let before, stressRank(after) < stressRank(before) else { continue }
            reasons.append(.substitutionRelievesJoint(joint: joint, from: before, to: after))
        }
        return reasons
    }

    /// Перенос базовой линии на упражнение-замену (SPEC §13.4):
    /// `roundToAchievable(baseline × ratio(новое) / ratio(старое), вниз)`.
    ///
    /// `nil` — перенос не определён, и новое упражнение стартует в калибровке.
    /// Случаев четыре, и все четыре §13.4 называет прямо: разные
    /// `progression_family`, нет базовой линии у старого, нет
    /// `family_load_ratio` у любого из двух. Значения по умолчанию у отношения
    /// нет намеренно — подставленная 1.0 перенесла бы вес штанги на гантель
    /// как есть.
    ///
    /// Вниз — по той же причине, что стартовый ×0.6 калибровки (§9.8): ошибка
    /// пересчёта обязана давать недогруз, а не перегруз.
    public static func transferredBaseline(
        from exercise: ExerciseCandidate,
        to candidate: ExerciseCandidate,
        baselineKg: Double?,
        ladder: WeightLadder
    ) -> Double? {
        guard exercise.progressionFamily == candidate.progressionFamily,
              let baseline = baselineKg,
              let fromRatio = exercise.familyLoadRatio, fromRatio > 0,
              let toRatio = candidate.familyLoadRatio, toRatio > 0
        else { return nil }
        return ladder.roundToAchievable(baseline * toRatio / fromRatio, direction: .down)
    }
}
