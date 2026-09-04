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
    /// Явный список достижимых весов. Каждый элемент обязан быть кратен
    /// сотой доле кг (`numeric(_,2)`, SPEC §3.1) — эту гарантию даёт
    /// `build()` (все четыре пути к `.discrete` там проходят через
    /// `round2`). Конструирование вручную с нецентовым весом — обязанность
    /// вызывающего кода нарушена: `nextAchievableWeight` полагается на
    /// кратность центу при сравнении и падает через `precondition`, если
    /// это не так (см. `isCentMultiple`). Код-ревью feature/weight-ladder,
    /// 2026-09-04.
    case discrete([Double])
    case arithmetic(step: Double)
    case none

    /// Ближайший достижимый вес строго выше `baseline`.
    /// `nil` — такого веса нет: лестница пуста/исчерпана либо квантования
    /// нет вовсе (`.none`). Это единственный сигнал, на который реагирует
    /// вызывающий код (SPEC §9.5, п. 1: «тяжелее нет вообще»).
    public func nextAchievableWeight(above baseline: Double) -> Double? {
        switch self {
        case .discrete(let weights):
            // Сравнение идёт с позицией baseline на сетке центов, а не с
            // самим baseline: ступени кратны центу, поэтому для ступени r
            // условие `r > baseline` эквивалентно `r > floorCents(baseline)`.
            // Верно только если каждая ступень тоже кратна центу — это
            // обязанность конструирующего кода (см. doc на `case discrete`),
            // и здесь она проверяется явно, а не молча: с нецентовой
            // ступенью порог мог оказаться ниже baseline, и функция вернула
            // бы вес не старше запрошенного — порча контракта «строго выше»,
            // а не просто неточность. Код-ревью feature/weight-ladder,
            // 2026-09-04.
            precondition(
                weights.allSatisfy(WeightLadder.isCentMultiple),
                "WeightLadder.discrete requires every rung to be a multiple of 0.01 kg (numeric(_,2), SPEC §3.1); construct via build(), which guarantees this."
            )
            guard let baselineCents = WeightLadder.floorCents(baseline) else { return nil }
            let threshold = Double(baselineCents) / 100
            // TODO(код-ревью feature/weight-ladder, 2026-09-04): filter+min
            // делает два прохода и аллокацию, хотя build() всегда возвращает
            // weights уже отсортированным — first(where:) по отсортированному
            // массиву был бы одним проходом без аллокации. Не тронуто по
            // решению ревью (efficiency, не блокирует мерж).
            return weights.filter { $0 > threshold }.min()

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
            guard let baselineCents = WeightLadder.floorCents(baseline),
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

    /// Кладёт **значение домена** на сетку центов: округление к ближайшему.
    /// Колонки веса в Postgres — `numeric(_,2)` (SPEC §3.1), то есть веса
    /// инвентаря и шаг по построению уже кратны сотой, и такое округление
    /// для них идемпотентно: два разных истинных значения отличаются минимум
    /// на цент, поэтому к ближайшему центу значение не может уехать на чужую
    /// точку сетки.
    ///
    /// Не применять к `baseline` — он сеткой не ограничен (произвольный
    /// результат вычислений вызывающего кода), и округление к ближайшему
    /// перетаскивает его через достижимую ступень. Для него `floorCents`.
    ///
    /// `nil` — значение не конечно (nan/inf) либо не помещается в Int без
    /// потери точности: за 2^53 сотых сам Double уже не представляет целые
    /// точно. Проверка обязательна, а не косметическая — `Int(_: Double)` на
    /// таких значениях не возвращает мусор, а роняет процесс.
    private static func cents(_ value: Double) -> Int? {
        let scaled = (value * 100).rounded()
        guard scaled.isFinite, scaled.magnitude <= 9_007_199_254_740_992 else { return nil }
        return Int(scaled)
    }

    /// Определяет **позицию для сравнения** на сетке центов: округление вниз
    /// с допуском масштаба шума `Double`.
    ///
    /// Почему вниз, а не к ближайшему: все ступени лестницы кратны центу, а
    /// для целой ступени `r` условие `r > x` тождественно `r > floor(x)`.
    /// Округление вниз поэтому не теряет ничего, а округление к ближайшему
    /// затягивает baseline вверх через достижимую ступень — 7.999 становился
    /// 8.0, и лестница либо перепрыгивала 8.0, либо (в `.discrete`) объявляла
    /// себя исчерпанной при доступных 8 кг.
    ///
    /// Зачем вообще допуск: baseline может прийти из накопленной арифметики,
    /// и 5.999999999999996 обязан читаться как «стоим на 6.0» (см.
    /// `test_nextAchievableWeightRoundsBaselineBeforeComparing`). Но 7.999 —
    /// честно ниже 8.0, и допуск не имеет права его туда тянуть.
    ///
    /// Допуск = `min(1e-3, max(1e-9, |scaled| · 1e-12))` цента — **никогда не
    /// превышает 1e-3 цента (3 порядка ниже цента), при любом baseline,
    /// допускаемом guard'ом ниже**. Без верхнего `min` относительный член
    /// растёт вместе с |baseline| без предела и достигает целого цента уже
    /// при |baseline| = 1e10 кг — внутри диапазона, который guard пропускает
    /// (до ~9·10¹³ кг) — и воспроизводит тот же баг, ради которого этот
    /// хелпер написан: пропуск ступени. Именно это и стало четвёртым по
    /// счёту случаем одного и того же дефекта (код-ревью
    /// feature/weight-ladder, 2026-09-04) — клэмп фиксирует это структурно, а
    /// не очередной подбор порога.
    ///
    /// TODO(код-ревью feature/weight-ladder, 2026-09-04): клэмп в 1e-3 цента
    /// сам по себе достаточен, только пока реальный шум `Double`-арифметики
    /// (порядка `|scaled| · 2⁻⁵²`) остаётся ниже него — это верно при
    /// |baseline| ≲ 4.5·10¹⁰ кг. Выше этой границы (физически абсурдные
    /// значения — 45 миллионов тонн) шум в принципе может превысить клэмп и
    /// перестать гаситься, воспроизводя в миниатюре до-4561e85 поведение
    /// (не распознать шумную baseline «на ступени»). Не чинится — граница
    /// недостижима иначе как в обход `build()`.
    private static func floorCents(_ value: Double) -> Int? {
        let scaled = value * 100
        guard scaled.isFinite else { return nil }
        let noise = min(1e-3, max(1e-9, scaled.magnitude * 1e-12))
        let floored = (scaled + noise).rounded(.down)
        guard floored.magnitude <= 9_007_199_254_740_992 else { return nil }
        return Int(floored)
    }

    /// `value` уже кратно сотой доле кг — `value * 100` не требует
    /// округления, чтобы стать целым. Проверяет ровно то же условие, которое
    /// защищает `precondition` в `.discrete` (см. doc на `case discrete`);
    /// не `private`, чтобы тест мог проверить условие напрямую — сам
    /// `precondition` XCTest поймать не может (это fatal trap, не throw).
    static func isCentMultiple(_ value: Double) -> Bool {
        let scaled = value * 100
        return scaled.isFinite && scaled == scaled.rounded()
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
