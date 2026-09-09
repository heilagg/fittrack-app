//  Обучение личного профиля фазовой реакции по оверрайдам (SPEC §11.4).
//
//  Применяется В ПОЛНОЧЬ, по ИТОГОВОМУ значению `override` за день — не в
//  момент нажатия. `daily_checkins.override` — одна колонка на дату, поэтому
//  «push, затем через час ease» уже свёрнуто источником в одно значение
//  (последнее); эта функция обрабатывает один день — один вызов, без отката.
//
//  `rest` не учится (SPEC §11.4: слишком шумный сигнал — чаще про жизнь вне
//  цикла, чем про фазовую реакцию). `nil` (не нажимали) — тоже не учится.
//
//  `phase_response_profile` копится по дням через одну и ту же операцию
//  (delta → clamp → sampleSize += 1), поэтому это ровно тот случай свёртки
//  по сессиям, для которого implement-feature §5а требует многосессионную
//  симуляцию — см. `PhaseResponseProfileTests.test_simulation30Sessions`.
extension Cycle {

    /// SPEC §11.4: сдвиг за один день оверрайда, до clamp. `nil` — день не
    /// учится (`rest` или отсутствие оверрайда).
    static func learningDelta(for override: Override?) -> Double? {
        switch override {
        case .push: return 0.02
        case .ease: return -0.02
        case .rest, .none: return nil
        }
    }

    public static let phaseAdjustmentClampRange = -0.15...0.15
    /// SPEC §11.4: с какого `sampleSize` профиль начинает действовать и
    /// уведомление показывается один раз.
    public static let phaseAdjustmentAppliesFromSampleSize = 3

    /// Один день обучения: если `phase` известна и `override` учится
    /// (`push`/`ease`), сдвигает `adjustment` (clamp ±0.15) и увеличивает
    /// `sampleSize`. `justNotified` — true ровно в тот день, когда
    /// `sampleSize` впервые достиг 3 (SPEC §11.4: «сообщение показывается
    /// один раз на фазу», факт зафиксирован в `notified`, чтобы повторный
    /// вызов после этого дня больше не сигналил).
    public static func applyingOverride(
        _ override: Override?,
        to profile: PhaseResponseProfile
    ) -> (profile: PhaseResponseProfile, justNotified: Bool) {
        guard let delta = learningDelta(for: override) else { return (profile, false) }
        var profile = profile
        profile.adjustment = min(
            phaseAdjustmentClampRange.upperBound,
            max(phaseAdjustmentClampRange.lowerBound, profile.adjustment + delta)
        )
        profile.sampleSize += 1
        let justNotified = !profile.notified && profile.sampleSize >= phaseAdjustmentAppliesFromSampleSize
        if justNotified { profile.notified = true }
        return (profile, justNotified)
    }

    /// Полная свёртка по журналу дней (SPEC §4.3: пересчёт из истории решает
    /// конфликт синхронизации так же, как `rebuildStates` у Progression) —
    /// `days` в хронологическом порядке, один элемент на день с известной
    /// фазой. Профиль для фазы, ни разу не встретившейся в `days`, отсутствует
    /// в результате (эквивалентно `PhaseResponseProfile()`).
    public static func rebuildingProfiles(from days: [(phase: Phase, override: Override?)]) -> [Phase: PhaseResponseProfile] {
        var profiles: [Phase: PhaseResponseProfile] = [:]
        for day in days {
            let current = profiles[day.phase] ?? PhaseResponseProfile()
            profiles[day.phase] = applyingOverride(day.override, to: current).profile
        }
        return profiles
    }
}
