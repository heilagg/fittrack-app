//  rebuildStates(from:) — центральная функция модуля (см. doc-комментарий
//  Progression.swift): состояние есть свёртка над журналом подходов, а не
//  инкрементально обновляемая запись. Отсюда бесплатно следуют:
//   - разрешение конфликтов синхронизации `exercise_states` (SPEC §4.3,
//     §18 сценарий 35) — при конфликте просто пересчитать из истории;
//   - инвалидация кэша при смене алгоритма — пересчёт с нуля всегда даёт
//     состояние, согласованное с текущей версией правил.
//
//  Реакция между сессиями (SPEC §9.4): смотрим на последнюю сессию (подъём
//  и застой) и на две последние (недобор до rep_min для понижения).
//
//  Несостыковка со SPEC (задокументировано в теле коммита, не в SPEC.md):
//  §9.4/§9.5 описывают шаг веса как ступень лестницы ОТ baseline_kg, но
//  §18 сценарии 10–11 требуют учитывать вес, который пользователь ФАКТИЧЕСКИ
//  ввёл (`actual_kg`), если он отличается от прописанного. Решение: если
//  фактический вес последнего рабочего подхода сессии отличается от
//  baseline больше чем на полцента, он становится опорной точкой для
//  вычисления цели (округлённой к достижимой ступени в нужную сторону)
//  вместо ступени лестницы от старого baseline — иначе понижение задним
//  числом наказывало бы дважды (шаг вниз ПОВЕРХ уже сниженного пользователем
//  веса), а повышение игнорировало бы уже подтверждённый более тяжёлый вес.
//
//  Вторая несостыковка, из той же пары сценариев: §9.4 перечисляет
//  понижение только по двум признакам («две сессии подряд с недобором» или
//  «одна сессия с двумя failed») — ни один из них не срабатывает на
//  сценарии 11 (одна сессия, один `hard`, повторы в диапазоне, но вес уже
//  снижен пользователем). Решение: добавлен третий, не описанный в SPEC
//  триггер понижения — уже сниженный вход (`actual_kg` заметно ниже
//  baseline) при `hard`/`failed` в той же сессии — иначе `actual_kg` ниже
//  baseline вообще ни на что не влияет, что явно противоречит тексту
//  сценария 11.
extension Progression {

    private static let centEpsilonKg = 0.005

