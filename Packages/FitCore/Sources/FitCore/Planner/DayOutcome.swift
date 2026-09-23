//  Что планировщик сделал с днём недели — один источник статуса дня для всех,
//  кто считает неделю (SPEC §7.1).
//
//  До этого типа статус дня читали четверо и каждый по-своему: сборка
//  (`planned` + дата + начатость + оверрайд), строка потерь (только `skipped`),
//  строка «План обновлён» (по наличию дня в словаре сессий) и `S_эфф`
//  (намеренно игнорирует статус: знаменатель — все запланированные сессии,
//  §7.3). Из-за этого день, заменённый оверрайдом `rest`, собирался правильно,
//  но для недельного учёта не существовал: объём терялся молча.
//
//  Теперь решение принимает `Planner.classify` один раз, а `WeekPlan`,
//  `weekLostVolume` и `rebuildNotice` только читают его результат. `S_эфф`
//  по-прежнему считается от сетки и статуса не знает — это не учёт потерь, а
//  масштаб недели.

/// Итог дня недели: что с ним стало и потерян ли его плановый объём.
public struct DayOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Тренировка собрана (день не начат, дата не в прошлом).
        case session
        /// Вместо силовой — растяжка: день сетки §7.2 или оверрайд `rest`.
        case stretching
        /// Планировщик день не трогает: выполнен, начат, в прошлом, пропущен.
        case notBuilt
        /// Силовой день без целевого вектора — дыра в разметке (§7.3, правило 4).
        case vectorMissing
        /// Генератор тренировок выключен целиком (§14.3, беременность).
        case generatorDisabled
    }

    public enum Cause: Sendable, Equatable {
        case restOverride
        case skipped
        case replaced
        case started
        case done
        case past
        case gridStretch
        case markupMissing
        case pregnancy
    }

    public var dayID: String
    public var kind: Kind
    public var cause: Cause?
    /// Плановый объём дня потерян: пропуск, оверрайд `rest`, замена. Знаменатель
    /// `S_эфф` при этом не меняется (§7.3), поэтому неделя выходит легче — и
    /// строка статуса обязана это сказать (§7.1).
    public var losesPlannedVolume: Bool
    public var session: BuiltSession?

    /// Публичный — чтобы итог дня можно было ВОССТАНОВИТЬ снаружи: снимок
    /// показанного плана (SPEC §20.6, `week_plans.last_shown_plan`) лежит в
    /// `jsonb`, а `Planner.rebuildNotice` принимает значения этого типа.
    /// Сам планировщик строит итог через `classify`, а не через этот вызов.
    public init(dayID: String, kind: Kind, cause: Cause?, losesPlannedVolume: Bool,
                session: BuiltSession?) {
        self.dayID = dayID
        self.kind = kind
        self.cause = cause
        self.losesPlannedVolume = losesPlannedVolume
        self.session = session
    }
}

extension Planner {
    /// Единственное место, где решается судьба дня.
    ///
    /// **Порядок веток несущий**: он решает, какая из двух подходящих причин
    /// выигрывает, и один раз его уже ломали — проверка «день в прошлом» стояла
    /// раньше `skipped`, и пропущенный вчера день переставал считаться потерей
    /// объёма. Добавляя ветку, вставляйте её в этот список осознанно, а не «в
    /// конец»:
    ///
    /// 1. `done` — выполнен: не трогаем ни при каких оверрайдах (§7.1).
    /// 2. `skipped` — пропущен: объём потерян, и дата тут ни при чём.
    /// 3. `started` — начат: правило неприкосновенности §7.1.
    /// 4. `stretch`/`rest` в сетке — растяжка по §7.2.
    /// 5. Нет целевого вектора — дыра в разметке (§7.3, правило 4).
    /// 6. Беременность — генератор выключен целиком (§14.3).
    /// 7. Оверрайд `rest` на сегодня — растяжка вместо тренировки (§11.4);
    ///    раньше отметки `replaced`, чтобы уже отмеченный день всё равно
    ///    показывался растяжкой.
    /// 8. `replaced` — заменён: объём потерян так же, как при пропуске.
    /// 9. День в прошлом со статусом `planned` — не трогаем и потерей не считаем.
    /// 10. Всё остальное — сборка.
    static func classify(day: PlannedDay, ctx: WeekContext) -> DayOutcome {
        func outcome(_ kind: DayOutcome.Kind, _ cause: DayOutcome.Cause?, lost: Bool = false) -> DayOutcome {
            DayOutcome(dayID: day.id, kind: kind, cause: cause, losesPlannedVolume: lost, session: nil)
        }

        // Сначала факты исполнения — они не зависят от календаря: пропуск
        // вчерашнего дня теряет объём так же, как пропуск сегодняшнего, и
        // проверка «день в прошлом» не должна была их перехватывать.
        if day.status == .done { return outcome(.notBuilt, .done) }
        if day.status == .skipped { return outcome(.notBuilt, .skipped, lost: true) }
        if ctx.startedDayIDs.contains(day.id) { return outcome(.notBuilt, .started) }

        if day.kind == .stretch || day.kind == .rest { return outcome(.stretching, .gridStretch) }

        // §14.3: генератор выключен. Не «пустая тренировка» и не потеря объёма —
        // отдельный итог с причиной, чтобы это было видно и тому, кто читает
        // только план недели.
        if ctx.cycle.profile.noPhaseReason == .pregnancy { return outcome(.generatorDisabled, .pregnancy) }

        // Силовой день, у которого вектора нет: собирать не из чего, но и тихо
        // пропускать нельзя — иначе ошибка разметки неотличима от дня отдыха.
        if day.vector.allSatisfy({ $0.value <= 0 }) { return outcome(.vectorMissing, .markupMissing) }

        // Оверрайд `rest` живёт один день и решается здесь, а не ожиданием
        // отметки `replaced` от вызывающей стороны (§7.1, §11.4). Проверяется
        // раньше самой отметки: когда она уже проставлена, сегодняшний день всё
        // равно идёт растяжкой, а не просто «не собран».
        if day.date == ctx.today, ctx.todayOverride == .rest {
            return outcome(.stretching, .restOverride, lost: true)
        }
        if day.status == .replaced { return outcome(.notBuilt, .replaced, lost: true) }

        // День в прошлом со статусом `planned` — не отмеченный ни выполненным,
        // ни пропущенным: планировщик его не трогает и потерей не считает,
        // отметку ставит вызывающая сторона (§3.1, `planned_days.status`).
        if day.date < ctx.today { return outcome(.notBuilt, .past) }

        return outcome(.session, nil)
    }
}
