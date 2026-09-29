//  Срез цикла: `cycle_events`, `cycle_profiles`, `phase_response_profile`
//  (SPEC §3.1, §11.3, §11.4, §11.5, §20.6).
//
//  ── Главная обязанность слоя, и она первая в списке §20.6 ─────────────────
//
//  **Строки `cycle_profiles` может не быть вовсе, и дефолт конструктора здесь
//  не годится.** У `CycleProfile` умолчание `phaseMode == .phases`, и оно верно
//  ровно там, где строка есть: она появляется на шаге 9 онбординга, который
//  проходят не все. У мужчины её нет никогда; у отключившей отслеживание
//  (`profiles.cycle_tracking = 'off'`) она может быть, но источника данных нет.
//
//  Цена молчаливого дефолта названа в doc-комментарии самого `CycleProfile` и
//  стоит того, чтобы повторить: в фазовом режиме без опорной даты
//  `Readiness.plannedVolumeFactor` возвращает 1.0, и признак разгрузочной
//  недели §11.5 игнорируется — у ВСЕХ мужчин и у всех отключивших цикл разом.
//  Это не отказ и не исключение: просто объём не снижается там, где должен, и
//  увидеть это можно только числом. Ни один тест §20.15 такого не ловит.
//
//  Поэтому режим собирается здесь, из двух источников сразу — строки и
//  `cycle_tracking`, — а не читается из одной колонки.
//
//  ── Почему `notified` считается, а не читается ────────────────────────────
//
//  В схеме `phase_response_profile.notified_at timestamptz` (§3.1), в FitCore
//  `PhaseResponseProfile.notified: Bool` (§11.4). Типы разные, и перевод —
//  `!= nil`: ядру нужен факт «сообщали ли», а момент нужен только UI, чтобы не
//  сообщить дважды. §20.6 этой обязанности не называет — она найдена сверкой
//  миграции `0002` с типом.

import FitCore

extension Mapping {

    /// Строка `cycle_events` (§3.1).
    public struct CycleEventRow: Sendable, Equatable {
        public var kind: String
        public var occurredOn: CalendarDay

        public init(kind: String, occurredOn: CalendarDay) {
            self.kind = kind
            self.occurredOn = occurredOn
        }
    }

    /// Строка `cycle_profiles` (§3.1). `nil` вместо неё — строки нет.
    public struct CycleProfileRow: Sendable, Equatable {
        public var typicalCycleLengthDays: Int?
        public var typicalPeriodLengthDays: Int?
        public var declaredRegularity: String?
        public var phaseMode: String
        public var noPhaseReason: String?
        public var lowConfidenceStreak: Int
        public var lowConfidenceCountedThrough: CalendarDay?

        public init(typicalCycleLengthDays: Int? = nil, typicalPeriodLengthDays: Int? = nil,
                    declaredRegularity: String? = nil, phaseMode: String = "phases",
                    noPhaseReason: String? = nil, lowConfidenceStreak: Int = 0,
                    lowConfidenceCountedThrough: CalendarDay? = nil) {
            self.typicalCycleLengthDays = typicalCycleLengthDays
            self.typicalPeriodLengthDays = typicalPeriodLengthDays
            self.declaredRegularity = declaredRegularity
            self.phaseMode = phaseMode
            self.noPhaseReason = noPhaseReason
            self.lowConfidenceStreak = lowConfidenceStreak
            self.lowConfidenceCountedThrough = lowConfidenceCountedThrough
        }
    }

    /// Строка `phase_response_profile` (§3.1, §11.4).
    public struct PhaseResponseRow: Sendable, Equatable {
        public var phase: String
        public var adjustment: Double
        public var sampleSize: Int
        /// Момент, а не флаг: ядру нужен факт, UI — момент (§11.4).
        public var notifiedAt: String?

        public init(phase: String, adjustment: Double, sampleSize: Int, notifiedAt: String? = nil) {
            self.phase = phase
            self.adjustment = adjustment
            self.sampleSize = sampleSize
            self.notifiedAt = notifiedAt
        }
    }

    public static func cycleEvents(from rows: [CycleEventRow]) -> [CycleEvent] {
        rows.compactMap { row in
            guard let kind = CycleEventKind(rawValue: row.kind) else { return nil }
            return CycleEvent(kind: kind, occurredOn: row.occurredOn)
        }
    }

