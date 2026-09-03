//  WeightLadder — предвычисленная лестница достижимых весов для пары
//  (профиль инвентаря × loadType). SPEC §9.5: шаг с 6 на 8 кг на гантелях
//  2/4/6/8 — это +33% нагрузки, отсюда необходимость знать следующий
//  достижимый вес отдельно от решения, что с ним делать (это уже
//  Progression, которого здесь нет и не должно быть — WeightLadder ни от
//  чего не зависит).
//
//  Три формы лестницы:
//   .discrete    — явный список весов (гантели, гири, штанга: комбинации
//                  дискретны и конечны).
//   .arithmetic  — неограниченная прогрессия с фиксированным шагом
//                  (тренажёр/трос: в equipment_profiles нет максимума стека,
//                  поэтому конечный список построить нельзя — см. несостыковку
//                  в описании PR).
//   .none        — вес не квантуется вовсе (собственный вес, резинки).
public enum WeightLadder: Sendable, Equatable {
    case discrete([Double])
    case arithmetic(step: Double)
    case none

    /// Ближайший достижимый вес строго выше `baseline`.
    /// `nil` — такого веса нет: лестница пуста/исчерпана либо квантования
    /// нет вовсе (`.none`). Это единственный сигнал, на который реагирует
    /// вызывающий код (SPEC §9.5, п. 1: «тяжелее нет вообще»).
    public func nextAchievableWeight(above baseline: Double) -> Double? {
        switch self {
        case .discrete(let weights):
            return weights.filter { $0 > baseline }.min()

        case .arithmetic(let step):
            guard step > 0 else { return nil }
            let stepsBelowOrAt = (baseline / step).rounded(.down)
            return max(step, (stepsBelowOrAt + 1) * step)

        case .none:
            return nil
        }
    }
}

extension WeightLadder {
    /// Строит лестницу для конкретного профиля инвентаря и типа нагрузки.
    public static func build(loadType: LoadType, profile: EquipmentProfile) -> WeightLadder {
        switch loadType {
        case .dumbbell:
            return .discrete(profile.dumbbellsKg.sorted())

        case .kettlebell:
            return .discrete(profile.kettlebellsKg.sorted())

        case .barbell:
            guard let bar = profile.barbellKg else { return .discrete([]) }
            let perSideSums = subsetSums(of: profile.platesKg)
            let totals = perSideSums.map { bar + 2 * $0 }
            return .discrete(Array(Set(totals)).sorted())

        case .machine, .cable:
            guard let step = profile.machineStepKg, step > 0 else { return .discrete([]) }
            return .arithmetic(step: step)

        case .bodyweight, .bodyweightLoaded, .band:
            return .none
        }
    }

    /// Суммы всех подмножеств `plates` — нагрузка на одну сторону штанги.
    /// Каждый блин из списка участвует не больше одного раза на сторону:
    /// `platesKg` уже описывает пары (SPEC §3.1, комментарий к колонке).
    private static func subsetSums(of plates: [Double]) -> [Double] {
        var sums: Set<Double> = [0]
        for plate in plates {
            let extended = sums.map { $0 + plate }
            sums.formUnion(extended)
        }
        return Array(sums)
    }
}
