//  Детренированность (SPEC §9.7) — перерыв в тренировках по конкретному
//  упражнению снижает базовую линию перед первой сессией после перерыва.

extension Progression {
    public enum DetrainingAdjustment: Sendable, Equatable {
        case none
        case mildDecay          // 11–21 день: ×0.92
        case moderateDecay      // 22–45 дней: ×0.85, rep_extension = 0
        case restartCalibration // > 45 дней: ×0.75, in_calibration = true

        /// Множитель базовой линии.
        public var baselineMultiplier: Double {
            switch self {
            case .none: return 1.0
            case .mildDecay: return 0.92
            case .moderateDecay: return 0.85
            case .restartCalibration: return 0.75
            }
        }

        /// Сбрасываются ли `rep_extension` и `extra_sets_added` (с 22 дней).
        public var resetsProgressionCounters: Bool {
            self == .moderateDecay || self == .restartCalibration
        }

        /// Возвращается ли упражнение в калибровку (больше 45 дней).
        public var restartsCalibration: Bool { self == .restartCalibration }
    }

    /// Числа таблицы §9.7 — одни на свёртку (`rebuildStates`, когда сессия
    /// после перерыва записана) и на предписание планировщика (перед этой
    /// сессией). Два места, читающие одно правило, — поэтому числа здесь, а не
    /// литералами в каждом.
    public static func detrainingAdjustment(daysSinceLastPerformed days: Int) -> DetrainingAdjustment {
        switch days {
        case ..<11:
            return .none
        case 11...21:
            return .mildDecay
        case 22...45:
            return .moderateDecay
        default:
            return .restartCalibration
        }
    }
}
