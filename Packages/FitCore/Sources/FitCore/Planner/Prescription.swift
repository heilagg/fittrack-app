//  Пересчёт предписания на другой момент утомления (SPEC §20.3).
//
//  §7.1 фиксирует момент оценки дня на 12:00 и делает это ради
//  идемпотентности: пересборка в 9:00 и в 18:00 дала бы разные тренировки. К
//  НАЧАТОЙ тренировке довод неприменим — её не пересобирают никогда, — и оба
//  крайних варианта платят слишком дорого. По 12:00 вечерняя тренировка считает
//  утомление на несколько часов старее и занижает веса (семь часов при
//  полураспаде 20 ч — около 21%, а пороги §8.2 стоят на 0.8 и 1.8); по «сейчас»
//  меняется состав между карточкой дня и нажатием «Начать», чего §7.1 не
//  разрешает: молчаливое изменение читается как баг, а объяснить его нечем.
//
//  Поэтому момент разводится по роли числа (§20.3): состав, порядок и
//  `target_sets` — по 12:00, `weight_readiness`, `prescribed_kg` и `target_rir`
//  — на фактический момент старта. `target_rir` попадает во вторую группу
//  вынужденно: §10 срезает надбавку готовности ровно тогда, когда утомление
//  подняло RIR, и разорвать эту пару значило бы выдать вес, не соответствующий
//  собственному порогу.

/// Вход `Planner.prescribe` — девять величин, и ни одной сверх (SPEC §20.3).
///
/// **Тип узкий не ради краткости, а ради контракта.** `prescribe` читала ровно
/// эти девять полей `SessionInput` и не читала восемь остальных — `dayIndex`,
/// `availability`, `sessionMinutes`, `weekDone`, `previousWorkoutSlugs`,
/// `isDeloadWeek`, `seed`, `weights`. Все восемь принадлежат ПОДБОРУ, а подбор
/// к моменту вызова уже состоялся, поэтому совпадение не случайно.
///
/// Пока вход был широким, этот список существовал только в голове читающего:
/// он нигде не записан и ничем не проверяется, и первая же правка, после
/// которой `exerciseNumbers` начнёт читать `weekDone`, превратила бы
/// подставленный вызывающей стороной ноль в тихо неверный вес. Узкий тип
/// делает список контрактом — поля, которого нет, нельзя прочитать, а появление
/// нового становится видимой правкой публичного API.
///
/// Цена принята явно: у сборки и у предписания два разных входных типа, и
/// разойтись они могут в том, что значит «то же самое утомление». Против этого
/// — единственная точка перевода (`init(_:day:)` ниже, которым пользуется сама
/// сборка) и тест §20.15 20l: предписание на НЕИЗМЕНЁННОМ утомлении не двигает
/// ни одного из трёх чисел.
public struct PrescriptionInput: Sendable {

    /// День, к которому относится сессия. Целиком, а не одной датой: по `id`
    /// проверяется, что сессия собрана на этом входе, и без этой проверки
    /// `prescribe` молча выдала бы веса чужого дня.
    public var day: PlannedDay
    public var library: [ExerciseCandidate]
    public var exerciseStates: [String: ExerciseState]
    public var equipment: EquipmentProfile
    public var goal: Goal
    public var safety: SafetyProfile

    /// Утомление НА НУЖНЫЙ МОМЕНТ — единственное поле, которое у предписания
    /// отличается от того, чем собиралась сессия (§20.3): состав считается на
    /// 12:00, числа — на фактический момент старта.
    public var fatigue: [MuscleSlug: Double]
    public var readiness: Double
    public var cycleState: CycleState

    public init(
        day: PlannedDay,
        library: [ExerciseCandidate],
        exerciseStates: [String: ExerciseState],
        equipment: EquipmentProfile,
        goal: Goal,
        safety: SafetyProfile,
        fatigue: [MuscleSlug: Double],
        readiness: Double,
        cycleState: CycleState
    ) {
        self.day = day
        self.library = library
        self.exerciseStates = exerciseStates
        self.equipment = equipment
        self.goal = goal
        self.safety = safety
        self.fatigue = fatigue
        self.readiness = readiness
        self.cycleState = cycleState
    }