    /// Профиль цикла с УЧЁТОМ источника данных (§20.6, обязанность 1).
    ///
    /// Режим «без фаз» подставляется в двух случаях: строки нет вовсе и
    /// `cycle_tracking == .off`. Причина — `.userChoice`, как велит §20.6: это
    /// и правда выбор пользователя, сделанный на шаге 9 онбординга либо не
    /// сделанный никогда.
    ///
    /// Сохранённая причина при этом ВЫИГРЫВАЕТ у подставленной: если в строке
    /// стоит `contraception` или `menopause`, она остаётся. Иначе ручное
    /// переключение §11.5 и клинический повод схлопнулись бы в одно значение, а
    /// §11.5 различает их по обратимости — «не сейчас» переспрашивается позже,
    /// «менопауза» нет.
    public static func cycleProfile(from row: CycleProfileRow?, tracking: CycleTracking) -> CycleProfile {
        guard let row, tracking != .off else {
            return CycleProfile(phaseMode: .noPhases,
                                noPhaseReason: row.flatMap { NoPhaseReason(rawValue: $0.noPhaseReason ?? "") }
                                    ?? .userChoice)
        }
        return CycleProfile(
            typicalCycleLengthDays: row.typicalCycleLengthDays,
            typicalPeriodLengthDays: row.typicalPeriodLengthDays,
            declaredRegularity: row.declaredRegularity.flatMap(DeclaredRegularity.init(rawValue:)),
            // Значение вне словаря — «без фаз»: неизвестный режим безопаснее
            // читать как отсутствие фаз, чем как их наличие. Фазовый режим на
            // мусорном значении двигал бы объём и RIR по выдуманной фазе.
            phaseMode: PhaseMode(rawValue: row.phaseMode) ?? .noPhases,
            noPhaseReason: row.noPhaseReason.flatMap(NoPhaseReason.init(rawValue:)),
            lowConfidenceStreak: row.lowConfidenceStreak,
            lowConfidenceCountedThrough: row.lowConfidenceCountedThrough
        )
    }

    /// Личный профиль фазовой реакции (§11.4).
    public static func phaseResponses(from rows: [PhaseResponseRow]) -> [Phase: PhaseResponseProfile] {
        var result: [Phase: PhaseResponseProfile] = [:]
        for row in rows {
            guard let phase = Phase(rawValue: row.phase) else { continue }
            result[phase] = PhaseResponseProfile(adjustment: row.adjustment,
                                                 sampleSize: row.sampleSize,
                                                 notified: row.notifiedAt != nil)
        }
        return result
    }

    /// Вход `Cycle.state` и `planRemainingDays` целиком (§7.1).
    public static func cycleInputs(events: [CycleEventRow], profile: CycleProfileRow?,
                                   responses: [PhaseResponseRow], tracking: CycleTracking) -> CycleInputs {
        CycleInputs(events: cycleEvents(from: events),
                    profile: cycleProfile(from: profile, tracking: tracking),
                    responseProfiles: phaseResponses(from: responses))
    }

    // MARK: - Чек-ин

    /// Строка `daily_checkins` (§3.1).
    public struct CheckinRow: Sendable, Equatable {
        public var energy: Int?
        public var soreness: Int?
        public var sleepQuality: Int?
        public var stress: Int?
        /// `null` | `push` | `ease` | `rest` (§11.4).
        public var override: String?

        public init(energy: Int? = nil, soreness: Int? = nil, sleepQuality: Int? = nil,
                    stress: Int? = nil, override: String? = nil) {
            self.energy = energy
            self.soreness = soreness
            self.sleepQuality = sleepQuality
            self.stress = stress
            self.override = override
        }
    }

    /// Чек-ин и оверрайд СЕГОДНЯШНЕГО дня.
    ///
    /// Оба возвращаются вместе, потому что живут в одной строке и относятся к
    /// одному дню; `Readiness.value` принимает их порознь. Строки нет —
    /// пустой чек-ин и отсутствие оверрайда: §10 трактует незаполненный
    /// чек-ин как отсутствие сигнала, а не как нули.
    public static func checkin(from row: CheckinRow?) -> (checkin: DailyCheckin, override: Override?) {
        guard let row else { return (DailyCheckin(), nil) }
        return (DailyCheckin(energy: row.energy, soreness: row.soreness,
                             sleepQuality: row.sleepQuality, stress: row.stress),
                row.override.flatMap(Override.init(rawValue:)))
    }
}
