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
//      не с `baseline_kg`, И ДОПОЛНИТЕЛЬНО обязан лежать по правильную
//      сторону от baseline — см. `effectiveOverride`.
//
//  Ни одна ветка здесь не присваивает `baselineKg` напрямую: они возвращают
//  `BaselineMove`, который проверяет и применяет `BaselineMove.apply`
//  (BaselineMove.swift). Присваиваний `state.baselineKg =` в этом файле
//  ровно одно — сидирование, то есть инициализация, а не сдвиг. Это
//  структурная защита от четвёртого раунда одного и того же дефекта:
//  правило направления живёт в одном месте, а не переписывается в каждой
//  ветке заново.
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
//  понижения — открывающий подход взят легче предписанного И легче baseline,
//  И он же получил 'hard'/'failed'.
extension Progression {

    /// Что сессия дала прогрессии — вход для учёта застоя (SPEC §9.4: три
    /// сессии подряд «без повышения»).
    private enum SessionOutcome {
        /// Вес вырос — по оверрайду пользователя или по шагу лестницы.
        case weightIncrease
        /// Тяжелее на лестнице ничего нет: рост идёт повторами и подходами по
        /// каскаду §9.5. Это прогресс, а не застой.
        case ladderCeiling
        /// Повышения не было, хотя лестница жива: либо удержание, либо
        /// вынужденное расширение повторов из-за слишком большого шага.
        case noIncrease
        /// Сессия закончилась понижением — §9.4 обнуляет счётчик застоя явно.
        case lowered
    }

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
        rebuildStatesWithDiagnostics(from: sessions, baseRange: baseRange, ladder: ladder).state
    }

    /// Тот же расчёт, но с диагностикой нарушений инварианта направления.
    /// Не `public`: пока единственный потребитель — тесты (через `@testable`),
    /// которые свипом утверждают, что на всём корпусе сценариев аномалий
    /// ноль. Станет публичным, когда у FitData появится, куда их писать.
    static func rebuildStatesWithDiagnostics(
        from sessions: [ExerciseSession],
        baseRange: ClosedRange<Int>,
        ladder: WeightLadder
    ) -> (state: ExerciseState, anomalies: [BaselineAnomaly]) {
        // Упражнения без веса (`LoadType.bodyweight`/`.band`, `ladder == .none`)
        // прогрессируют только повторами/подходами: `baseline_kg` в схеме для
        // них nullable и остаётся nil навсегда (SPEC §3.1). `baseline`
        // ниже — 0 исключительно как нейтральное значение для арифметики
        // `planProgression`, которая с `ladder == .none` в него никогда не
        // делит (`nextAchievableWeight(.none)` всегда nil); реального веса
        // это число не означает и в `state.baselineKg` не попадает.
        let isWeighted = ladder != .none

        var state = ExerciseState()
        var anomalies: [BaselineAnomaly] = []
        var consecutiveHeldSessions = 0
        var previousSessionUnderRepMin = false
        var consecutiveCalibrationExitSets = 0
        // Потолок длительности калибровки (условие 3 из §9.8-цикла ниже).
        var calibrationSessions = 0
        // Максимум базовой линии за всю историю. Нужен, чтобы отличить рост
        // от отыгрыша: возврат на вес, который уже был, повышением по смыслу
        // §9.4 не является. Не персистится — свёртка пересчитывает его с нуля
        // вместе со всем остальным.
        var maxBaselineReached = 0.0
        // TODO(код-ревью feature/progression, 2026-09-07): этот счётчик
        // никуда не выходит из свёртки. `ExerciseState` его не хранит (в
        // схеме нет колонки: количество подходов — это
        // `workout_exercises.target_sets`, владелец — Planner), а обе ветки
        // каскада, которые он различает (`.addSet` и `.suggestHarderVariant`),
        // состояние не меняют. Следствие: шаг 2 каскада §9.5 из результата
        // rebuildStates невосстановим, и покрыть его тестом через публичный
        // API нельзя. Сброс ниже поэтому корректен, но пока не наблюдаем.
        // Зафиксировано как открытый вопрос SPEC §19.2 — решать вместе с
        // Planner, который владеет target_sets.
        var extraSetsAdded = 0

        /// Применить намерение через единственную точку схождения и запомнить
        /// аномалию, если инвариант нарушен.
        func move(_ intent: BaselineMove, openingWeight: Double?, readiness: Double) {
            if let anomaly = BaselineMove.apply(
                intent, to: &state.baselineKg, openingWeight: openingWeight, readiness: readiness
            ) {
                anomalies.append(anomaly)
            }
        }

        for session in sessions {
            // Пустая сессия — артефакт данных (тренировка начата, подходы не
            // записаны), а не тренировка. Она остаётся полностью невидимой:
            // не двигает ни счётчик детренированности (guard стоит раньше
            // присваивания lastPerformedAt), ни счётчики смежности ниже.
            guard let firstSet = session.sets.first else { continue }

            var cutThisSession = false
            if isWeighted, let lastDay = state.lastPerformedAt, let baseline = state.baselineKg {
                let gap = lastDay.days(until: session.performedAt)
                let decay = detrainingAdjustment(daysSinceLastPerformed: gap)
                switch decay {
                case .none:
                    break
                case .mildDecay:
                    move(.lower(to: baseline * 0.92, reason: .detraining),
                         openingWeight: firstSet.actualKg, readiness: session.readiness)
                case .moderateDecay:
                    move(.lower(to: baseline * 0.85, reason: .detraining),
                         openingWeight: firstSet.actualKg, readiness: session.readiness)
                    state.repExtension = 0
                case .restartCalibration:
                    move(.lower(to: baseline * 0.75, reason: .detraining),
                         openingWeight: firstSet.actualKg, readiness: session.readiness)
                    state.isInCalibration = true
                    // Срез обязан пережить свою собственную сессию. Она уже
                    // помечена калибровочной (строкой выше), и без этого флага
                    // её же данные — где пользователь мог взять старый вес
                    // сама — тут же усваиваются калибровкой и ×0.75
                    // отменяется в тот же момент. Тогда §9.7 перестаёт быть
                    // гарантией «начнём чуть легче» и становится подсказкой.
                    // Калибровка начинается со следующей сессии.
                    cutThisSession = true
                    // Полный рестарт — надмножество .moderateDecay и не может
                    // сохранять БОЛЬШЕ накопленного состояния, чем более
                    // короткий перерыв.
                    state.repExtension = 0
                    state.stallCount = 0
                }
                if decay != .none {
                    // «Два подхода подряд» (SPEC §9.8) не может охватывать
                    // перерыв в 11+ дней: подход до перерыва и подход после
                    // него — не подряд.
                    consecutiveCalibrationExitSets = 0
                }
            }
            state.lastPerformedAt = session.performedAt

            // Режим снимается ДО скана выхода и до условий завершения ниже:
            // «условие выхода выполнено» означает «калибровка кончается ПОСЛЕ
            // этой сессии», а не «эта сессия не была калибровочной». Без
            // снимка сессия, которая выход и вызвала, уходила по обычному
            // пути и теряла своё калибровочное обновление — базовая линия
            // застревала на предыдущей ступени, потому что §9.5 шаг больше
            // 10% не пропускает. Код-ревью многосессионного прогона,
            // 2026-09-08.
            let inCalibrationRegime = state.isInCalibration

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

            // Сидирование расщеплено на присвоение baseline (здесь) и политику
            // счётчиков смежности (ниже). Раньше они были слиты в одной ветке
            // с `continue`, и первая сессия — которая по §9.8 почти всегда И
            // калибровочная — получала политику сидирования, молча минуя
            // политику калибровки. Код-ревью 3b92caa, 2026-09-07.
            //
            // Признак считается ДО попытки присвоения и покрывает оба её
            // исхода одинаково: сессия, начавшаяся без базовой линии, не может
            // дать ни повышения, ни понижения независимо от того, оставила ли
            // она baseline после себя.
            let hadNoBaseline = isWeighted && state.baselineKg == nil
            // Условие 2 завершения калибровки: тяжелее ничего нет, искать
            // больше нечего. Без него женщина на максимальной гантели с 20
            // лёгкими повторами не выходила бы из режима никогда (условие §9.8
            // требует попадания в диапазон, а она его перевыполняет) и не
            // попадала бы в каскад §9.5 — то есть §18 сценарии 3 и 4 ломались
            // бы. Проверяется до присвоения ниже: у сидирующей сессии базовой
            // линии ещё нет, и условие к ней неприменимо.
            if state.isInCalibration, isWeighted, let current = state.baselineKg,
               ladder.nextAchievableWeight(above: current) == nil {
                state.isInCalibration = false
            }

            if hadNoBaseline {
                // Единственное присвоение baselineKg в этом файле: это
                // инициализация, а не сдвиг, поэтому оно не идёт через
                // BaselineMove (двигать ещё нечего).
                //
                // Источник — establishedWeight, тот же, что у калибровочного
                // обновления ниже: вопрос «какой рабочий вес установила эта
                // сессия» у сидирования и у калибровки один и тот же, и
                // отвечать на него двумя разными способами незачем.
                state.baselineKg = establishedWeight(session, baseRange: baseRange)
            }

            // Режим калибровки определяется ТОЛЬКО состоянием.
            // `exercise_states.in_calibration` (SPEC §3.1) — источник истины, и
            // его вычисляет эта свёртка; `workouts.is_calibration` остаётся
            // флагом для UI и аналитики, но режимом не управляет. Контракт для
            // приложения: помечать тренировку калибровочной по состоянию, а не
            // считать тренировки.
            //
            // Почему не `session.isCalibration || state.isInCalibration`: тогда
            // приложение, продолжающее слать флаг, держит режим открытым вечно
            // и отменяет условия завершения ниже — упражнение на исчерпанной
            // лестнице так и не попадает в каскад §9.5.
            // Код-ревью многосессионного прогона, 2026-09-08.
            if inCalibrationRegime {
                calibrationSessions += 1
                // Калибровочная сессия — другой режим (§9.8: шаг ±15%, до 3
                // повышений за сессию). Нельзя утверждать «две сессии подряд
                // с недобором» или «три сессии без прогресса», когда одна из
                // них — подбор веса, поэтому калибровочная сессия ОБРЫВАЕТ
                // оба прогона. Сброс консервативен: он откладывает понижение
                // и deload, а не вызывает их ложно.
                //
                // Проверяется РАНЬШЕ сидирования: при совпадении (первая
                // сессия и есть калибровочная) утверждение о режиме сессии
                // сильнее утверждения о том, что она первая.
                //
                // Асимметрия с lastPerformedAt выше намеренная: мышца
                // работала, поэтому счётчик детренированности сбросить
                // правильно, а счётчики смежности — нет.
                //
                // Но базовую линию калибровочная сессия ОБНОВЛЯЕТ — ради этого
                // она и существует (§9.8: «Намеренное занижение: безопасно, и
                // алгоритм быстро поднимет»). Раньше здесь стоял чистый
                // continue, и найденный калибровкой вес выбрасывался: каждая
                // сессия открывала с той же базовой линии, доходила до
                // рабочего веса и не оставляла следа — калибровка не сходилась
                // никогда. §9.8 исключает калибровочные подходы из МОДЕЛИ
                // УТОМЛЕНИЯ и НЕДЕЛЬНОГО ОБЪЁМА, а не из обновления базовой
                // линии; это исключение было прочитано слишком широко.
                // Код-ревью 433afa0, 2026-09-08.
                if isWeighted, !hadNoBaseline, !cutThisSession,
                   let established = establishedWeight(session, baseRange: baseRange),
                   let current = state.baselineKg {
                    let target = calibrationTarget(
                        session, established: established,
                        effectiveUpper: baseRange.upperBound + state.repExtension, ladder: ladder
                    )
                    let intent: BaselineMove =
                        target > current + centEpsilonKg ? .raise(to: target, reason: .calibration)
                      : target < current - centEpsilonKg ? .lower(to: target, reason: .calibration)
                      : .hold
                    move(intent, openingWeight: firstSet.actualKg, readiness: session.readiness)
                }
                // hadNoBaseline пропускается намеренно: сидирование выше уже
                // записало ровно это значение, и повторный ход дал бы
                // target == baseline, то есть ложную аномалию.

                // Условие 3 завершения: потолок длительности. §9.8 говорит
                // «первые 2–3 тренировки»; шесть — вдвое больше ориентира, то
                // есть спека соблюдена, а залипание на странных данных
                // исключено.
                if calibrationSessions >= 6 {
                    state.isInCalibration = false
                }
                previousSessionUnderRepMin = false
                consecutiveHeldSessions = 0
                continue
            }

            if hadNoBaseline {
                // Сессия — настоящая тренировка, и недобор по повторам
                // определён относительно baseRange без всякого baseline.
                // Флаг смежности присваивается, иначе у пользователя, чьи
                // первые две сессии обе провалились по повторам, понижение
                // не сработает никогда.
                previousSessionUnderRepMin = anyUnderRepMin
                // А consecutiveHeldSessions не трогаем: «сессия без
                // повышения» для неё бессмысленна — базовой линии на входе
                // не было, повышаться было не от чего.
                //
                // Выход здесь обязателен и когда сидирование НЕ удалось (у
                // последнего подхода нет actual_kg — колонка nullable):
                // иначе управление доходит до `?? 0` ниже, planProgression
                // считает jump = (next − 0) / 0 = inf, и каскад молча
                // возвращает extendReps, наращивая rep_extension упражнению
                // без базовой линии. Код-ревью e1a7ee7, 2026-09-08.
                continue
            }
            // Для взвешенных упражнений baselineKg здесь гарантированно не nil
            // (иначе сработал бы выход выше), поэтому `?? 0` остаётся только
            // для ladder == .none, ради которого он и написан: там 0 —
            // нейтральное значение, а не подмена несуществующего веса.
            let baseline = state.baselineKg ?? 0

            let effectiveUpper = baseRange.upperBound + state.repExtension
            let feedbacks = session.sets.map(\.feedback)
            let failedCount = feedbacks.filter { $0 == .failed }.count
            let allAtTop = reps.allSatisfy { $0 >= effectiveUpper }
            let anyEasyOrOk = feedbacks.contains(.easy) || feedbacks.contains(.ok)
            let readiness = session.readiness

            // Опорный вес — вес ОТКРЫВАЮЩЕГО подхода (см. правило 1 в шапке).
            let refWeight = firstSet.actualKg ?? baseline
            let override = effectiveOverride(firstSet, baseline: isWeighted ? baseline : nil)
            // Третий, не описанный в SPEC триггер понижения: открывающий
            // подход взят легче предписанного (и легче baseline — это уже
            // внутри effectiveOverride) И он же получил 'hard'/'failed'.
            let openedLighterAndStruggled = override == .down
                && (firstSet.feedback == .hard || firstSet.feedback == .failed)

            // Тяжелее на лестнице ничего нет: и .extendReps, и .addSet, и
            // .suggestHarderVariant в этом состоянии означают следование
            // каскаду §9.5, а не застой.
            let ladderCeiling = ladder.nextAchievableWeight(above: baseline) == nil
            var outcome: SessionOutcome

            if failedCount >= 2 || (previousSessionUnderRepMin && anyUnderRepMin) || openedLighterAndStruggled {
                if isWeighted {
                    // Решение «снизил ли вес ПОЛЬЗОВАТЕЛЬ» приходит сюда уже
                    // принятым (effectiveOverride) и внутри lowerTarget не
                    // переоткрывается: сырое сравнение refWeight с baseline
                    // истинно и тогда, когда вес срезала ГОТОВНОСТЬ, а
                    // пользователь предписание просто принял, — и день с
                    // низкой готовностью наказывал базовую линию сильнее,
                    // чем день на полном весе. Код-ревью e1a7ee7, 2026-09-08.
                    if let target = lowerTarget(
                        baseline: baseline,
                        userLoweredTo: override == .down ? refWeight : nil,
                        ladder: ladder
                    ) {
                        move(.lower(to: target, reason: override == .down ? .userOverride : .ladderStep),
                             openingWeight: firstSet.actualKg, readiness: readiness)
                    }
                    // nil — понижать некуда (лестница исчерпана снизу). Это
                    // законная ситуация, а не аномалия: базовая линия просто
                    // остаётся на месте.
                }
                state.repExtension = 0
                outcome = .lowered
            } else if allAtTop && failedCount == 0 && anyEasyOrOk {
                var raisedWeight = false

                if isWeighted, override == .up,
                   let target = raiseTarget(baseline: baseline, userRaisedTo: refWeight, ladder: ladder) {
                    // Пользователь сам взял вес тяжелее предписанного и своей
                    // базовой линии и справился — это факт, а не гипотеза,
                    // поэтому проверка «прыжок ≤ 10%» (SPEC §9.5) не
                    // применяется.
                    let before = state.baselineKg
                    move(.raise(to: target, reason: .userOverride),
                         openingWeight: firstSet.actualKg, readiness: readiness)
                    if state.baselineKg != before {
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
                            let before = state.baselineKg
                            move(.raise(to: next, reason: .ladderStep),
                                 openingWeight: firstSet.actualKg, readiness: readiness)
                            raisedWeight = state.baselineKg != before
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
                    // и было взято, компенсация возвращается. На понижении
                    // счётчик не трогаем — срезать одновременно и вес, и
                    // объём было бы двойным штрафом.
                    extraSetsAdded = 0
                }

                // Классификация исхода, а не сброс счётчиков на месте: §9.4
                // считает застоем три сессии «без ПОВЫШЕНИЯ», а расширение
                // повторов вес не двигает. Различить «расширяем повторы, потому
                // что лестница кончилась» (§9.5 шаг 1, это прогресс) и
                // «расширяем, потому что следующая ступень дороже 10%» по
                // самому WeightDecision нельзя — обе ветки возвращают
                // .extendReps, — поэтому исчерпанность спрашивается у лестницы.
                outcome = raisedWeight ? .weightIncrease
                        : (ladderCeiling ? .ladderCeiling : .noIncrease)
            } else {
                outcome = .noIncrease
            }

            // Единственная точка учёта застоя: ветки выше объявляют исход, а
            // счётчики двигаются здесь. Раньше сброс стоял в конце ветки
            // повышения вне switch и срабатывал на любом исходе каскада —
            // из-за чего .extendReps засчитывался как прогресс, stallCount
            // никогда не доходил до 2, «предложить замену упражнения» (§9.4)
            // было недостижимо, а deload повторялся бесконечно: базовая линия
            // безупречно выполняющей женщины шла 10 → 9 → 8.1 → 7.29 → 6.5 за
            // 30 сессий. Код-ревью многосессионного прогона, 2026-09-08.
            switch outcome {
            case .weightIncrease where !((state.baselineKg ?? 0) > maxBaselineReached + centEpsilonKg):
                // Вес вырос, но не превзошёл ранее достигнутый максимум: это
                // отыгрыш после deload, а не прогресс. Прогон одноподходного
                // упражнения показал вечный цикл: deload 10 → 9, затем два
                // расширения повторов и increaseWeightWithRepReset обратно на
                // 10, что сбрасывало stallCount — и через три сессии снова
                // deload. Счётчик не доходил до 2 никогда, то есть замена
                // упражнения (§9.4) так и не предлагалась, хотя женщина
                // объективно стоит на месте.
                //
                // Прогон сессий засчитывается (она отработала), а счётчик
                // ЭПИЗОДОВ застоя — нет.
                consecutiveHeldSessions = 0
            case .lowered, .weightIncrease, .ladderCeiling:
                // Понижение сбрасывает счётчик по букве §9.4. Исчерпанная
                // лестница — потому что deload на 10% не решает ничего для
                // той, кто упёрлась в потолок инвентаря и растёт повторами и
                // подходами ровно так, как предписывает §9.5: у него там своя
                // эскалация (повторы → подходы → сложный вариант → «на
                // поддержании»).
                state.stallCount = 0
                consecutiveHeldSessions = 0
            case .noIncrease:
                consecutiveHeldSessions += 1
                if consecutiveHeldSessions == 3 {
                    state.stallCount += 1
                    consecutiveHeldSessions = 0
                    if state.stallCount == 1 {
                        if isWeighted {
                            move(.lower(to: baseline * 0.90, reason: .stallDeload),
                                 openingWeight: firstSet.actualKg, readiness: readiness)
                        }
                        state.repExtension = 0
                    }
                    // stallCount == 2: предложение замены упражнения — сигнал
                    // наружу (Planner читает stallCount), самого предложения
                    // ExerciseState не хранит.
                }
            }

            if let b = state.baselineKg { maxBaselineReached = max(maxBaselineReached, b) }
            previousSessionUnderRepMin = anyUnderRepMin
        }

        return (state, anomalies)
    }

    /// Куда калибровочная сессия двигает базовую линию.
    ///
    /// Обычно это `established` — самый тяжёлый выполненный вес. Но если
    /// сессия закончилась «легко» на верху диапазона, значит подъём §9.3 не
    /// завершился — просто кончились подходы, — и следующая сессия обязана
    /// открыться выше, иначе калибровка не сходится вовсе. Ярче всего это на
    /// одноподходном упражнении: внутри сессии подъёма нет ни одного, и без
    /// межсессионного шага базовая линия навсегда остаётся на холодном старте
    /// (проверено прогоном на 12 сессий).
    ///
    /// Шаг тот же, что §9.3 делает внутри сессии в калибровке: +15% с
    /// округлением вверх до достижимого. Перелёта это не создаёт — следующая
    /// сессия немедленно даёт фидбэк на первом же подходе, а
    /// `establishedWeight` провальный вес не усваивает.
    /// Код-ревью многосессионного прогона, 2026-09-08.
    private static func calibrationTarget(
        _ session: ExerciseSession, established: Double,
        effectiveUpper: Int, ladder: WeightLadder
    ) -> Double {
        let climbUnfinished = session.sets.last.map {
            $0.feedback == .easy && $0.actualReps >= effectiveUpper
        } ?? false
        guard climbUnfinished else { return established }
        let stepped = ladder.roundToAchievable(established * 1.15, direction: .up)
        // roundToAchievable(.up) клэмпит к максимуму лестницы, поэтому на
        // исчерпанной лестнице шаг сам собой выродится в established.
        return stepped > established + centEpsilonKg ? stepped : established
    }

    /// Рабочий вес, который установила сессия: самый тяжёлый подход,
    /// выполненный НЕ на `failed` и с повторами не ниже `rep_min`.
    ///
    /// Почему максимум, а не закрывающий вес: §9.3 поднимает вес, пока не
    /// станет тяжело, поэтому калибровочная сессия по устройству заканчивается
    /// перелётом — последний подход это, как правило, тот, на котором она
    /// провалилась. Брать его значит начинать следующую тренировку с веса,
    /// который она только что не вытянула, вопреки «Намеренное занижение:
    /// безопасно» (§9.8).
    ///
    /// Почему не «последний записанный при обратном обходе»: это тот же
    /// закрывающий вес и та же проблема. Обход по всем подходам нужен, чтобы
    /// пустой закрывающий подход не терял сессию целиком, — и он здесь есть,
    /// но с отсечкой провала и недобора.
    ///
    /// `nil` — сессия ничего не установила: весов нет, либо все подходы
    /// провалены или недобраны по повторам.
    private static func establishedWeight(_ session: ExerciseSession, baseRange: ClosedRange<Int>) -> Double? {
        session.sets
            .filter { $0.feedback != .failed && $0.actualReps >= baseRange.lowerBound }
            .compactMap(\.actualKg)
            .max()
    }

    /// Направление, в котором пользователь **осмысленно** отклонился от
    /// предписания на открывающем подходе: не только относительно
    /// `prescribed_kg`, но и относительно базовой линии.
    ///
    /// Второе условие — не перестраховка, а суть. Предписанный вес это
    /// `baseline × readiness` (§9.6), и readiness доходит до 1.10 (§10),
    /// поэтому предписание бывает ВЫШЕ базовой линии. Отказ от такой
    /// надбавки (взяла меньше предписанного, но не меньше своей базовой
    /// линии) — это не заявление «мне тяжело на моём рабочем весе», и читать
    /// его как сигнал снизить базовую линию значит позволить дневной
    /// готовности портить долгосрочную — ровно то, что §9.6 запрещает.
    /// Симметрично вверх: принятая надбавка не есть оверрайд.
    ///
    /// Обе ветки свёртки читают результат этой функции; отдельных условий
    /// «и ещё сравнить с baseline» в ветках нет и быть не должно — три
    /// раунда ревью подряд ловили именно рассредоточенные проверки.
    /// Код-ревью 3b92caa, 2026-09-07.
    ///
    /// `baseline` = nil — упражнение без веса: оверрайда нет по определению.
    private static func effectiveOverride(_ set: SetResult, baseline: Double?) -> RoundDirection? {
        guard let baseline,
              let prescribed = set.prescribedKg,
              let actual = set.actualKg
        else { return nil }

        if actual > prescribed + centEpsilonKg && actual > baseline + centEpsilonKg { return .up }
        if actual < prescribed - centEpsilonKg && actual < baseline - centEpsilonKg { return .down }
        return nil
    }

    /// Цель повышения базовой линии по фактически взятому весу.
    ///
    /// `nil` — повышать некуда: `roundToAchievable(_, .up)` клэмпит ВНИЗ к
    /// максимуму лестницы, когда запрошенный вес выше него, а базовая линия
    /// лестницей не ограничена (сидируется из пользовательского `actual_kg`,
    /// например с тренировки на чужом инвентаре). Ситуация законная — на
    /// домашней лестнице просто нет ступени выше — поэтому она отсекается
    /// здесь и НЕ доходит до инварианта: тот сигнализирует о дефекте, а не о
    /// нормальном исчерпании лестницы. Ровно так же устроен `lowerTarget`.
    /// Код-ревью 3b92caa, 2026-09-07.
    private static func raiseTarget(baseline: Double, userRaisedTo: Double, ladder: WeightLadder) -> Double? {
        let target = ladder.roundToAchievable(userRaisedTo, direction: .up)
        return target > baseline + centEpsilonKg ? target : nil
    }

    /// Цель понижения базовой линии (SPEC §9.4, с поправкой на фактически
    /// использованный вес — см. несостыковку в шапке файла).
    ///
    /// `nil` — понижать некуда: лестница исчерпана снизу либо результат
    /// округления оказался не ниже базовой линии. Возвращать в этом случае
    /// клэмп к минимуму лестницы нельзя — `roundToAchievable(_, .down)`
    /// округляет ВВЕРХ, когда значение ниже первой ступени, и ветка понижения
    /// поднимала базовую линию (3 → 4 на лестнице [4,6,8]). Инвариант в
    /// BaselineMove это тоже отсечёт, но здесь ситуация законная, а не
    /// аномальная: ниже просто нет ступеней, и засорять ею диагностику
    /// незачем. Код-ревью 3b92caa, 2026-09-07.
    private static func lowerTarget(baseline: Double, userLoweredTo: Double?, ladder: WeightLadder) -> Double? {
        let target: Double
        if let userWeight = userLoweredTo {
            // Пользователь уже сам снизил вес — это и есть новая нижняя
            // граница; ещё один шаг вниз поверх неё был бы двойным штрафом
            // (SPEC §18, сценарий 11).
            target = ladder.roundToAchievable(userWeight, direction: .down)
        } else {
            guard let step = ladder.previousAchievableWeight(below: baseline) else { return nil }
            target = step
        }
        return target < baseline - centEpsilonKg ? target : nil
    }
}
