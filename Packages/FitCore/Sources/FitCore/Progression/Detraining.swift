//  Детренированность (SPEC §9.7) — перерыв в тренировках по конкретному
//  упражнению снижает базовую линию перед первой сессией после перерыва.

extension Progression {
    public enum DetrainingAdjustment: Sendable, Equatable {
        case none
        case mildDecay          // 11–21 день: ×0.92
        case moderateDecay      // 22–45 дней: ×0.85, rep_extension = 0
        case restartCalibration // > 45 дней: ×0.75, in_calibration = true
    }

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
