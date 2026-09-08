//  Множитель готовности и защита базовой линии (SPEC §9.6).
//
//  Единственное место, где живёт демпфирование обновлений `baseline_kg` —
//  см. doc-комментарий Progression.swift. Ничего не знает о том, ПОЧЕМУ
//  baseline меняется (раньше/позже — RebuildStates), только НАСКОЛЬКО
//  сильно применять уже посчитанную дельту.

/// SPEC §9.6: дневная готовность не должна портить долгосрочную базовую
/// линию. Фидбэк, полученный в день с readiness < 0.95, обновляет
/// `baseline_kg` с демпфированием ×0.4 вместо ×1.0 — иначе, например, каждая
/// менструальная фаза откатывала бы прогресс на месяц назад.
public enum BaselineUpdater {
    public static func dampingFactor(readiness: Double) -> Double {
        readiness < 0.95 ? 0.4 : 1.0
    }

    /// Применяет демпфирование к уже посчитанной дельте базовой линии
    /// (`target - baseline`, знак значения не имеет) и возвращает новую
    /// базовую линию.
    public static func apply(baseline: Double, target: Double, readiness: Double) -> Double {
        baseline + (target - baseline) * dampingFactor(readiness: readiness)
    }
}
