//  Срез безопасности: `user_restrictions`, `parq_responses` и журнал боли
//  (SPEC §3.1, §8.4, §14.1, §14.4, §20.6).
//
//  `SafetyProfile` собирается из трёх источников, и два из трёх несут правило
//  §20.6, которое из схемы не выводится.
//
//  ── Только активные ограничения ───────────────────────────────────────────
//
//  `resolved_at is null` (§20.6, обязанность 10). Снятое ограничение, которое
//  продолжает фильтровать, ничем себя не обнаруживает: пул упражнений просто
//  уже, чем должен быть, тренировка собирается, причин не печатается. Условие
//  стоит в SQL, а не здесь, — но продублировано фильтром на случай, если срез
//  соберут из строк, прочитанных иначе.
//
//  ── `isConservative` — это `has_red_flag`, и только он ────────────────────
//
//  §20.6, обязанность 11. `acknowledged` в него не входит: он говорит,
//  прочитала ли пользовательница рекомендацию к врачу, а не сняла ли она флаг.
//  Спутать их — значит выключить консервативный режим §14.1 ровно тем
//  действием, которым она подтвердила, что прочитала предупреждение.
//
//  ── Суставы события боли читаются, а не выводятся ─────────────────────────
//
//  §20.6, обязанность 3: множество берётся из колонки `sets.pain_joints`,
//  зафиксированной на момент события (§19.2 п.8). Переразметка `joint_stress` в
//  контенте уже случившиеся события не меняет, и пересчёт из разметки на чтении
//  дал бы событию суставы, которых у него не было. Кладёт их туда
//  `Recovery.painJoints(from:)` в момент записи подхода — см. `TreeState`/
//  `LogSet` на стороне роутов.

import FitCore

extension Mapping {

    /// Строка `user_restrictions` (§3.1).
    public struct RestrictionRow: Sendable, Equatable {
        public var joint: String
        public var severity: String
        /// `nil` — ограничение действует (§20.6).
        public var resolvedAt: String?

        public init(joint: String, severity: String, resolvedAt: String? = nil) {
            self.joint = joint
            self.severity = severity
            self.resolvedAt = resolvedAt
        }
    }

    /// Подход с флагом боли — срез `sets` ⋈ `workout_exercises` (§3.1, §8.4).
    public struct PainRow: Sendable, Equatable {
        public var exerciseSlug: String
        public var joints: [String]
        /// День шкалы FitCore, уже переведённый из `sets.completed_at` в зоне
        /// запроса (§20.7): конверсия делается один раз, при чтении строки, а
        /// не здесь.
        public var occurredOn: CalendarDay

        public init(exerciseSlug: String, joints: [String], occurredOn: CalendarDay) {
            self.exerciseSlug = exerciseSlug
            self.joints = joints
            self.occurredOn = occurredOn
        }
    }

    public static func restrictions(from rows: [RestrictionRow]) -> [UserRestriction] {
        rows.compactMap { row in
            guard row.resolvedAt == nil,
                  let joint = Joint(rawValue: row.joint),
                  let severity = RestrictionSeverity(rawValue: row.severity)
            else { return nil }
            return UserRestriction(joint: joint, severity: severity)
        }
    }

    /// События боли из журнала.
    ///
    /// Строка без единого распознанного сустава отбрасывается целиком, а не
    /// становится событием с пустым множеством: `Recovery.isExcluded` и
    /// `escalations` считают события, и пустое раздуло бы счёт эскалации
    /// §8.4 п.4, не дав при этом ни одного сустава для разгрузки.
    public static func painEvents(from rows: [PainRow]) -> [PainEvent] {
        rows.compactMap { row in
            let joints = Set(row.joints.compactMap(Joint.init(rawValue:)))
            guard !joints.isEmpty else { return nil }
            return PainEvent(exerciseSlug: row.exerciseSlug, joints: joints, occurredOn: row.occurredOn)
        }
    }

    /// `SafetyProfile` целиком (§7.3, §14.1, §14.4).
    ///
    /// `hasRedFlag` приходит отдельным параметром, а не строкой `parq_responses`:
    /// в срезе от неё нужно ровно одно поле, и тащить сюда `answers` и
    /// `acknowledged` значило бы дать следующему читающему повод их прочесть.
    public static func safety(
        level: ExperienceLevel,
        restrictions rows: [RestrictionRow],
        painRows: [PainRow],
        hasRedFlag: Bool
    ) -> SafetyProfile {
        SafetyProfile(
            level: level,
            restrictions: restrictions(from: rows),
            painEvents: painEvents(from: painRows),
            isConservative: hasRedFlag
        )
    }
}
