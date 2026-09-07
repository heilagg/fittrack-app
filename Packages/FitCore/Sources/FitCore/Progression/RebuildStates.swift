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
//  Ключевой принцип, восстановленный после код-ревью feature/progression
//  (2026-09-07): свёртка реагирует на решения ПОЛЬЗОВАТЕЛЯ, а не на
//  собственные внутрисессионные корректировки. Отсюда два правила, которые
//  легко нарушить обратно:
//   1. Опорный вес берётся из ОТКРЫВАЮЩЕГО подхода сессии. Последний подход
//      несёт то, что назначила §9.3, а она понижает вес ровно на
//      'failed'/'hard' — на нём признак «пользователь снизил вес»
//      выполнялся сам собой, и одна сессия с одним 'failed' роняла baseline
//      вопреки §9.4 («один плохой день не откатывает вес»).
//   2. Оверрайд определяется сравнением с ПРЕДПИСАНИЕМ (`prescribed_kg`), а
//      не с `baseline_kg`. Предписание — это `baseline × readiness` (§9.6),
//      поэтому сравнение с baseline читает принятое как есть предписание как
//      оверрайд на всяком дне с readiness ≠ 1.0, причём в обе стороны:
//      вниз оно ложно понижало базовую линию на readiness 0.8, вверх —
//      ложно поднимало её до раздутого готовностью веса на readiness 1.10.
//      И то и другое — ровно то, что §9.6 запрещает.
//
//  Несостыковка со SPEC (задокументировано в теле коммита, не в SPEC.md):
//  §9.4/§9.5 описывают шаг веса как ступень лестницы ОТ baseline_kg, но
//  §18 сценарии 10–11 требуют учитывать вес, который пользователь ФАКТИЧЕСКИ
//  ввёл. Решение: если открывающий подход сессии отличается от предписанного
//  веса, его фактический вес становится опорной точкой для вычисления цели
//  (округлённой к достижимой ступени в нужную сторону) вместо ступени
//  лестницы от старого baseline — иначе понижение задним числом наказывало
//  бы дважды (шаг вниз ПОВЕРХ уже сниженного пользователем веса), а
//  повышение игнорировало бы уже подтверждённый более тяжёлый вес.
//
//  Вторая несостыковка, из той же пары сценариев: §9.4 перечисляет понижение
//  только по двум признакам («две сессии подряд с недобором» или «одна сессия
//  с двумя failed») — ни один из них не срабатывает на сценарии 11 (одна
//  сессия, один 'hard', повторы в диапазоне, но вес уже снижен
//  пользователем). Решение: добавлен третий, не описанный в SPEC триггер
//  понижения — открывающий подход взят легче предписанного И он же получил
//  'hard'/'failed'. Оба признака читаются с одного и того же подхода,
//  потому что сценарий 11 описывает одно событие, а не два.
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
        // TODO(код-ревью feature/progression, 2026-09-07): этот счётчик
        // никуда не выходит из свёртки. `ExerciseState` его не хранит (в
        // схеме нет колонки: количество подходов — это
        // `workout_exercises.target_sets`, владелец — Planner), а обе ветки
        // каскада, которые он различает (`.addSet` и `.suggestHarderVariant`),
        // состояние не меняют. Следствие: на исчерпанной лестнице с
        // repExtension = 4 свёртка возвращает одно и то же состояние
        // независимо от его значения — то есть шаг 2 каскада §9.5
        // («затем добавляем подход») из результата rebuildStates
        // невосстановим, и покрыть его тестом через публичный API нельзя.
        // Сброс ниже поэтому корректен, но пока не наблюдаем. Чинится либо
        // выносом счётчика в ExerciseState, либо передачей его снаружи
        // (Planner как владелец target_sets) — решение за модулем Planner.
        var extraSetsAdded = 0

        for session in sessions {
            // Пустая сессия — артефакт данных (тренировка начата, подходы не
            // записаны), а не тренировка. Она остаётся полностью невидимой:
            // не двигает ни счётчик детренированности (guard стоит раньше
            // присваивания lastPerformedAt), ни счётчики смежности ниже.
            guard let firstSet = session.sets.first else { continue }

            if isWeighted, let lastDay = state.lastPerformedAt, let baseline = state.baselineKg {
                let gap = lastDay.days(until: session.performedAt)
                let decay = detrainingAdjustment(daysSinceLastPerformed: gap)
                switch decay {
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
                    // Полный рестарт — надмножество .moderateDecay и не может
                    // сохранять БОЛЬШЕ накопленного состояния, чем более
                    // короткий перерыв. Без этих двух строк 60-дневный
                    // перерыв оставлял repExtension нетронутым, требуя больше
                    // повторов, чем 30-дневный, на весе, срезанном на 25%.
                    // Код-ревью feature/progression, 2026-09-07.
                    state.repExtension = 0
                    state.stallCount = 0
                }
                if decay != .none {
                    // «Два подхода подряд» (SPEC §9.8) не может охватывать
                    // перерыв в 11+ дней: подход до перерыва и подход после
                    // него — не подряд. Сброс на любом ненулевом вердикте, а
                    // не только на .restartCalibration.
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

            let reps = session.sets.map(\.actualReps)
            let anyUnderRepMin = reps.contains { $0 < baseRange.lowerBound }

            if isWeighted, state.baselineKg == nil {
                // Первая сессия в журнале вообще: неоткуда взять предыдущий
                // baseline для сравнения — сама сессия его и задаёт.
                //
                // Здесь, в отличие от опорного веса ниже, берётся ПОСЛЕДНИЙ
                // подход, и это намеренно: открывающий вес самой первой
                // сессии — это холодный старт (§9.8, таблица от веса тела
                // × 0.6, заведомо заниженный), а калибровка поднимает вес
                // внутри сессии, поэтому закрывающий подход — более честная
                // оценка рабочего веса, чем открывающий.
                state.baselineKg = session.sets.last?.actualKg
                // Сидирующая сессия — настоящая тренировка, и недобор по
                // повторам определён относительно baseRange без всякого
                // baseline. Флаг смежности присваивается, иначе у
                // пользователя, чьи первые две сессии обе провалились по
                // повторам, понижение не сработает никогда.
                previousSessionUnderRepMin = anyUnderRepMin
                // А вот consecutiveHeldSessions не трогаем: «сессия без
                // повышения» для неё бессмысленна — baseline только что
                // создан, повышаться было не от чего.
                continue
            }
            let baseline = state.baselineKg ?? 0

            if session.isCalibration {
                // Калибровочная сессия — другой режим (§9.8: шаг ±15%, до 3
                // повышений за сессию). Нельзя утверждать «две сессии подряд
                // с недобором» или «три сессии без прогресса», когда одна из
                // них — подбор веса, поэтому калибровочная сессия ОБРЫВАЕТ
                // оба прогона. Сброс консервативен: он откладывает понижение
                // и deload, а не вызывает их ложно.
                //
                // Асимметрия с lastPerformedAt выше намеренная: мышца
                // работала, поэтому счётчик детренированности сбросить
                // правильно, а счётчики смежности — нет.
                previousSessionUnderRepMin = false
                consecutiveHeldSessions = 0
                continue
            }

            let effectiveUpper = baseRange.upperBound + state.repExtension
            let feedbacks = session.sets.map(\.feedback)
            let failedCount = feedbacks.filter { $0 == .failed }.count
            let allAtTop = reps.allSatisfy { $0 >= effectiveUpper }
            let anyEasyOrOk = feedbacks.contains(.easy) || feedbacks.contains(.ok)
            let readiness = session.readiness

            // Опорный вес — вес ОТКРЫВАЮЩЕГО подхода (см. правило 1 в шапке).
            let refWeight = firstSet.actualKg ?? baseline
            let override = openingOverride(firstSet)
            // Третий, не описанный в SPEC триггер понижения: открывающий
            // подход взят легче предписанного И он же получил 'hard'/'failed'.
            let openedLighterAndStruggled = isWeighted
                && override == .down
                && (firstSet.feedback == .hard || firstSet.feedback == .failed)

            if failedCount >= 2 || (previousSessionUnderRepMin && anyUnderRepMin) || openedLighterAndStruggled {
                if isWeighted {
                    let target = lowerTarget(baseline: baseline, referenceWeight: refWeight, ladder: ladder)
                    state.baselineKg = BaselineUpdater.apply(baseline: baseline, target: target, readiness: readiness)
                }
                state.repExtension = 0
                state.stallCount = 0
                consecutiveHeldSessions = 0
            } else if allAtTop && failedCount == 0 && anyEasyOrOk {
                var raisedWeight = false

                if isWeighted, override == .up {
                    // Пользователь сам взял вес тяжелее предписанного и
                    // справился — это факт, а не гипотетическая рекомендация,
                    // поэтому проверка «прыжок ≤ 10%» (SPEC §9.5) здесь не
                    // применяется.
                    let target = ladder.roundToAchievable(refWeight, direction: .up)
                    // roundToAchievable(.up) КЛЭМПИТ ВНИЗ к максимуму
                    // лестницы, когда запрошенный вес выше него, а baseline
                    // сидируется из пользовательского actual_kg и лестницей
                    // не ограничен. Без этой проверки ветка ПОВЫШЕНИЯ роняла
                    // baseline (20 → 8 на лестнице [4,6,8]). Ветка повышения
                    // не имеет права уменьшать базовую линию ни при каком
                    // входе. Код-ревью feature/progression, 2026-09-07.
                    if target > baseline + centEpsilonKg {
                        state.baselineKg = BaselineUpdater.apply(baseline: baseline, target: target, readiness: readiness)
                        state.repExtension = 0
                        raisedWeight = true
                    }
                }

                if !raisedWeight {
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
                            raisedWeight = true
                        }
                        state.repExtension = 0
                    case .addSet:
                        extraSetsAdded += 1
                    case .suggestHarderVariant, .maintain:
                        break
                    }
                }

                if raisedWeight {
                    // Добавленные подходы — компенсация за «тяжелее нет
                    // вообще» (SPEC §9.5, п. 2). Как только тяжелее появилось
                    // и было взято, компенсация возвращается: иначе +2
                    // подхода остаются навсегда и складываются с повышением
                    // веса. На понижении счётчик не трогаем — срезать
                    // одновременно и вес, и объём было бы двойным штрафом.
                    extraSetsAdded = 0
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

    /// Направление, в котором пользователь изменил предписанный вес
    /// открывающего подхода. `nil` — предписание принято как есть либо
    /// сравнивать не с чем (вес не предписывался или не записан).
    ///
    /// Переиспользует `RoundDirection` из Equipment: это ровно та же пара
    /// «вверх/вниз», заводить второй такой enum незачем.
    private static func openingOverride(_ set: SetResult) -> RoundDirection? {
        guard let prescribed = set.prescribedKg, let actual = set.actualKg else { return nil }
        if actual > prescribed + centEpsilonKg { return .up }
        if actual < prescribed - centEpsilonKg { return .down }
        return nil
    }

    /// Цель понижения базовой линии (SPEC §9.4, с поправкой на фактически
    /// использованный вес — см. несостыковку в шапке файла).
    private static func lowerTarget(baseline: Double, referenceWeight: Double, ladder: WeightLadder) -> Double {
        if referenceWeight < baseline - centEpsilonKg {
            // Пользователь уже сам снизил вес — это и есть новая нижняя
            // граница; ещё один шаг вниз поверх неё был бы двойным штрафом
            // (SPEC §18, сценарий 11).
            return ladder.roundToAchievable(referenceWeight, direction: .down)
        }
        return ladder.previousAchievableWeight(below: baseline) ?? baseline
    }
}
