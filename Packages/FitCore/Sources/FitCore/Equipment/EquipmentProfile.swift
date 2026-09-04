//  EquipmentProfile — подмножество таблицы `equipment_profiles` (SPEC §3.1),
//  которое определяет достижимые веса. Остальные поля профиля (bench,
//  pullup_bar, machines и т.п.) влияют на подбор упражнений в
//  FitContent/Planner, а не на квантование веса, и здесь не нужны.
//
//  TODO(код-ревью feature/weight-ladder, 2026-09-04): здесь нет
//  has_kettlebells/cable_machine из схемы equipment_profiles — эти булевы
//  флаги в БД первичны над kg-колонками (пользователь мог снять галочку
//  «есть гири», не очистив kettlebells_kg). Пока сюда никто не маппит строки
//  FitData, это безопасно; актуально станет, когда появится маппинг
//  FitData → EquipmentProfile. Не тронуто по решению ревью (не блокирует
//  мерж).

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
