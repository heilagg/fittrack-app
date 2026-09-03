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
        let baseline = WeightLadder.round2(baseline)
        switch self {
        case .discrete(let weights):
            return weights.filter { $0 > baseline }.min()

        case .arithmetic(let step):
            guard step > 0 else { return nil }
            let stepsBelowOrAt = (baseline / step).rounded(.down)
            return max(step, WeightLadder.round2((stepsBelowOrAt + 1) * step))

        case .none:
            return nil
        }
    }

    /// Округление до сотых — точность колонок веса в Postgres (`numeric(_,2)`,
    /// SPEC §3.1). Суммирование `Double` даёт шум за пределами этой точности
    /// (классика: 0.1 + 0.2 ≠ 0.3), из-за которого subset-sum блинов мог не
    /// дедуплицировать математически равные суммы, а `nextAchievableWeight`
    /// мог сравнить `baseline` с лестницей на пару ULP не в ту сторону.
    /// Округление после каждой арифметической операции и перед сравнением
    /// схлопывает такой шум в одно и то же представление `Double`.
    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

extension WeightLadder {
    /// Строит лестницу для конкретного профиля инвентаря и типа нагрузки.
    public static func build(loadType: LoadType, profile: EquipmentProfile) -> WeightLadder {
        switch loadType {
        case .dumbbell:
            return .discrete(profile.dumbbellsKg.map(round2).sorted())

        case .kettlebell:
            return .discrete(profile.kettlebellsKg.map(round2).sorted())

        case .barbell:
            guard let bar = profile.barbellKg else { return .discrete([]) }
            let perSideSums = subsetSums(of: profile.platesKg)
            let totals = perSideSums.map { round2(bar + 2 * $0) }
            return .discrete(Array(Set(totals)).sorted())

        case .machine, .cable:
            guard let step = profile.machineStepKg, step > 0 else { return .discrete([]) }
            return .arithmetic(step: round2(step))

        case .bodyweight, .bodyweightLoaded, .band:
            return .none
        }
    }

    /// Суммы всех подмножеств `plates` — нагрузка на одну сторону штанги.
    /// Каждый блин из списка участвует не больше одного раза на сторону:
    /// `platesKg` уже описывает пары (SPEC §3.1, комментарий к колонке).
    /// Округляется на каждом шаге (см. `round2`), иначе накопленный шум
    /// `Double` может помешать дедупу сумм от разных подмножеств.
    private static func subsetSums(of plates: [Double]) -> [Double] {
        var sums: Set<Double> = [0]
        for plate in plates {
            let extended = sums.map { round2($0 + plate) }
            sums.formUnion(extended)
        }
        return Array(sums)
    }
}
