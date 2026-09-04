//  WeightLadder — предвычисленная лестница достижимых весов для пары
//  (профиль инвентаря × loadType). SPEC §9.5: шаг с 6 на 8 кг на гантелях
//  2/4/6/8 — это +33% нагрузки, отсюда необходимость знать следующий
//  достижимый вес отдельно от решения, что с ним делать (это уже
//  Progression, которого здесь нет и не должно быть — WeightLadder ни от
//  чего не зависит).
//
//  Три формы лестницы:
//   .discrete    — явный список весов (гантели, гири, штанга: комбинации
//                  дискретны и конечны).
//   .arithmetic  — неограниченная прогрессия с фиксированным шагом
//                  (тренажёр/трос: в equipment_profiles нет максимума стека,
//                  поэтому конечный список построить нельзя — см. несостыковку
//                  в описании PR).
//   .none        — вес не квантуется вовсе (собственный вес, резинки).
public enum WeightLadder: Sendable, Equatable {
    case discrete([Double])
    case arithmetic(step: Double)
    case none

    /// Ближайший достижимый вес строго выше `baseline`.
    /// `nil` — такого веса нет: лестница пуста/исчерпана либо квантования
    /// нет вовсе (`.none`). Это единственный сигнал, на который реагирует
    /// вызывающий код (SPEC §9.5, п. 1: «тяжелее нет вообще»).
    public func nextAchievableWeight(above baseline: Double) -> Double? {
        let baseline = WeightLadder.round2(baseline)
        switch self {
        case .discrete(let weights):
            // TODO(код-ревью feature/weight-ladder, 2026-09-04): filter+min
            // делает два прохода и аллокацию, хотя build() всегда возвращает
            // weights уже отсортированным — first(where:) по отсортированному
            // массиву был бы одним проходом без аллокации. Не тронуто по
            // решению ревью (efficiency, не блокирует мерж).
            return weights.filter { $0 > baseline }.min()

        case .arithmetic(let step):
            guard step > 0 else { return nil }
            // Число шагов считается в целых сотых, без деления Double вообще.
            // Деление здесь ломалось в обе стороны: сырое `baseline / step`
            // давало off-by-one вниз на шуме (0.3 / 0.1 = 2.9999999999999996 →
            // floor 2 вместо 3), а round2 поверх частного — off-by-one вверх,
            // потому что его допуск 0.005 на порядки грубее шума ~1e-16 и
            // заодно схлопывал честные частные чуть ниже целого (2.49 / 2.5 =
            // 0.996 → 1 → лестница перепрыгивала ступень). Оба раза виновато
            // само деление Double; и baseline, и step кратны сотой
            // (numeric(_,2), SPEC §3.1), поэтому целочисленной арифметики
            // достаточно и порог подбирать не нужно. Код-ревью
            // feature/weight-ladder, 2026-09-04.
            guard let baselineCents = WeightLadder.cents(baseline),
                  let stepCents = WeightLadder.cents(step),
                  stepCents > 0
            else { return nil }
            // Int-деление в Swift усекает к нулю, а нужен floor — для
            // отрицательного baseline это разные вещи (см. тест на above: -3).
            var stepsBelowOrAt = baselineCents / stepCents
            if baselineCents % stepCents < 0 { stepsBelowOrAt -= 1 }
            // TODO(код-ревью feature/weight-ladder, 2026-09-04): max(stepCents, ...)
            // латает отрицательный baseline постфактум вместо того, чтобы
            // клэмпить stepsBelowOrAt у источника (max(0, ...)) — «пол лестницы
            // это step» выражен как патч над результатом, а не как инвариант
            // построения. Не тронуто по решению ревью (altitude, не блокирует
            // мерж).
            return Double(max(stepCents, (stepsBelowOrAt + 1) * stepCents)) / 100

        case .none:
            return nil
        }
    }