    /// `sessions` — сессии одного упражнения одного пользователя в
    /// хронологическом порядке (от старой к новой); свёртка не сортирует.
    /// `baseRange` — целевой диапазон повторов от цели (Goal), не меняется
    /// в ходе прогрессии (меняется только `repExtension` поверх него).
    ///
    /// Сознательно не реализовано (нет ни одного сценария SPEC §18,
    /// закреплённого за Progression, который бы это требовал):
    /// - `increaseWeightWithRepReset` не сохраняет сузившийся диапазон
    ///   повторов в `ExerciseState` — решение доступно вызывающему через
    ///   `WeightDecision`, но сама свёртка обрабатывает его как обычное
    ///   повышение веса (baseline меняется, repExtension сбрасывается);
    /// - «до 3 повышений за упражнение в калибровке за сессию» (SPEC §9.8)
    ///   не ограничивается — счётчик на уровне сессии, а не между ними;
    /// - стартовый калибровочный вес (SPEC §9.8, таблицы по весу тела/полу/
    ///   опыту) не вычисляется здесь: нужны данные профиля/контента, которых
    ///   у FitCore нет. Вместо этого первая же сессия с фактическим весом
    ///   (калибровочная или нет) становится начальным `baselineKg` —
    ///   таблицы применяются выше по стеку, до того как первый подход вообще
    ///   попадает в журнал.
    public static func rebuildStates(
        from sessions: [ExerciseSession],
        baseRange: ClosedRange<Int>,
        ladder: WeightLadder
    ) -> ExerciseState {
        // Упражнения без веса (`LoadType.bodyweight`/`.band`, `ladder == .none`)
        // прогрессируют только повторами/подходами: `baseline_kg` в схеме для
        // них nullable и остаётся nil навсегда (SPEC §3.1). `baseline`
        // ниже — 0 исключительно как нейтральное значение для арифметики
        // `planProgression`, которая с `ladder == .none` в него никогда не
        // делит (`nextAchievableWeight(.none)` всегда nil); реального веса
        // это число не означает и в `state.baselineKg` не попадает.
        let isWeighted = ladder != .none

        var state = ExerciseState()
        var consecutiveHeldSessions = 0
        var previousSessionUnderRepMin = false
        var consecutiveCalibrationExitSets = 0
        var extraSetsAdded = 0

        for session in sessions {
            guard !session.sets.isEmpty else { continue }

            if isWeighted, let lastDay = state.lastPerformedAt, let baseline = state.baselineKg {
                let gap = lastDay.days(until: session.performedAt)
                switch detrainingAdjustment(daysSinceLastPerformed: gap) {
                case .none:
                    break
                case .mildDecay:
                    state.baselineKg = baseline * 0.92
                case .moderateDecay:
                    state.baselineKg = baseline * 0.85
                    state.repExtension = 0
                case .restartCalibration:
                    state.baselineKg = baseline * 0.75
                    state.isInCalibration = true
                    // Без сброса счётчик выхода из калибровки, накопленный
                    // ДО перерыва, тут же вытолкнул бы состояние обратно из
                    // только что установленной калибровки в этой же сессии.
                    consecutiveCalibrationExitSets = 0
                }
            }
            state.lastPerformedAt = session.performedAt

            if state.isInCalibration {
                for set in session.sets {
                    let inRange = baseRange.contains(set.actualReps)
                    if inRange, set.feedback == .ok || set.feedback == .hard {
                        consecutiveCalibrationExitSets += 1
                        if consecutiveCalibrationExitSets >= 2 {
                            state.isInCalibration = false
                        }
                    } else {
                        consecutiveCalibrationExitSets = 0
                    }
                }
            }

            if isWeighted, state.baselineKg == nil {
                // Первая сессия в журнале вообще: неоткуда взять предыдущий
                // baseline для сравнения — сама сессия его и задаёт.
                state.baselineKg = session.sets.last?.actualKg
                continue
            }
            let baseline = state.baselineKg ?? 0

            if session.isCalibration { continue }

            let effectiveUpper = baseRange.upperBound + state.repExtension
            let reps = session.sets.map(\.actualReps)
            let feedbacks = session.sets.map(\.feedback)
            let failedCount = feedbacks.filter { $0 == .failed }.count
            let anyUnderRepMin = reps.contains { $0 < baseRange.lowerBound }
            let allAtTop = reps.allSatisfy { $0 >= effectiveUpper }
            let anyEasyOrOk = feedbacks.contains(.easy) || feedbacks.contains(.ok)
            let readiness = session.readiness
            let refWeight = session.sets.last?.actualKg ?? baseline
            // См. «вторая несостыковка» в шапке файла: явное снижение веса
            // пользователем, подтверждённое hard/failed в той же сессии,
            // само по себе триггерит понижение — не дожидаясь второй сессии
            // подряд с недобором.
            let overrideStruggle = isWeighted
                && refWeight < baseline - centEpsilonKg
                && (failedCount >= 1 || feedbacks.contains(.hard))

            if failedCount >= 2 || (previousSessionUnderRepMin && anyUnderRepMin) || overrideStruggle {
                if isWeighted {
                    let target = lowerTarget(baseline: baseline, referenceWeight: refWeight, ladder: ladder)
                    state.baselineKg = BaselineUpdater.apply(baseline: baseline, target: target, readiness: readiness)
                }
                state.repExtension = 0
                state.stallCount = 0
                consecutiveHeldSessions = 0
            } else if allAtTop && failedCount == 0 && anyEasyOrOk {
                if isWeighted, refWeight > baseline + centEpsilonKg {
                    // Пользователь уже поднял вес тяжелее прописанного и
                    // справился — это факт, а не гипотетическая рекомендация,
                    // поэтому проверка «прыжок ≤10%» (SPEC §9.5) здесь не
                    // применяется (см. несостыковку в шапке файла).
                    let target = ladder.roundToAchievable(refWeight, direction: .up)
                    state.baselineKg = BaselineUpdater.apply(baseline: baseline, target: target, readiness: readiness)
                    state.repExtension = 0
                } else {
                    switch planProgression(
                        baselineKg: baseline,
                        baseRange: baseRange,
                        repExtension: state.repExtension,
                        extraSetsAdded: extraSetsAdded,
                        ladder: ladder
                    ) {
                    case .extendReps:
                        state.repExtension = min(state.repExtension + 2, 4)
                    case .increaseWeight(let next), .increaseWeightWithRepReset(let next, _):
                        if isWeighted {
                            state.baselineKg = BaselineUpdater.apply(baseline: baseline, target: next, readiness: readiness)
                        }
                        state.repExtension = 0
                    case .addSet:
                        extraSetsAdded += 1
                    case .suggestHarderVariant, .maintain:
                        break
                    }
                }
                state.stallCount = 0
                consecutiveHeldSessions = 0
            } else {
                consecutiveHeldSessions += 1
                if consecutiveHeldSessions == 3 {
                    state.stallCount += 1
                    consecutiveHeldSessions = 0
                    if state.stallCount == 1 {
                        if isWeighted {
                            state.baselineKg = baseline * 0.90
                        }
                        state.repExtension = 0
                    }
                    // stallCount == 2: предложение замены упражнения — сигнал
                    // наружу (Planner читает stallCount), самого предложения
                    // ExerciseState не хранит.
                }
            }

            previousSessionUnderRepMin = anyUnderRepMin
        }

        return state
    }

    /// Цель понижения базовой линии (SPEC §9.4, с поправкой на фактически
    /// использованный вес — см. несостыковку в шапке файла).
    private static func lowerTarget(baseline: Double, referenceWeight: Double, ladder: WeightLadder) -> Double {
        if referenceWeight < baseline - centEpsilonKg {
            // Пользователь уже сам снизил вес — это и есть новая нижняя
            // граница; ещё один шаг вниз поверх нее был бы двойным штрафом
            // (SPEC §18, сценарий 11).
            return ladder.roundToAchievable(referenceWeight, direction: .down)
        }
        return ladder.previousAchievableWeight(below: baseline) ?? baseline
    }
}
