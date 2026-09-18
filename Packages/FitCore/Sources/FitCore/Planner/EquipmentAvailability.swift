//  Второй вход инвентаря планировщика (SPEC §7.5, §6.6): всё, что читает
//  словарь требований, кроме весов. Веса — `EquipmentProfile` и лестница
//  (Equipment/), их здесь нет намеренно: «есть ли чем нагрузить» отвечает
//  лестница, и второй источник истины для этого вопроса не нужен.
//
//  Контракт согласованности (§7.5) проверяет вызывающая сторона: при снятом
//  `has_kettlebells` она передаёт `kettlebells_kg` пустым, без блока и
//  тренажёров — `machine_step_kg` пустым.

public enum BenchType: String, Sendable, Equatable, Hashable {
    case flat
    case adjustable
}

public struct EquipmentAvailability: Sendable, Equatable {
    public var bench: BenchType?
    public var pullupBar: Bool
    public var bands: Bool
    public var hasKettlebells: Bool
    public var cableMachine: Bool
    public var machines: Set<String>

    public init(
        bench: BenchType? = nil,
        pullupBar: Bool = false,
        bands: Bool = false,
        hasKettlebells: Bool = false,
        cableMachine: Bool = false,
        machines: Set<String> = []
    ) {
        self.bench = bench
        self.pullupBar = pullupBar
        self.bands = bands
        self.hasKettlebells = hasKettlebells
        self.cableMachine = cableMachine
        self.machines = machines
    }

    /// Предикат словаря §6.6.
    public func satisfies(_ requirement: EquipmentRequirement) -> Bool {
        switch requirement {
        case .benchFlat: return bench != nil
        case .benchAdjustable: return bench == .adjustable
        case .pullupBar: return pullupBar
        case .bands: return bands
        case .kettlebells: return hasKettlebells
        case .cableMachine: return cableMachine
        case .machine(let slug): return machines.contains(slug)
        }
    }
}

extension Planner {
    /// Выполнимость на текущем инвентаре (SPEC §6.6): каждое требование
    /// выполнено И у весового `load_type` лестница не пуста. `bodyweight`,
    /// `bodyweight_loaded` и `band` лестницы не имеют (`.none`) и вторым
    /// условием не ограничены.
    public static func isFeasible(
        _ candidate: ExerciseCandidate,
        availability: EquipmentAvailability,
        equipment: EquipmentProfile
    ) -> Bool {
        guard candidate.equipment.allSatisfy(availability.satisfies) else { return false }
        if case .discrete(let rungs) = WeightLadder.build(loadType: candidate.loadType, profile: equipment) {
            return !rungs.isEmpty
        }
        return true
    }
}