    /// Округление до сотых — точность колонок веса в Postgres (`numeric(_,2)`,
    /// SPEC §3.1). Суммирование `Double` даёт шум за пределами этой точности
    /// (классика: 0.1 + 0.2 ≠ 0.3), из-за которого subset-sum блинов мог не
    /// дедуплицировать математически равные суммы, а `nextAchievableWeight`
    /// мог сравнить `baseline` с лестницей на пару ULP не в ту сторону.
    /// Округление после каждой арифметической операции и перед сравнением
    /// схлопывает такой шум в одно и то же представление `Double`.
    ///
    /// TODO(код-ревью feature/weight-ladder, 2026-09-04): в `build()` и
    /// `subsetSums` корректность по-прежнему держится на том, что round2 не
    /// забыли вызвать в каждой точке арифметики — технически это ничем не
    /// обеспечено. `.arithmetic` из этого списка выбыла: она считает в целых
    /// сотых (см. `cents`), деления Double там нет вовсе, и дисциплина ей
    /// больше не нужна. Более глубокое решение для остальных — тип-обёртка
    /// вроде Kilograms, у которой +/*/сравнение сами округляют. Не тронуто по
    /// решению ревью (altitude, не блокирует мерж); естественный повод
    /// сделать это — когда Progression/Planner тоже понадобится точность
    /// numeric(_,2).
    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Вес в целых сотых долях килограмма. Колонки веса в Postgres — это
    /// `numeric(_,2)` (SPEC §3.1), то есть входные веса по построению кратны
    /// сотой: их можно перевести в целые один раз и дальше считать точно,
    /// не внося шум Double делением и не подбирая эпсилон.
    ///
    /// `nil` — значение не конечно (nan/inf) либо не помещается в Int без
    /// потери точности: за 2^53 сотых сам Double уже не представляет целые
    /// точно. Проверка обязательна, а не косметическая — `Int(_: Double)` на
    /// таких значениях не возвращает мусор, а роняет процесс.
    ///
    /// Кодирует то же правило «точность до сотых», что и `round2` выше;
    /// объединить их в один тип — часть отложенной работы про Kilograms.
    private static func cents(_ value: Double) -> Int? {
        let scaled = (value * 100).rounded()
        guard scaled.isFinite, scaled.magnitude <= 9_007_199_254_740_992 else { return nil }
        return Int(scaled)
    }
}

extension WeightLadder {
    /// Строит лестницу для конкретного профиля инвентаря и типа нагрузки.
    public static func build(loadType: LoadType, profile: EquipmentProfile) -> WeightLadder {
        switch loadType {
        case .dumbbell:
            return .discrete(profile.dumbbellsKg.map(round2).sorted())

        case .kettlebell:
            return .discrete(profile.kettlebellsKg.map(round2).sorted())

        case .barbell:
            guard let bar = profile.barbellKg else { return .discrete([]) }
            let perSideSums = subsetSums(of: profile.platesKg)
            let totals = perSideSums.map { round2(bar + 2 * $0) }
            return .discrete(Array(Set(totals)).sorted())

        case .machine, .cable:
            guard let step = profile.machineStepKg, step > 0 else { return .discrete([]) }
            return .arithmetic(step: round2(step))

        case .bodyweight, .bodyweightLoaded, .band:
            return .none
        }
    }

    /// Суммы всех подмножеств `plates` — нагрузка на одну сторону штанги.
    /// Каждый блин из списка участвует не больше одного раза на сторону:
    /// `platesKg` уже описывает пары (SPEC §3.1, комментарий к колонке).
    /// Округляется на каждом шаге (см. `round2`), иначе накопленный шум
    /// `Double` может помешать дедупу сумм от разных подмножеств.
    ///
    /// TODO(код-ревью feature/weight-ladder, 2026-09-04): O(2^n) по числу
    /// блинов, без заявленной границы. SPEC (equipment_profiles.plates_kg)
    /// хранит блины поштучно, а не по номиналам, так что n — это реальный
    /// инвентарь пользователя, не набор из 5-8 номиналов. Не тронуто по
    /// решению ревью (efficiency, не блокирует мерж).
    private static func subsetSums(of plates: [Double]) -> [Double] {
        var sums: Set<Double> = [0]
        for plate in plates {
            let extended = sums.map { round2($0 + plate) }
            sums.formUnion(extended)
        }
        return Array(sums)
    }
}
