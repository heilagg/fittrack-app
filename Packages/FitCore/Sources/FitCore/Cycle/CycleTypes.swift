//  Типы данных Cycle: срезы `cycle_events` / `cycle_profiles` /
//  `phase_response_profile` (SPEC §3.1), нужные конвейеру, плюс типы,
//  которые конвейер производит на выходе.

/// Один зафиксированный факт о цикле — срез `cycle_events`.
public enum CycleEventKind: String, Sendable, Equatable, Hashable {
    case periodStart = "period_start"
    case periodEnd = "period_end"
    case spotting
}

public struct CycleEvent: Sendable, Equatable {
    public var kind: CycleEventKind
    public var occurredOn: CalendarDay

    public init(kind: CycleEventKind, occurredOn: CalendarDay) {
        self.kind = kind
        self.occurredOn = occurredOn
    }
}

/// `cycle_profiles.declared_regularity` — приор для `regularityFactor`,
/// пока не набралось двух измеренных длин (SPEC §11.3).
public enum DeclaredRegularity: String, Sendable, Equatable, Hashable {
    case regular
    case variable
    case irregular
}

/// `cycle_profiles.no_phase_reason` (SPEC §11.5). Только `.lowConfidence`
/// снимается автоматически — остальные утверждают что-то о теле или о
/// выборе пользователя, и отменять их за неё нельзя.
///
/// Асимметрия между `.lowConfidence` и остальными шестью — решение SPEC
/// §11.5, а не пробел в реализации: это единственная причина, снимаемая
/// автоматически, потому что она единственная — утверждение о качестве НАШИХ
/// данных, а не о теле пользовательницы или её выборе. Остальные шесть
/// («только вручную» в таблице §11.5) намеренно не имеют пути автовыхода —
/// `Cycle.applyingCycleClose`/`applyingClosedCycles` реагируют исключительно
/// на `.lowConfidence`, и это не нужно расширять на другие случаи.
public enum NoPhaseReason: String, Sendable, Equatable, Hashable {
    case contraception
    case amenorrhea
    case menopause
    case pregnancy
    case userChoice = "user_choice"
    case declined
    case lowConfidence = "low_confidence"
}

/// Заявленные на онбординге данные — срез `cycle_profiles`, нужный конвейеру.
/// `phaseMode`/`noPhaseReason`/`lowConfidenceStreak` — персистентное состояние
/// режима (SPEC §11.5), не входные приоры; см. `Cycle.applyingCycleClose`.
public struct CycleProfile: Sendable, Equatable {
    public var typicalCycleLengthDays: Int?
    public var typicalPeriodLengthDays: Int?
    public var declaredRegularity: DeclaredRegularity?
    public var phaseMode: PhaseMode
    public var noPhaseReason: NoPhaseReason?
    public var lowConfidenceStreak: Int
    /// SPEC §11.5: дата `period_start`, закрывшего последний УЧТЁННЫЙ в серии
    /// цикл. `nil` — ещё ничего не учтено. Благодаря ей повторный вызов
    /// `applyingClosedCycles` ничего не досчитывает: «ровно один раз на
    /// закрытие» — свойство состояния, а не обязанность вызывающего кода.
    public var lowConfidenceCountedThrough: CalendarDay?

    public init(
        typicalCycleLengthDays: Int? = nil,
        typicalPeriodLengthDays: Int? = nil,
        declaredRegularity: DeclaredRegularity? = nil,
        phaseMode: PhaseMode = .phases,
        noPhaseReason: NoPhaseReason? = nil,
        lowConfidenceStreak: Int = 0,
        lowConfidenceCountedThrough: CalendarDay? = nil
    ) {
        self.typicalCycleLengthDays = typicalCycleLengthDays
        self.typicalPeriodLengthDays = typicalPeriodLengthDays
        self.declaredRegularity = declaredRegularity
        self.phaseMode = phaseMode
        self.noPhaseReason = noPhaseReason
        self.lowConfidenceStreak = lowConfidenceStreak
        self.lowConfidenceCountedThrough = lowConfidenceCountedThrough
    }
}

