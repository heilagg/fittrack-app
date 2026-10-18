//  Подпись снаряда на экране упражнения (SPEC §6.6, «Подпись снаряда на
//  экране»; §13.2, §13.4, §20.11).
//
//  Каталог формулировок, как названия типов дня (`ReasonStrings`): список,
//  размноженный по вебу и iOS, расходится тихо, поэтому он живёт здесь, и iOS
//  в офлайне читает тот же.
//
//  ── Почему из `load_type` и `equipment`, а не отдельным полем разметки ───
//
//  Снаряд упражнения уже записан в этих двух полях, и второе поле разошлось бы
//  с ними на первой правке. Гантели и штанга требованием словаря §6.6 не
//  являются — их отвечает лестница весов, — поэтому их подпись даёт
//  `load_type`; всё остальное даёт требование.
//
//  ── Закрытость словаря проверяет компилятор ───────────────────────────────
//
//  `switch` по `EquipmentRequirement` без `default`: новое значение словаря не
//  соберётся без своей подписи — это и есть «тест FitAPI падает на значении
//  без неё» из §6.6. Слаги тренажёров — строки, и их полноту сверяет тест с
//  закрытым списком §6.6 (`EquipmentLabelsTests`).

import FitCore

public enum EquipmentLabels {

    /// Русские названия тренажёров (§6.6). В базу пишется слаг.
    public static let machineNames: [String: String] = [
        "leg_press": "Жим ногами",
        "leg_extension": "Разгибание ног",
        "leg_curl": "Сгибание ног",
        "hip_abduction": "Разведение ног",
        "calf_raise": "Подъём на носки",
        "lat_pulldown": "Верхний блок",
        "seated_row": "Горизонтальная тяга",
        "back_extension": "Гиперэкстензия",
        "chest_press": "Жим от груди",
        "pec_deck": "Бабочка",
        "shoulder_press": "Жим над головой",
        "ab_crunch": "Тренажёр для пресса",
        "hip_adduction": "Сведение ног",
        "chest_supported_row": "Тяга в тренажёре с упором грудью",
        "assisted_pullup": "Гравитрон",
        "smith": "Тренажёр Смита",
    ]

    /// Слаг Смита: при нём `load_type: barbell` подписи «Штанга» не даёт —
    /// штанга там способ счёта веса, а не снаряд, который ищут в зале (§6.6).
    static let smithSlug = "smith"

    /// Подписи в порядке строк таблицы §6.6: сначала чем нагружают, потом
    /// опоры. Пустой массив — у упражнения снаряда нет, строка не показывается.
    public static func labels(loadType: LoadType, equipment: [EquipmentRequirement]) -> [String] {
        let requirements = Set(equipment)
        let isSmith = requirements.contains(.machine(smithSlug))
        var result: [String] = []
        func add(_ label: String) {
            if !result.contains(label) { result.append(label) }
        }

        switch loadType {
        case .dumbbell: add("Гантели")
        case .barbell: if !isSmith { add("Штанга") }
        // Гири, блок, тренажёр и резинка подписываются своим требованием, а
        // собственный вес снаряда не имеет.
        case .kettlebell, .cable, .machine, .band, .bodyweight, .bodyweightLoaded: break
        }

        // Порядок таблицы §6.6, а не порядок в разметке: два упражнения с одним
        // снарядом не должны подписываться по-разному.
        let order: [EquipmentRequirement] = [.kettlebells, .cableMachine]
            + equipment.compactMap { if case .machine = $0 { return $0 } else { return nil } }
            + [.benchFlat, .benchAdjustable, .pullupBar, .bands, .stepPlatform, .plyoBox]
        for requirement in order where requirements.contains(requirement) {
            add(label(requirement))
        }
        return result
    }

    /// Подпись одного требования словаря §6.6.
    public static func label(_ requirement: EquipmentRequirement) -> String {
        switch requirement {
        case .kettlebells: return "Гири"
        case .cableMachine: return "Блочный тренажёр (кроссовер)"
        case .machine(let slug):
            // Слаг вне закрытого списка — брак разметки, его ловит валидатор
            // (§19.1); показать слаг лучше, чем пустое место.
            return machineNames[slug] ?? slug
        case .benchFlat: return "Скамья"
        case .benchAdjustable: return "Регулируемая скамья"
        case .pullupBar: return "Турник"
        case .bands: return "Резинка"
        case .stepPlatform: return "Степ-платформа"
        case .plyoBox: return "Тумба"
        }
    }
}
