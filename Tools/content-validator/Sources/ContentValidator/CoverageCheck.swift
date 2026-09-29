//  Правило покрытия §20.11: «тренировка собирается», а не «три упражнения».
//
//  Проверка не считает разметку, а ВЫЗЫВАЕТ сборку §7.3 — так решено в
//  content-domain §2 п.2. Счётное правило не годится в обе стороны: оно
//  пропускало бы библиотеку, на которой сборка ослабляет минимум паттернов, и
//  отвергало бы здоровую сессию из трёх упражнений, к которой у §7.3 претензий
//  нет (§20.11, «Числового порога у правила нет»).
//
//  Комбинация покрыта, если сборка даёт непустую тренировку, не ослабившую ни
//  одного своего правила: минимума трёх разных `pattern`, лимита «не более двух
//  из одной `progression_family`» и лимита семи упражнений. Машинно это ровно
//  отсутствие причин ослабления в итоге сборки — их печатает сам §7.3, и
//  второго определения «ослабила» валидатор не заводит.
//
//  ── Что зафиксировано в прогоне и почему именно так ───────────────────────
//
//  **Неделя из одного дня.** Правило говорит про комбинацию, а не про неделю.
//  `S_эфф` делится на сумму доли мышцы по ЗАПЛАНИРОВАННЫМ сессиям недели (§7.3),
//  поэтому любая другая форма недели добавила бы в правило вторую переменную,
//  которую §20.11 не называет, и выбор этой формы был бы произволом.
//
//  **Бюджет времени не задан** (`sessionMinutes: nil`, «сборка без бюджета»,
//  §7.1). Иначе проверялся бы бюджет, а не разметка: нехватку времени §7.3
//  печатает ДРУГОЙ причиной (`patternMinimumRelaxedByTime`), она меняется одним
//  тапом по `session_minutes` и браком разметки не является.
//
//  **Уровень пользователя — `novice`.** Пул отбирается условием
//  `skill_level ≤ уровня` (§7.3), значит пул новичка вложен в пул среднего, а
//  тот — в пул опытного. Покрытие на новичке влечёт покрытие на двух
//  остальных — та же монотонность, на которой §20.11 оставляет нижний профиль
//  инвентаря.
//
//  **Консервативный режим §14.1 правилом НЕ проверяется.** Он беднее любого из
//  трёх уровней (потолок `novice` плюс исключение любого `joint_stress: high`),
//  и §20.11 его среди осей не называет. Вводить его сюда значило бы решить за
//  SPEC; прогон печатает про это строку в сводке, чтобы дыра не была
//  безымянной.

import FitCore
import FitContent

public enum CoverageCheck {

    /// Минимум разных паттернов — единственное числовое правило, которое §7.3
    /// действительно держит: его он сам и ремонтирует, а ослабление печатает
    /// причиной. Порога по числу упражнений у правила НЕТ и быть не должно —
    /// см. §20.11, «Числового порога у правила нет»: жадный отбор
    /// останавливается, когда score перестаёт расти, и три упражнения с тремя
    /// паттернами и без единой причины — здоровая сессия.
    public static let minPatterns = 3
    /// Один и тот же seed на всех комбинациях: сборка обязана быть
    /// воспроизводимой, и разный seed давал бы разные ничьи (§7.3).
    public static let seed: UInt64 = 20_260_926

    /// Заведомо неполные комбинации (§20.11): пары (тип дня, уровень
    /// инвентаря), где профильный паттерн типа дня физически недостижим И
    /// из-за этого недостижимо полное правило.
    ///
    /// Список — копия §20.11, и расти он обязан только правкой SPEC. Поэтому
    /// здесь он константа, а не вывод из данных: вычисляемый список молча
    /// оправдывал бы любую дыру, ради чего его и нельзя вычислять.
    /// На принятом срезе строка одна. Ожидалось три — `pull` и `full_body`
    /// сняты прогоном: тянущего паттерна на пустом профиле нет, но полное
    /// правило они набирают другими паттернами, а требования «в дне спины
    /// обязана быть тяга» §20.11 не вводит.
    public static let declaredIncomplete: Set<Combination> = [
        Combination(kind: .upper, level: .bodyweight),
    ]

    public struct Combination: Hashable, Sendable {
        public let kind: SessionKind
        public let level: EquipmentLevel

        public init(kind: SessionKind, level: EquipmentLevel) {
            self.kind = kind
            self.level = level
        }
    }

