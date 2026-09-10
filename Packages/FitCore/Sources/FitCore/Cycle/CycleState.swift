//  Cycle.state(...) — верхний уровень конвейера (см. doc-комментарий
//  Cycle.swift): CycleHistory.derive → LengthEstimator.expected →
//  PhaseResolver.phase → ConfidenceModel.confidence → CycleState →
//  PhasePolicy. Единственная публичная точка входа, которая сводит все
//  частные функции модуля в одно значение на день.
//
//  Три состояния, различающие холодный старт (SPEC §11.3), возвращают
//  `phase = nil` каждое по своей причине — коды ниже читать вместе с
//  таблицей doc-комментария Cycle.swift, «Холодный старт»:
//   - `phaseMode == .noPhases`               — режим без фаз (SPEC §11.5)
//   - `phaseMode == .phases, hasAnchor == false` — опорной даты нет вовсе
//   - иначе `phase` всегда определена — «ноль измеренных циклов» (сценарий
//     15/15b) НЕ отдельная ветка здесь: `expectedLength`/`dataFactor`
//     сами по себе корректно деградируют при пустой истории.
public enum Cycle {}

extension Cycle {

    /// `responseProfiles` — личный профиль по фазам (SPEC §11.4), обычно
    /// результат `rebuildingProfiles(from:)`; пустой словарь эквивалентен
    /// «профиль ещё не набрал sampleSize ≥ 3 ни по одной фазе».
    ///
    /// Дефолта у `responseProfiles` намеренно нет — как и у состояния в
    /// `Recovery.applying(_:at:to:)` и `Progression.rebuildStates(from:…)`.
    /// Забытый аргумент здесь неотличим по поведению от «профиль пуст»: обе
    /// пользовательницы получат дефолт популяции, но одна из них потеряет
    /// месяцы обучения (SPEC §11.4) без единого сигнала. Пусть лучше не
    /// компилируется.
    public static func state(
        events: [CycleEvent],
        profile: CycleProfile,
        responseProfiles: [Phase: PhaseResponseProfile],
        asOf today: CalendarDay
    ) -> CycleState {
        let day = cycleDay(events: events, asOf: today)

        guard profile.phaseMode == .phases else {
            return CycleState(
                phaseMode: .noPhases,
                noPhaseReason: profile.noPhaseReason,
                hasAnchor: day != nil,
                phase: nil,
                cycleConfidence: nil,
                periodization: nil,
                effectivePhaseAdjustment: nil
            )
        }

        guard let day else {
            return CycleState(
                phaseMode: .phases,
                noPhaseReason: nil,
                hasAnchor: false,
                phase: nil,
                cycleConfidence: nil,
                periodization: nil,
                effectivePhaseAdjustment: nil
            )
        }

        let lengths = measuredLengths(from: events)
        let expectedLen = expectedLength(measuredLengths: lengths, profile: profile)
        let resolvedPhase = phase(
            forDay: day,
            expectedLength: expectedLen,
            menstrualEnd: menstrualEnd(events: events, profile: profile)
        )
        let confidence = cycleConfidence(
            dataFactor: dataFactor(measuredCount: lengths.count),
            regularityFactor: regularityFactor(
                filteredLengths: recentFilteredLengths(lengths),
                declaredRegularity: profile.declaredRegularity
            ),
            recencyFactor: recencyFactor(cycleDay: day, expectedLength: expectedLen)
        )

        return CycleState(
            phaseMode: .phases,
            noPhaseReason: nil,
            hasAnchor: true,
            phase: resolvedPhase,
            cycleConfidence: confidence,
            periodization: periodization(phase: resolvedPhase, cycleConfidence: confidence),
            effectivePhaseAdjustment: effectiveReadinessAdjustment(
                phase: resolvedPhase,
                profile: responseProfiles[resolvedPhase] ?? PhaseResponseProfile()
            )
        )
    }
}
