//  Недостижимый вес (SPEC §9.5) — как повысить нагрузку, когда лестница
//  инвентаря разрежена или упражнение вообще без веса.

extension Progression {

    /// Решение о повышении нагрузки на упражнении между сессиями.
    public enum WeightDecision: Sendable, Equatable {
        /// Следующий достижимый вес слишком далёк (>10% прыжок) —
        /// расширяем диапазон повторов вместо повышения веса.
        case extendReps
        /// Обычный шаг: следующий достижимый вес в пределах 10% — повышаем.
        case increaseWeight(to: Double)
        /// Расширение исчерпано (rep_extension = 4), а прыжок всё ещё
        /// велик — прыгаем на вес и сбрасываем диапазон повторов.
        case increaseWeightWithRepReset(to: Double, newRange: ClosedRange<Int>)
        /// Тяжелее нет вообще, повторы уже выбраны до предела (rep_max + 4) —
        /// добавляем рабочий подход (до +2 от базового количества).
        case addSet
        /// Тяжелее нет, повторы и подходы исчерпаны — предложить замену из
        /// той же progression_family. Сам подбор альтернативы — Planner.
        case suggestHarderVariant
        /// В `progression_family` нет более сложного варианта — упражнение
        /// помечается «на поддержании». `planProgression` этот случай сама
        /// не возвращает (у FitCore нет доступа к `progression_family` —
        /// это контент, а не состояние прогрессии). Planner его пока тоже не
        /// выдаёт: «более сложный вариант» в семье не определён (SPEC §9.5,
        /// пп.3–4; §19.2, п.14), и слагаемое w10 равно нулю. Случай живёт в
        /// этом enum, чтобы у Progression и Planner был общий словарь, когда
        /// определение появится.
        case maintain
    }

    /// `extraSetsAdded` — сколько дополнительных рабочих подходов (сверх
    /// базового количества, максимум 2) уже добавлено на этом упражнении —
    /// `ExerciseState.extraSetsAdded`, колонка `exercise_states.extra_sets_added`
    /// (SPEC §3.1, §9.5). Состояние прогрессии, как `repExtension`; Planner
    /// только прибавляет его к `target_sets` (SPEC §7.3).
    public static func planProgression(
        baselineKg: Double,
        baseRange: ClosedRange<Int>,
        repExtension: Int,
        extraSetsAdded: Int,
        ladder: WeightLadder
    ) -> WeightDecision {
        guard let next = ladder.nextAchievableWeight(above: baselineKg) else {
            if repExtension < 4 { return .extendReps }
            if extraSetsAdded < 2 { return .addSet }
            return .suggestHarderVariant
        }

        let jump = (next - baselineKg) / baselineKg
        if jump <= 0.10 {
            return .increaseWeight(to: next)
        }

        if repExtension < 4 {
            return .extendReps
        }

        return .increaseWeightWithRepReset(
            to: next,
            newRange: baseRange.lowerBound...(baseRange.lowerBound + 2)
        )
    }
}