    public static func run(_ library: ContentLibrary, into findings: FindingCollector) -> Summary {
        var summary = Summary()
        guard !library.candidates.isEmpty else {
            findings.add(rule: "§20.11", subject: "покрытие",
                         "библиотека пуста: правило покрытия проверять не на чем")
            return summary
        }

        for level in EquipmentLevel.allCases {
            for kind in DayVectorTable.vectorBearingKinds {
                let combination = Combination(kind: kind, level: level)
                let exempt = declaredIncomplete.contains(combination)
                var everyAccentPassedFully = true
                var builtAnything = false

                for accent in accents {
                    guard let vector = library.vectors.vector(kind: kind, accent: accent) else {
                        continue  // дыру в таблице называет VectorChecks
                    }
                    summary.builds += 1
                    builtAnything = true
                    let pair = VectorChecks.name(DayVectorKey(kind: kind, accent: accent))
                    let subject = "\(level.rawValue) \(pair)"
                    let verdict = build(library: library, level: level, kind: kind,
                                        accent: accent, vector: vector)

                    switch verdict {
                    case .empty(let why):
                        // Пустая тренировка не допускается нигде и ни при каких
                        // условиях, включая заведомо неполные комбинации.
                        findings.add(rule: "§20.11", subject: subject,
                                     "тренировка не собралась: \(why)")
                        everyAccentPassedFully = false
                    case .relaxed(let why):
                        everyAccentPassedFully = false
                        if !exempt {
                            findings.add(rule: "§20.11", subject: subject,
                                         "правило покрытия не выполнено: \(why)")
                        } else {
                            summary.relaxedInDeclared += 1
                        }
                    case .full:
                        summary.passed += 1
                    }
                }

                // Строка списка, которая больше ничего не оправдывает, обязана
                // из него уйти: иначе список исключений тихо переживает ту
                // разметку, ради которой его завели.
                //
                // `builtAnything` обязателен: без него комбинация, у которой в
                // таблице нет ни одного вектора, выглядела бы «прошедшей
                // полностью» — ни одна сборка не запускалась, и опровергнуть
                // было нечем. Дыру в таблице называет VectorChecks, и второй
                // раз, да ещё требованием убрать исключение, она не называется.
                if exempt, builtAnything, everyAccentPassedFully {
                    findings.add(rule: "§20.11", subject: "\(level.rawValue) \(kind.rawValue)",
                                 "комбинация объявлена заведомо неполной, но проходит правило "
                                 + "полностью — строку пора убрать из §20.11")
                }
            }
        }
        return summary
    }

    private static var accents: [MuscleSlug?] { [nil] + MuscleSlug.allCases.map { $0 } }

    // MARK: - Одна сборка

    private enum Verdict {
        case full
        case relaxed(String)
        case empty(String)
    }

    private static func build(
        library: ContentLibrary, level: EquipmentLevel, kind: SessionKind,
        accent: MuscleSlug?, vector: [MuscleSlug: Double]
    ) -> Verdict {
        let day = PlannedDay(id: "coverage", date: CalendarDay(year: 2026, month: 1, day: 5),
                             kind: kind, accent: accent, vector: vector)
        let input = SessionInput(
            week: [day],
            dayIndex: 0,
            library: library.candidates,
            availability: level.availability,
            equipment: level.equipment,
            safety: SafetyProfile(level: .novice),
            goal: .general,
            sessionMinutes: nil,
            cycleState: CycleState(phaseMode: .noPhases, noPhaseReason: .userChoice,
                                   hasAnchor: false, phase: nil, cycleConfidence: nil,
                                   periodization: nil, effectivePhaseAdjustment: nil),
            seed: seed)

        guard let session = Planner.buildSession(input) else {
            return .empty("Planner.buildSession вернул nil")
        }
        if session.exercises.isEmpty {
            // `noFeasibleExercises` шире своего имени: §7.3 печатает её и когда
            // жёсткие ограничения не пропустили ничего, и когда пул непуст, но
            // ни одно упражнение не служит вектору дня (`serving` в
            // SessionBuilder). Для разметки это разные диагнозы — «нечем
            // тренироваться на этом инвентаре» против «библиотека не покрывает
            // эти мышцы», — поэтому формулировка называет оба.
            let reason = session.reasons.contains(where: isNoFeasible)
                ? "noFeasibleExercises: на этом профиле либо ничего не проходит жёсткие "
                  + "ограничения, либо ни одно упражнение не грузит мышцы вектора"
                : "состав пуст без названной причины"
            return .empty(reason)
        }
        if let relaxation = session.reasons.first(where: isRelaxation) {
            return .relaxed(describe(relaxation, session: session))
        }
        // Инвариант, а не второе правило: ремонт паттернов §7.3 добирает до трёх
        // всегда, когда их столько есть, а когда нет — печатает причину, которую
        // поймала ветка выше. Меньше трёх без причины означало бы, что сборка
        // изменилась и правило покрытия проверяет не то, что думает.
        let patterns = Set(session.exercises.compactMap { library.bySlug[$0.slug]?.pattern })
        if patterns.count < minPatterns {
            return .relaxed("\(patterns.count) паттернов из \(minPatterns) и ни одной "
                            + "причины — сборка §7.3 изменилась, правило покрытия устарело")
        }
        return .full
    }

    private static func isNoFeasible(_ reason: ReasonCode) -> Bool {
        if case .noFeasibleExercises = reason { return true }
        return false
    }

    private static func isRelaxation(_ reason: ReasonCode) -> Bool {
        switch reason {
        case .patternMinimumRelaxedUnavailable, .patternMinimumRelaxedByTime,
             .patternMinimumRelaxedByLimit:
            return true
        default:
            return false
        }
    }

    private static func describe(_ reason: ReasonCode, session: BuiltSession) -> String {
        let count = "собрано \(session.exercises.count) упражнений"
        switch reason {
        case .patternMinimumRelaxedUnavailable(let available):
            return "минимум паттернов ослаблен недоступностью: их \(available); \(count)"
        case .patternMinimumRelaxedByTime(let fitted):
            return "минимум паттернов ослаблен временем: поместилось \(fitted); \(count)"
        case .patternMinimumRelaxedByLimit(let fitted, let limit):
            return "минимум паттернов ослаблен лимитом \(limit): поместилось \(fitted); \(count)"
        default:
            return count
        }
    }

    public struct Summary: Sendable {
        public var builds = 0
        public var passed = 0
        public var relaxedInDeclared = 0
    }
}
