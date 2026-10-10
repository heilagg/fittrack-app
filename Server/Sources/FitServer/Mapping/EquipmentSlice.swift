//  Срез `equipment_profiles` (SPEC §3.1, §6.6, §7.5, §20.6).
//
//  Одна строка даёт ДВА значения FitCore, и это не удобство, а §7.5: планировщик
//  спрашивает инвентарь двумя разными вопросами. `EquipmentAvailability`
//  отвечает на «выполнимо ли упражнение» (словарь требований §6.6),
//  `EquipmentProfile` — на «какие веса достижимы» (лестница §9.5). Смешивать их
//  нельзя: у упражнения на резинках требование есть, а лестницы нет.
//
//  ── Два правила §20.6, которые здесь считаются, а не перекладываются ───────
//
//  «Флаг главнее своей весовой колонки» (§7.5) — в двух экземплярах, потому что
//  флагов два:
//
//    has_kettlebells = false            → kettlebellsKg = []
//    ни троса, ни тренажёров            → machineStepKg = nil
//
//  Оба случая одного рода и оба тихие. Оставленный набор гирь при снятом флаге
//  строит лестницу по гирям, которых нет, — и пользовательница получает
//  предписание на вес, который ей неоткуда взять. Ошибка не падает и в ответе
//  не видна: число правдоподобно.
//
//  Второй флаг сложнее первого, и §20.6 называет его отдельно именно поэтому:
//  своей булевой колонки у шага стека нет. Шаг осмыслен, если есть хоть что-то
//  со стеком — трос либо тренажёр, — так что признак собирается из двух колонок,
//  а не читается из одной.

import FitCore

extension Mapping {

    /// Строка `equipment_profiles` (§3.1).
    public struct EquipmentRow: Sendable, Equatable {
        public var dumbbellsKg: [Double]
        public var platesKg: [Double]
        public var barbellKg: Double?
        public var machineStepKg: Double?
        public var hasKettlebells: Bool
        public var kettlebellsKg: [Double]
        public var bands: Bool
        public var pullupBar: Bool
        /// `null` | `flat` | `adjustable`.
        public var bench: String?
        public var cableMachine: Bool
        public var machines: [String]
        public var stepPlatform: Bool
        public var plyoBox: Bool

        public init(dumbbellsKg: [Double] = [], platesKg: [Double] = [], barbellKg: Double? = nil,
                    machineStepKg: Double? = nil, hasKettlebells: Bool = false,
                    kettlebellsKg: [Double] = [], bands: Bool = false, pullupBar: Bool = false,
                    bench: String? = nil, cableMachine: Bool = false, machines: [String] = [],
                    stepPlatform: Bool = false, plyoBox: Bool = false) {
            self.dumbbellsKg = dumbbellsKg
            self.platesKg = platesKg
            self.barbellKg = barbellKg
            self.machineStepKg = machineStepKg
            self.hasKettlebells = hasKettlebells
            self.kettlebellsKg = kettlebellsKg
            self.bands = bands
            self.pullupBar = pullupBar
            self.bench = bench
            self.cableMachine = cableMachine
            self.machines = machines
            self.stepPlatform = stepPlatform
            self.plyoBox = plyoBox
        }
    }

    /// Инвентарь обоими вопросами §7.5 сразу.
    public struct EquipmentSlice: Sendable, Equatable {
        public var profile: EquipmentProfile
        public var availability: EquipmentAvailability

        public init(profile: EquipmentProfile, availability: EquipmentAvailability) {
            self.profile = profile
            self.availability = availability
        }
    }

    public static func equipment(from row: EquipmentRow) -> EquipmentSlice {
        // §20.6, обязанность 4: набор гирь передаётся пустым, как бы ни была
        // заполнена колонка.
        let kettlebells = row.hasKettlebells ? row.kettlebellsKg.sorted() : []
        let machines = Set(row.machines)
        // §20.6, обязанность 5: шаг стека — под своим флагом, и флага у него
        // своего нет. Квантовать нечего, если ни троса, ни тренажёров.
        let hasStack = row.cableMachine || !machines.isEmpty
        return EquipmentSlice(
            profile: EquipmentProfile(
                dumbbellsKg: row.dumbbellsKg.sorted(),
                kettlebellsKg: kettlebells,
                platesKg: row.platesKg.sorted(),
                barbellKg: row.barbellKg,
                machineStepKg: hasStack ? row.machineStepKg : nil
            ),
            availability: EquipmentAvailability(
                // Значение вне словаря — как будто скамьи нет: `bench` без
                // `check` в схеме, и «скамья, которой мы не знаем» не годится
                // ни под `bench_flat`, ни под `bench_adjustable` (§6.6).
                bench: row.bench.flatMap(BenchType.init(rawValue:)),
                pullupBar: row.pullupBar,
                bands: row.bands,
                hasKettlebells: row.hasKettlebells,
                cableMachine: row.cableMachine,
                stepPlatform: row.stepPlatform,
                plyoBox: row.plyoBox,
                machines: machines
            )
        )
    }
}
