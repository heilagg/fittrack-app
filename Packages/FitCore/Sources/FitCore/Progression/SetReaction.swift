//  Реакция внутри сессии — следующий подход того же упражнения (SPEC §9.3).
//  Мгновенная: реагирует только на подход, который только что завершился, и
//  ничего не знает о прошлых сессиях (это уже BaselineUpdater).

/// Что делать с упражнением после только что завершённого подхода.
public enum SetOutcome: Sendable, Equatable {
    /// Вес для следующего подхода того же упражнения.
    case nextWeight(Double)
    /// Два `failed` подряд (SPEC §9.3): упражнение завершается досрочно,
    /// оставшиеся подходы помечаются `sets.skipped = true`. Переноса объёма на
    /// следующее упражнение нет (§9.3), поэтому решать здесь нечего ни
    /// Progression, ни Planner: сессия просто заканчивается с меньшим объёмом
    /// на эту мышцу, а `неделя[m]` считает только выполненные подходы (§7.3).
    case terminateExercise
}

public enum Progression {

    /// «Не больше 3 повышений за упражнение в калибровке» (SPEC §9.8).
    public static let maxCalibrationIncreases = 3

    /// Берёт ли этот подход калибровочное повышение — то есть расходует ли он
    /// одну из трёх попыток §9.8.
    ///
    /// Вынесено отдельной функцией, потому что потребителей у правила двое и
    /// разойтись им нельзя: сама `nextSet` и тот, кто ведёт счётчик снаружи —
    /// на вебе это построение дерева §20.9, где счётчик выражен третьей
    /// компонентой состояния узла. Вывести «было ли повышение» сравнением
    /// результата с `current` нельзя: на плотной лестнице ×1.15 может
    /// округлиться обратно в ту же ступень, и попытка, которая по правилу
    /// израсходована, выглядела бы неизрасходованной.
    ///
    /// Считается решение, а не изменение веса, — как `extra_sets_added` в §9.5
    /// считает решение добавить подход, а не факт его выполнения.
    public static func consumesCalibrationIncrease(
        feedback: Feedback,
        actualReps: Int,
        range: ClosedRange<Int>,
        isCalibration: Bool,
        calibrationIncreasesUsed: Int
    ) -> Bool {
        isCalibration
            && feedback == .easy
            && actualReps >= range.upperBound
            && calibrationIncreasesUsed < maxCalibrationIncreases
    }

    /// `priorFeedback` — фидбэк подхода, непосредственно предшествующего
    /// только что завершённому (`nil`, если только что завершённый подход —
    /// первый в упражнении за сессию). Нужен только для проверки «два
    /// failed подряд»; вся остальная реакция зависит исключительно от
    /// последнего подхода (SPEC §9.3 нарочно не использует более глубокую
    /// историю здесь — это работа `BaselineUpdater`).
    ///
    /// `calibrationIncreasesUsed` — сколько калибровочных повышений уже взято
    /// по ЭТОМУ упражнению в ЭТОЙ сессии (SPEC §9.8). Вне калибровки значение
    /// не читается. Дефолта у параметра намеренно нет, как и у
    /// `responseProfiles` в `Cycle.state`: забытый аргумент неотличим по
    /// поведению от «повышений ещё не было», то есть лимит §9.8 просто
    /// перестал бы действовать — молча и ровно в калибровке, в первые две-три
    /// тренировки новой пользовательницы. Пусть лучше не компилируется.
    ///
    /// Счётчик остаётся снаружи: он живёт в пределах одной сессии, а этот
    /// модуль ничего не хранит между вызовами. Продвигает его вызывающая
    /// сторона по `consumesCalibrationIncrease`.
    public static func nextSet(
        priorFeedback: Feedback?,
        current: Double,
        feedback: Feedback,
        actualReps: Int,
        range: ClosedRange<Int>,
        isCalibration: Bool,
        calibrationIncreasesUsed: Int,
        ladder: WeightLadder
    ) -> SetOutcome {
        if feedback == .failed && priorFeedback == .failed {
            return .terminateExercise
        }

        let raw: Double
        switch (feedback, actualReps) {
        case (.failed, _):
            raw = current * 0.90
        case (.hard, let r) where r < range.lowerBound:
            raw = current * 0.95
        case (.hard, _):
            raw = current
        case (.ok, _):
            raw = current
        case (.easy, let r) where r >= range.upperBound:
            // Калибровка: шаг вверх +15% вместо +5% (SPEC §9.8), но не больше
            // трёх повышений за упражнение в сессии. Исчерпав их, ветка
            // перестаёт двигать вес: три ×1.15 подряд — это уже +52%, и
            // продолжать поиск тем же шагом значит не подбирать вес, а
            // проскакивать его.
            if isCalibration {
                raw = consumesCalibrationIncrease(
                    feedback: feedback, actualReps: actualReps, range: range,
                    isCalibration: true, calibrationIncreasesUsed: calibrationIncreasesUsed
                ) ? current * 1.15 : current
            } else {
                raw = current * 1.05
            }
        case (.easy, _):
            // Легко, но повторов ниже верха диапазона (в т.ч. пользователь
            // сам снизил вес и не добрал до rep_min) — добираем повторами,
            // вес не трогаем. SPEC §18, сценарий 9.
            raw = current
        }

        let direction: RoundDirection = raw < current ? .down : .up
        let stepped = ladder.roundToAchievable(raw, direction: direction)

        // SPEC §9.3: «Никогда не повышаем более чем на один достижимый шаг за
        // подход вне калибровки». Округление вверх этого не даёт: оно знает
        // только, куда положить `raw`, но не сколько ступеней при этом
        // пройдено. Перелёт начинается, как только надбавка перерастает шаг
        // лестницы, то есть при `current > 20 × шаг` — и это обычные рабочие
        // веса, а не экзотика: штанга 20 кг с блинами 1.25/2.5/5/10 перелетает
        // с 52.5 кг, трос с шагом 1.25 — с 26.25, гантели через 2 кг — с 42.
        // На стеке с шагом 2.5 со 100 кг `raw` = 105 попадает точно на ступень,
        // и 102.5 оказывается перепрыгнута.
        //
        // Потолок — `nextAchievableWeight(above: current)`: по контракту он
        // строго выше `current`, то есть ровно «одна ступень вверх» из §9.3.
        // `nil` закрывает обе вырожденные лестницы разом: `.none` (ступеней
        // нет вовсе, квантовать нечего) и `.discrete` на максимуме (там
        // `roundToAchievable(.up)` уже клэмпит к верхней ступени).
        //
        // Калибровку исключает само правило: её +15% (§9.8) обязаны прыгать
        // через ступени, иначе поиск рабочего веса растягивается на сессии.
        // Ветки вниз не ограничиваются — §9.3 говорит только о повышении, а
        // для отката процент и есть смысл: −10% со 150 кг на шаге 2.5 — шесть
        // ступеней, и урезать их до одной значило бы не откатиться вовсе.
        if !isCalibration, raw > current,
           let oneStepUp = ladder.nextAchievableWeight(above: current) {
            return .nextWeight(min(stepped, oneStepUp))
        }
        return .nextWeight(stepped)
    }
}