/// Тип блока тренировки, который фаза диктует (SPEC §11.2, столбец «Тип
/// блока»). `.neutral` — ниже категориального порога `cycleConfidence ≥ 0.3`,
/// когда категорию присваивать нечему опереться (SPEC §11.2, §11.3).
public enum BlockType: Sendable, Equatable {
    case recovery
    case strength
    case peak
    case volumeAccumulation
    case deload
    case neutral
}

/// Вклад фазы в подбор и объём (SPEC §11.2) — то, что PhasePolicy выдаёт
/// вызывающей стороне (Planner) на день с известной фазой в режиме `phases`.
///
/// `volumeMultiplier`/`rirShift` уже умножены на `cycleConfidence`
/// (непрерывно, SPEC §11.2); `blockType` уже гейтится порогом 0.3
/// (категориально, тот же раздел). `reason` несёт `cycleConfidence`,
/// при котором эти числа посчитаны (SPEC §14.6) — слой представления решает,
/// показывать ли фазу утвердительно, по этому значению, а не по одной
/// мягкости формулировки.
public struct PhasePeriodization: Sendable, Equatable {
    public var volumeMultiplier: Double
    public var rirShift: Int
    public var blockType: BlockType
    public var reason: ReasonCode

    public init(volumeMultiplier: Double, rirShift: Int, blockType: BlockType, reason: ReasonCode) {
        self.volumeMultiplier = volumeMultiplier
        self.rirShift = rirShift
        self.blockType = blockType
        self.reason = reason
    }
}

/// Личный профиль фазовой реакции — срез `phase_response_profile` (SPEC
/// §11.4). `notified` заменяет `notified_at`: логике нужен только факт
/// «уже показывали», а не момент времени.
public struct PhaseResponseProfile: Sendable, Equatable {
    public var adjustment: Double
    public var sampleSize: Int
    public var notified: Bool

    public init(adjustment: Double = 0, sampleSize: Int = 0, notified: Bool = false) {
        self.adjustment = adjustment
        self.sampleSize = sampleSize
        self.notified = notified
    }
}

/// Итог конвейера Cycle на конкретный день (SPEC §11) — вход для Readiness
/// (`effectivePhaseAdjustment`, `cycleConfidence`) и Planner (`periodization`).
///
/// Оверрайда здесь нет и не должно быть. `daily_checkins.override` — сырой
/// ввод, а не производная цикла: Readiness читает его напрямую и подставляет
/// ВМЕСТО фазовой поправки (SPEC §10, `phaseTerm`), а Cycle получает его
/// отдельно, в `applyingOverride` для обучения профиля (SPEC §11.4). Прокинуть
/// его через это значение означало бы завести второй путь к тому же полю.
///
/// `phase`/`cycleConfidence`/`periodization`/`effectivePhaseAdjustment` — все
/// вместе `nil`, когда фаза не вычисляется: опорной даты нет (SPEC §11.3) или
/// режим `no_phases` (SPEC §11.5). Различить эти два случая — по `phaseMode`
/// и `hasAnchor`.
public struct CycleState: Sendable, Equatable {
    public var phaseMode: PhaseMode
    public var noPhaseReason: NoPhaseReason?
    public var hasAnchor: Bool
    public var phase: Phase?
    public var cycleConfidence: Double?
    public var periodization: PhasePeriodization?
    /// `effectiveVolumeShift`/`effectiveRIRShift` уже несут `cycleConfidence`
    /// внутри себя; `effectivePhaseAdjustment` — нет, это сырое слагаемое
    /// для формулы Readiness (`phaseTerm = effectivePhaseAdjustment ×
    /// cycleConfidence`, SPEC §10) и оно должно остаться неумноженным,
    /// чтобы Readiness не перемножил дважды.
    public var effectivePhaseAdjustment: Double?

    public init(
        phaseMode: PhaseMode,
        noPhaseReason: NoPhaseReason?,
        hasAnchor: Bool,
        phase: Phase?,
        cycleConfidence: Double?,
        periodization: PhasePeriodization?,
        effectivePhaseAdjustment: Double?
    ) {
        self.phaseMode = phaseMode
        self.noPhaseReason = noPhaseReason
        self.hasAnchor = hasAnchor
        self.phase = phase
        self.cycleConfidence = cycleConfidence
        self.periodization = periodization
        self.effectivePhaseAdjustment = effectivePhaseAdjustment
    }
}
