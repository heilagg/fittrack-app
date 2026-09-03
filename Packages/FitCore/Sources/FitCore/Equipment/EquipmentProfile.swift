//  EquipmentProfile — подмножество таблицы `equipment_profiles` (SPEC §3.1),
//  которое определяет достижимые веса. Остальные поля профиля (bench,
//  pullup_bar, machines и т.п.) влияют на подбор упражнений в
//  FitContent/Planner, а не на квантование веса, и здесь не нужны.

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
