//  Три уровня инвентаря (SPEC §6.6, «Три уровня инвентаря») — они же три
//  пресета онбординга (§5, шаг 7).
//
//  Живут в FitContent, а не в FitCore и не в валидаторе, по двум причинам.
//  Первая: это данные продукта, зафиксированные таблицей SPEC, а не логика —
//  `FitCore` от таких таблиц свободен по построению (§2.1). Вторая: потребителей
//  двое, и они в разных пакетах — валидатор проверяет на этих профилях правило
//  покрытия §20.11, а онбординг предлагает их как пресеты. Копия в каждом
//  разошлась бы, и разошлась бы молча: покрытие проверялось бы на профиле, на
//  котором никто не тренируется.
//
//  Порядок объявления — от беднейшего к богатейшему, и он несущий: §20.11
//  стоит на том, что профили ВЛОЖЕНЫ (без железа ⊂ гантели ⊂ зал), а
//  выполнимость §6.6 по доступности монотонна. Поэтому покрытие нижнего уровня
//  влечёт покрытие двух верхних, и валидатору достаточно нижнего. Вложенность
//  проверяется тестом, а не держится на внимательности: сняв резинки с «зала»,
//  можно было бы незаметно сделать уровни несравнимыми.

import FitCore

/// Уровень инвентаря: пресет §5 шаг 7 и ось правила покрытия §20.11.
public enum EquipmentLevel: String, Sendable, Equatable, Hashable, CaseIterable {
    case bodyweight = "home_bodyweight"
    case dumbbells = "home_dumbbells"
    case gym

    /// Название пресета на экране инвентаря (§5, шаг 7).
    public var title: String {
        switch self {
        case .bodyweight: return "Дома без железа"
        case .dumbbells: return "Дома с гантелями"
        case .gym: return "Зал"
        }
    }

    /// Веса уровня — вход лестницы достижимых весов (§9.5).
    public var equipment: EquipmentProfile {
        switch self {
        case .bodyweight:
            // Пустой профиль целиком: собственный вес и ничего больше.
            return EquipmentProfile()
        case .dumbbells:
            return EquipmentProfile(dumbbellsKg: [5, 7.5, 10, 12.5, 15, 17.5, 20])
        case .gym:
            // Непрерывный шаг 2.5 кг — прямое требование §5, шаг 7.
            return EquipmentProfile(
                dumbbellsKg: stride(from: 2.5, through: 50, by: 2.5).map { $0 },
                kettlebellsKg: stride(from: 8, through: 32, by: 4).map { $0 },
                platesKg: [1.25, 2.5, 5, 10, 15, 20],
                barbellKg: 20,
                machineStepKg: 2.5)
        }
    }

    /// Всё остальное, что читает словарь требований §6.6.
    public var availability: EquipmentAvailability {
        switch self {
        case .bodyweight:
            // Резинок здесь нет намеренно: сценарий §18 28 («инвентарь только
            // резинки») задаётся детальной настройкой, а не пресетом (§6.6).
            return EquipmentAvailability()
        case .dumbbells:
            return EquipmentAvailability()
        case .gym:
            return EquipmentAvailability(
                bench: .adjustable, pullupBar: true, bands: true, hasKettlebells: true,
                cableMachine: true, stepPlatform: true, plyoBox: true,
                machines: Set(EquipmentLevel.machineSlugs))
        }
    }

    /// Закрытый список слагов тренажёров (§6.6). Разметка вне этого списка —
    /// ошибка: `machines` в §3.1 свободный `text[]`, и опечатка в слаге иначе
    /// делала бы упражнение невыполнимым навсегда и молча.
    public static let machineSlugs: [String] = [
        "leg_press", "leg_extension", "leg_curl", "hip_abduction", "calf_raise",
        "lat_pulldown", "seated_row", "back_extension", "chest_press", "pec_deck",
        "shoulder_press", "ab_crunch",
    ]

    /// Требования §6.6, выполнимые на этом уровне. Через него проверяется
    /// вложенность уровней — то свойство, на котором стоит §20.11.
    public var satisfiedRequirements: Set<EquipmentRequirement> {
        let all: [EquipmentRequirement] = [
            .benchFlat, .benchAdjustable, .pullupBar, .bands, .kettlebells,
            .cableMachine, .stepPlatform, .plyoBox,
        ] + EquipmentLevel.machineSlugs.map { .machine($0) }
        return Set(all.filter { availability.satisfies($0) })
    }
}