    /// Единственный перевод из входа сборки. Существует затем, чтобы
    /// соответствие девяти полей было записано ОДИН раз: им пользуется сама
    /// сборка, когда считает числа упражнений, поэтому разойтись два типа
    /// могут только здесь — и только видимой правкой.
    public init(_ input: SessionInput, day: PlannedDay) {
        self.init(day: day, library: input.library, exerciseStates: input.exerciseStates,
                  equipment: input.equipment, goal: input.goal, safety: input.safety,
                  fatigue: input.fatigue, readiness: input.readiness,
                  cycleState: input.cycleState)
    }
}

extension Planner {

    /// Предписание на утомление другого момента поверх УЖЕ СОБРАННОЙ сессии.
    ///
    /// `input` — тот же вход, которым сессия собиралась, с одним изменённым
    /// полем: `fatigue` продеканo до нужного момента. Состав, порядок,
    /// `target_sets` и диапазоны повторов остаются как есть, пересчитываются
    /// ровно три числа.
    ///
    /// **Второй `buildSession` эту роль занять не может.** Утомление входит не
    /// только в числа, но и в ПОДБОР, четырьмя путями: множитель объёма мышцы в
    /// цели, слагаемое w5, выбор упражнения под ±1 подход на сессию (§10) и
    /// надбавка RIR. Второй полный вызов сменил бы и состав, и раскладку
    /// подходов — ровно то, что §20.3 запрещает.
    ///
    /// **Диапазоны повторов не пересчитываются намеренно**, хотя и могли бы:
    /// `repRange` читает состояние, а состояние от утомления не зависит вовсе,
    /// так что результат совпал бы. Оставлены нетронутыми потому, что §20.3
    /// называет три числа, а не четыре: совпадение — свойство сегодняшних
    /// формул, а не контракта, и полагаться на него значит поставить состав
    /// дня в зависимость от того, что в `Readiness` ничего не поменяется.
    ///
    /// `estimatedSeconds`, `effectiveVolume`, `scale` и `reasons` остаются
    /// прежними по той же причине: ни одна из этих величин утомления не читает
    /// (время — от готовности §13.3, объём — от состава, причины — от фазы).
    ///
    /// `nil` — сессия собрана не на этом входе: день не тот либо упражнения нет
    /// в срезе библиотеки. Молча вернуть сессию как есть нельзя: это дало бы
    /// веса по 12:00 там, где контракт обещает веса момента старта, и не упало
    /// бы ни на одном тесте.
    public static func prescribe(_ session: BuiltSession, on input: PrescriptionInput) -> BuiltSession? {
        // Сверка по `dayID`, а не по индексу: индекс принадлежит вызывающей
        // стороне и мог быть посчитан на неделе в другом порядке
        // (`buildSession` сортирует её сам), а `dayID` — то, чем сессия себя
        // называет.
        guard input.day.id == session.dayID else { return nil }
        let day = input.day
        let bySlug = Dictionary(input.library.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })

        var exercises: [PrescribedExercise] = []
        exercises.reserveCapacity(session.exercises.count)
        for exercise in session.exercises {
            guard let candidate = bySlug[exercise.slug] else { return nil }
            let stored = input.exerciseStates[exercise.slug]
            let state = stored.map {
                stateForSession($0, ladder: WeightLadder.build(loadType: candidate.loadType, profile: input.equipment),
                                on: day.date)
            }
            let n = exerciseNumbers(candidate, state: state, storedBaseline: stored?.baselineKg, input: input)
            var updated = exercise
            updated.targetRIR = n.rir
            updated.weightReadiness = n.weightReadiness
            updated.prescribedKg = n.prescribedKg
            exercises.append(updated)
        }

        var result = session
        result.exercises = exercises
        return result
    }
}
