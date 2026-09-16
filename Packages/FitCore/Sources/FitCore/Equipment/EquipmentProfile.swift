//  EquipmentProfile — подмножество таблицы `equipment_profiles` (SPEC §3.1),
//  которое определяет достижимые веса. Остальные поля профиля (bench,
//  pullup_bar, machines и т.п.) влияют на подбор упражнений в
//  FitContent/Planner, а не на квантование веса, и здесь не нужны: Planner
//  получает их отдельным срезом `EquipmentAvailability` (SPEC §7.5).
//
//  Флаги из схемы главнее kg-колонок: пользователь мог снять «есть гири», не
//  очистив `kettlebells_kg`. Контракт SPEC §7.5 — вызывающая сторона передаёт
//  сюда `kettlebellsKg` пустым при снятом `has_kettlebells`, а `machineStepKg`
//  пустым, если нет ни блока, ни тренажёров; этот тип флагов не видит и сам
//  согласовать их не может.

/// Инвентарь пользователя в объёме, необходимом для построения `WeightLadder`.
public struct EquipmentProfile: Sendable, Equatable {
    /// Веса гантелей, доступные пользователю (на одну руку), кг.
    public var dumbbellsKg: [Double]
    /// Веса гирь, доступные пользователю, кг.
    public var kettlebellsKg: [Double]
    /// Отдельные блины на штангу; вес пары считается ×2 (SPEC §3.1).
    public var platesKg: [Double]
    /// Вес грифа, кг. `nil` — штанги нет.
    public var barbellKg: Double?
    /// Шаг стека тренажёра/блочной рамы, кг. `nil` — тренажёра/троса нет.
    public var machineStepKg: Double?

    public init(
        dumbbellsKg: [Double] = [],
        kettlebellsKg: [Double] = [],
        platesKg: [Double] = [],
        barbellKg: Double? = nil,
        machineStepKg: Double? = nil
    ) {
        self.dumbbellsKg = dumbbellsKg
        self.kettlebellsKg = kettlebellsKg
        self.platesKg = platesKg
        self.barbellKg = barbellKg
        self.machineStepKg = machineStepKg
    }
}
