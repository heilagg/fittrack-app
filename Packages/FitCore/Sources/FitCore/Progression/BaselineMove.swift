//  Единственная точка, через которую разрешено менять baseline_kg.
//
//  Зачем она существует. Три ревью подряд находили один и тот же класс
//  дефекта: ветка, которая обязана двигать базовую линию в одну сторону,
//  двигала её в другую — повышение клэмпилось вниз к максимуму лестницы,
//  понижение клэмпилось вверх к минимуму, отказ от надбавки готовности
//  читался как «пользователь снизил вес». Каждый раз лечение было точечным
//  guard'ом в конкретной ветке, и каждый раз следующая ветка оставалась без
//  него. Поэтому правило вынесено из веток сюда: ветки больше не
//  присваивают baseline, они возвращают НАМЕРЕНИЕ (`BaselineMove`), а его
//  проверяет и применяет `apply(_:to:...)`.
//
//  Инвариант проверяется возвратом аномалии, а не `precondition`:
//   - `precondition` — fatal trap, а не throw, и XCTest его не ловит; в этом
//     же пакете это уже проходили (см. `WeightLadder.isCentMultiple`, который
//     сделан internal ровно затем, чтобы тест проверял условие, а не трап);
//   - логировать в FitCore нечем: у пакета ноль import'ов, даже Foundation
//     нет, и это зафиксированное правило (см. Package.swift);
//   - возврат аномалии даёт ОДИНАКОВОЕ поведение в debug и release, то есть
//     ветка отката исполняется и в тестах, а не остаётся непокрытой — в
//     отличие от связки «assert в debug + молчаливый откат в релизе».
//
//  Реакция на нарушение — не клэмп к границе (он выдал бы пользователю
//  правдоподобное, но неверное число и спрятал бы дефект), а отказ двигать
//  базовую линию вовсе.

/// Намерение сдвинуть базовую линию, которое ветка свёртки возвращает вместо
/// того, чтобы присваивать `baselineKg` самой.
enum BaselineMove: Equatable {
    case hold
    case raise(to: Double, reason: Reason)
    case lower(to: Double, reason: Reason)

    /// Чем вызван сдвиг. Нужен не для отчётности, а для двух решений в
    /// `apply`: демпфировать ли по готовности (§9.6) и проверять ли
    /// согласованность с открывающим весом.
    enum Reason: Equatable {
        /// Пользователь сам изменил предписанный вес (SPEC §9.4).
        case userOverride
        /// Обычный шаг по лестнице из каскада §9.5.
        case ladderStep
        /// Вес, установленный калибровочной сессией (SPEC §9.8). Не
        /// демпфируется: калибровка ИЗМЕРЯЕТ факт («вот вес, который она
        /// вытянула сегодня»), а не корректирует базовую линию по ощущениям,
        /// и ×0.4 растянул бы сходимость на много тренировок вместо
        /// обещанных §9.8 двух-трёх.
        case calibration
        /// Deload при stall_count = 1 (SPEC §9.4).
        case stallDeload
        /// Множитель детренированности (SPEC §9.7).
        case detraining
    }
}

/// Нарушение инварианта направления. Возвращается вместе с состоянием:
/// бросать нечего (FitCore не бросает и не логирует), а вызывающий код
/// (FitData/App) может решить, что с этим делать.
enum BaselineAnomaly: Equatable {
    /// Ветка повышения вернула цель не выше текущей базовой линии.
    case raiseWouldNotRaise(from: Double, to: Double, reason: BaselineMove.Reason)
    /// Ветка понижения вернула цель не ниже текущей базовой линии.
    case lowerWouldNotLower(from: Double, to: Double, reason: BaselineMove.Reason)
    /// Сдвиг объявлен оверрайдом пользователя, но вес открывающего подхода
    /// лежит не с той стороны от базовой линии, что и направление сдвига.
    case overrideAgainstBaseline(opening: Double?, baseline: Double, raising: Bool)
}

extension BaselineMove {
    /// Допуск сравнения — половина цента, точности колонок веса в Postgres
    /// (`numeric(_,2)`, SPEC §3.1). Тот же порог, что и в остальной свёртке.
    static let epsilonKg = 0.005

    /// Проверяет намерение и применяет его. Возвращает аномалию, если
    /// намерение нарушает инвариант направления; в этом случае базовая линия
    /// НЕ меняется.
    ///
    /// `openingWeight` — фактический вес открывающего подхода сессии; нужен
    /// только для проверки ходов с `reason == .userOverride`.
    ///
    /// Демпфирование §9.6 применяется здесь и только здесь: к ходам,
    /// вызванным фидбэком (`.userOverride`, `.ladderStep`), и не применяется
    /// к `.detraining`/`.stallDeload` — те не являются реакцией на фидбэк и
    /// приходят уже готовым множителем.
    static func apply(
        _ move: BaselineMove,
        to baseline: inout Double?,
        openingWeight: Double?,
        readiness: Double
    ) -> BaselineAnomaly? {
        guard let current = baseline else {
            // Базовой линии ещё нет — двигать нечего. Инициализация идёт
            // не через ходы (см. сидирование в rebuildStates).
            return nil
        }

        let target: Double
        let reason: Reason
        let raising: Bool
        switch move {
        case .hold:
            return nil
        case .raise(let to, let why):
            target = to; reason = why; raising = true
        case .lower(let to, let why):
            target = to; reason = why; raising = false
        }

        // Инвариант 1/2: направление хода обязано совпадать с направлением
        // изменения. Ловит и клэмп повышения вниз к максимуму лестницы, и
        // клэмп понижения вверх к минимуму.
        if raising, target <= current + epsilonKg {
            return .raiseWouldNotRaise(from: current, to: target, reason: reason)
        }
        if !raising, target >= current - epsilonKg {
            return .lowerWouldNotLower(from: current, to: target, reason: reason)
        }

        // Инвариант 3: ход, объявленный оверрайдом пользователя, обязан
        // опираться на открывающий вес, лежащий с той же стороны от базовой
        // линии. Без этого отказ от надбавки готовности (взяла меньше
        // предписанного, но не меньше своей базовой линии) читается как
        // сигнал снизить базовую линию — то, что §9.6 прямо запрещает.
        if reason == .userOverride {
            guard let opening = openingWeight,
                  raising ? opening > current + epsilonKg : opening < current - epsilonKg
            else {
                return .overrideAgainstBaseline(opening: openingWeight, baseline: current, raising: raising)
            }
        }

        let damped: Bool
        switch reason {
        case .userOverride, .ladderStep: damped = true
        case .calibration, .stallDeload, .detraining: damped = false
        }
        baseline = damped
            ? BaselineUpdater.apply(baseline: current, target: target, readiness: readiness)
            : target

        return nil
    }
}
