//  Флаг боли (SPEC §8.4). Немедленное прекращение упражнения и запись
//  `sets.pain_flag = true` (SPEC §3.1, п.1) — это состояние одного подхода,
//  которое пишет FitData/экран тренировки напрямую; Recovery в этом не
//  участвует. Здесь — только то, что требует памяти по истории событий:
//  исключение упражнения на 14 дней (п.3) и эскалация по 30-дневному окну
//  (п.4, п.5).

/// Один зафиксированный флаг боли — срез `sets` (`pain_flag = true`),
/// дополненный суставами, которым этот флаг приписан.
///
/// **Суставов несколько, а не один** (SPEC §8.4 п.5, §19.2 п.8). Выбирать
/// между равными по нагрузке было нечем: канонический пример §6.2
/// (`hip_thrust_barbell`) даёт `lower_back` и `hip` одинаковой степени
/// `medium`, и любой тай-брейк молча обнулял бы счёт второго сустава. Поэтому
/// событие несёт всё множество, а п.5 считается по пересечению множеств.
///
/// Сам `joint_stress` — поле упражнения из FitContent, от которого FitCore не
/// зависит, поэтому готовое множество передаёт вызывающая сторона
/// (`Recovery.painJoints(from:)`). Выводить его заново при каждом чтении она не
/// должна: множество фиксируется в `sets.pain_joints` (SPEC §3.1) в момент
/// события, иначе переразметка контента задним числом создавала бы и отменяла
/// бы рекомендацию показаться специалисту.
public struct PainEvent: Sendable, Equatable {
    public var exerciseSlug: String
    /// Все суставы, которым приписан флаг (SPEC §8.4 п.5, §19.2 п.8, вариант «б»).
    public var joints: Set<Joint>
    public var occurredOn: CalendarDay

    public init(exerciseSlug: String, joints: Set<Joint>, occurredOn: CalendarDay) {
        self.exerciseSlug = exerciseSlug
        self.joints = joints
        self.occurredOn = occurredOn
    }
}

/// Мягкое предложение пользователю по итогам эскалации (SPEC §8.4, п.4–5).
/// Ни один из вариантов не блокирует и не применяет ограничение сам —
/// решение остаётся за пользователем (SPEC §8.4 читается в связке с §8.2:
/// «не блокируем»).
public enum PainEscalation: Sendable, Equatable {
    case suggestPermanentRestriction(exerciseSlug: String)
    case suggestSpecialist(joint: Joint)
}

extension Recovery {
    /// Суставы, которым приписывается флаг боли на упражнении с данным
    /// `joint_stress` (SPEC §6.2) — вход для `PainEvent.joints`.
    ///
    /// Правило: все суставы МАКСИМАЛЬНОЙ степени нагрузки. Тай-брейк по
    /// порядку объявления снят (SPEC §19.2 п.8, закрыт вариантом «б»): он был
    /// детерминирован, но клинически произволен, и у двух равных суставов
    /// счёт §8.4 п.5 доставался первому по алфавиту служебного слага.
    ///
    /// Суставы меньшей степени в множество НЕ входят: `low` — это упоминание
    /// сустава в разметке, а не основание рекомендовать специалиста. На
    /// каноническом примере §6.2 (`knee: low`, `lower_back: medium`,
    /// `hip: medium`) разница видна числом: с порогом по максимуму три события
    /// дают две рекомендации, без порога — три.
    ///
    /// Пустое множество — только для пустого словаря. Пустой `joint_stress`
    /// означает упражнение, не грузящее ни одного сустава; это ошибка разметки
    /// контента, и ловить её место в `Tools/content-validator`, а не здесь
    /// (реальных упражнений пока нет, только `_schema.example.json`).
    public static func painJoints(from jointStress: [Joint: JointStressLevel]) -> Set<Joint> {
        guard let top = jointStress.values.max() else { return [] }
        return Set(jointStress.filter { $0.value == top }.keys)
    }

    /// SPEC §8.4, п.3.
    public static let painExclusionDays = 14
    /// SPEC §8.4, п.4–5.
    public static let painEscalationWindowDays = 30

    /// SPEC §8.4, п.3: упражнение исключается из подбора на 14 дней после
    /// флага боли на нём. Границу дня 14 включаем (симметрично с §8.4,
    /// который не уточняет — окно «на 14 дней» естественнее читать как
    /// включающее, чем как «13 полных дней»).
    public static func isExcluded(exerciseSlug: String, from events: [PainEvent], asOf today: CalendarDay) -> Bool {
        events.contains { event in
            event.exerciseSlug == exerciseSlug
                && isWithin(event.occurredOn, of: today, days: painExclusionDays)
        }
    }

    /// SPEC §8.4, п.4–5: эскалации за последние 30 дней. Порядок вывода
    /// детерминирован (сортировка по слагу/суставу) — источник, `events`,
    /// такой гарантии не даёт.
    public static func escalations(from events: [PainEvent], asOf today: CalendarDay) -> [PainEscalation] {
        let recent = events.filter { isWithin($0.occurredOn, of: today, days: painEscalationWindowDays) }

        // п.4: флаг боли по одному упражнению повторяется 2 раза за 30 дней.
        let restrictionSlugs = Dictionary(grouping: recent, by: \.exerciseSlug)
            .filter { $0.value.count >= 2 }
            .keys.sorted()

        // п.5: флаг боли по разным упражнениям с одним joint_stress-суставом
        // 3 раза за 30 дней — «разным» проверяем через количество различных
        // exercise_slug, а не общее число событий (иначе совпало бы с п.4
        // при повторной боли в одном и том же упражнении).
        //
        // Счёт по ПЕРЕСЕЧЕНИЮ множеств (SPEC §8.4 п.5): событие входит в счёт
        // каждого своего сустава, поэтому ничья lower_back/hip поднимает оба, а
        // не первый по порядку. Одно упражнение с двумя суставами трёх
        // рекомендаций не даёт: считаются различные слаги, как и раньше.
        var slugsByJoint: [Joint: Set<String>] = [:]
        for event in recent {
            for joint in event.joints { slugsByJoint[joint, default: []].insert(event.exerciseSlug) }
        }
        let specialistJoints = slugsByJoint.filter { $0.value.count >= 3 }
            .keys.sorted { $0.rawValue < $1.rawValue }

        return restrictionSlugs.map { .suggestPermanentRestriction(exerciseSlug: $0) }
            + specialistJoints.map { .suggestSpecialist(joint: $0) }
    }

    // TODO(код-ревью feature/recovery, 2026-09-08): третья независимая
    // реализация «сколько дней прошло с события» поверх CalendarDay — рядом
    // живут Progression/RebuildStates.swift (gap для детренированности, §9.7)
    // и Progression/Detraining.swift. Они уже расходятся в мелочи: там
    // отрицательный разрыв не отсекается вовсе (вход обязан быть отсортирован),
    // здесь отсекается явно. Общего хелпера на CalendarDay нет, поэтому
    // единая правка семантики потребует ручного обхода всех трёх мест.
    // Не трогаем в этой ветке по решению ревью — вернуться при работе над Cycle.
    private static func isWithin(_ day: CalendarDay, of today: CalendarDay, days: Int) -> Bool {
        let elapsed = day.days(until: today)
        return elapsed >= 0 && elapsed <= days
    }
}
