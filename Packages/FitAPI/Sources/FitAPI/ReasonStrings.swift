//  Каталог русских формулировок (SPEC §20.3, §13.5, §14.6).
//
//  Живёт в FitAPI, а не в Server/, по той же причине, что и DTO: iOS в офлайне
//  (§4.3) обязан читать тот же каталог, а не писать второй. Расхождение двух
//  каталогов было бы тихим и чинилось бы релизом в App Store.
//
//  Тон (§13.5): без морализаторства, без восклицательных знаков, без счётчика
//  провалов; объяснения конкретны — не «сегодня полегче», а «ягодичные ещё не
//  восстановились».
//
//  Правило §14.6 и §11.3 соблюдается здесь, а не в клиенте: при уверенности
//  ниже 0.3 фаза НЕ НАЗЫВАЕТСЯ. Порог не влияет на расчёт — он определяет,
//  вправе ли интерфейс вообще назвать фазу, а утверждение о теле
//  пользовательницы на слабом сигнале строить нельзя. `cycle_confidence` при
//  этом всё равно едет в `params`: клиент обязан им воспользоваться и подать
//  рекомендацию тем осторожнее, чем ниже уверенность, и готовая строка его от
//  этого не освобождает.

import FitCore

public enum ReasonStrings {

    /// §11.3: ниже этого порога фазу называть нельзя.
    public static let phaseNamingThreshold = 0.3

    // MARK: - Словарь

    /// Форма «по <мышце>»: «выйдет меньше по ягодичным».
    public static func dative(_ muscle: MuscleSlug) -> String {
        switch muscle {
        case .gluteMax: return "ягодичным"
        case .gluteMed: return "средним ягодичным"
        case .quads: return "квадрицепсу"
        case .hamstrings: return "бицепсу бедра"
        case .adductors: return "приводящим"
        case .calves: return "икрам"
        case .erectors: return "разгибателям спины"
        case .lats: return "широчайшим"
        case .trapsMid: return "средним трапециевидным"
        case .trapsUpper: return "верхним трапециевидным"
        case .rearDelts: return "задним дельтам"
        case .sideDelts: return "средним дельтам"
        case .frontDelts: return "передним дельтам"
        case .pecs: return "грудным"
        case .biceps: return "бицепсу"
        case .triceps: return "трицепсу"
        case .forearms: return "предплечьям"
        case .abs: return "прессу"
        case .obliques: return "косым"
        }
    }

    /// Форма «на <мышцу>»: «тот же акцент на ягодичные».
    public static func accusative(_ muscle: MuscleSlug) -> String {
        switch muscle {
        case .gluteMax: return "ягодичные"
        case .gluteMed: return "средние ягодичные"
        case .quads: return "квадрицепс"
        case .hamstrings: return "бицепс бедра"
        case .adductors: return "приводящие"
        case .calves: return "икры"
        case .erectors: return "разгибатели спины"
        case .lats: return "широчайшие"
        case .trapsMid: return "средние трапециевидные"
        case .trapsUpper: return "верхние трапециевидные"
        case .rearDelts: return "задние дельты"
        case .sideDelts: return "средние дельты"
        case .frontDelts: return "передние дельты"
        case .pecs: return "грудные"
        case .biceps: return "бицепс"
        case .triceps: return "трицепс"
        case .forearms: return "предплечья"
        case .abs: return "пресс"
        case .obliques: return "косые"
        }
    }

    /// Форма «на <сустав>»: «без нагрузки на колено».
    public static func accusative(_ joint: Joint) -> String {
        switch joint {
        case .knee: return "колено"
        case .lowerBack: return "поясницу"
        case .shoulder: return "плечо"
        case .wrist: return "запястье"
        case .neck: return "шею"
        case .hip: return "бедро"
        case .ankle: return "голеностоп"
        }
    }

    /// Форма «в <фазе>»: «многие отмечают спад в поздней лютеиновой фазе».
    public static func prepositional(_ phase: Phase) -> String {
        switch phase {
        case .menstrual: return "менструальной фазе"
        case .follicular: return "фолликулярной фазе"
        case .ovulatory: return "овуляторной фазе"
        case .earlyLuteal: return "ранней лютеиновой фазе"
        case .lateLuteal: return "поздней лютеиновой фазе"
        }
    }

    public static func name(_ kind: SessionKind) -> String {
        switch kind {
        case .fullBody: return "всё тело"
        case .upper: return "верх"
        case .lower: return "низ"
        case .push: return "жимовой день"
        case .pull: return "тяговый день"
        case .rest: return "отдых"
        case .stretch: return "растяжка"
        }
    }

    /// «подход» / «подхода» / «подходов».
    public static func sets(_ n: Int) -> String {
        let abs = Swift.abs(n)
        if abs % 100 / 10 == 1 { return "\(n) подходов" }
        switch abs % 10 {
        case 1: return "\(n) подход"
        case 2, 3, 4: return "\(n) подхода"
        default: return "\(n) подходов"
        }
    }

    /// «упражнение» / «упражнения» / «упражнений».
    static func exercises(_ n: Int) -> String {
        let abs = Swift.abs(n)
        if abs % 100 / 10 == 1 { return "\(n) упражнений" }
        switch abs % 10 {
        case 1: return "\(n) упражнение"
        case 2, 3, 4: return "\(n) упражнения"
        default: return "\(n) упражнений"
        }
    }

    // MARK: - Причины

    public static func message(for reason: ReasonCode) -> String {
        switch reason {
        case .phasePeriodization(let phase, let confidence):
            // §14.6: подаём как предположение, не как медицинский факт; при
            // низкой уверенности фазу не называем вовсе (§11.3).
            guard confidence >= phaseNamingThreshold else {
                return "Пока предлагаем работать чуть легче — если чувствуете себя иначе, скажите нам"
            }
            return "Многие отмечают спад в \(prepositional(phase)) — предлагаем работать чуть легче. "
                + "Если чувствуете себя иначе, скажите нам"

        case .ovulatoryImpactCaution(let confidence):
            guard confidence >= phaseNamingThreshold else {
                return "Заменили часть прыжковых упражнений — если хотите, верните их"
            }
            return "В овуляторной фазе некоторые предпочитают меньше прыжковых движений. "
                + "Заменили часть — если хотите, верните их"

        case .patternMinimumRelaxedUnavailable(let available):
            return "На вашем инвентаре и с текущими ограничениями доступно "
                + "\(patterns(available)) движения из нужных — собрали из того, что есть"

        case .patternMinimumRelaxedByTime(let fitted):
            return "В отведённое время поместилось \(patterns(fitted)) — "
                + "добавьте минут в настройках, если хотите больше"

        case .patternMinimumRelaxedByLimit(let fitted, let limit):
            switch limit {
            case .exerciseCount:
                return "Поместилось \(patterns(fitted)): тренировка уже набрала "
                    + "\(exercises(Planner.maxExercises))"
            case .family:
                return "Поместилось \(patterns(fitted)): на остальные движения "
                    + "подходят только упражнения, которые уже в тренировке"
            }

        case .planRebuilt(let cause):
            return "План обновлён: \(message(for: cause))"

        case .plannedVolumeLoss(let muscle, let sets, let cause):
            return "На этой неделе выйдет на \(self.sets(sets)) меньше по \(dative(muscle)): \(phrase(cause))"

        case .weekShortfallByTime(let muscle, let sets):
            return "До конца недели выйдет на \(self.sets(sets)) меньше по \(dative(muscle)): "
                + "не помещается в отведённое время"

        case .workoutGenerationDisabled:
            return "Подбор тренировок выключен. Мы не составляем программы для беременности — "
                + "здесь нужен специалист, который вас наблюдает"

        case .noFeasibleExercises:
            return "На этом инвентаре и с текущими ограничениями подходящих упражнений не нашлось"

        case .dayVectorMissing(let kind, let accent):
            let day = accent.map { "\(name(kind)) с акцентом на \(accusative($0))" } ?? name(kind)
            return "Не смогли собрать день «\(day)» — это ошибка в нашей разметке, а не в ваших настройках"

        case .substitutionKeepsLeadingMuscle(let muscle):
            return "Тот же акцент на \(accusative(muscle))"

        case .substitutionRelievesJoint(let joint, _, let to):
            return to == nil
                ? "Без нагрузки на \(accusative(joint))"
                : "Меньше нагрузки на \(accusative(joint))"
        }
    }

    public static func message(for cause: RebuildCause) -> String {
        switch cause {
        case .phaseChanged(let phase, let confidence):
            guard let phase, let confidence, confidence >= phaseNamingThreshold else {
                return "изменилось состояние цикла"
            }
            return "началась \(nominative(phase))"
        case .cycleConfidenceChanged:
            return "уточнился прогноз цикла"
        case .workoutSkipped:
            return "тренировка пропущена"
        case .workoutCompleted:
            return "тренировка выполнена"
        case .override:
            return "вы изменили настрой на сегодня"
        case .dayEdited:
            return "вы изменили этот день"
        case .equipmentChanged:
            return "изменился инвентарь"
        }
    }

    static func nominative(_ phase: Phase) -> String {
        switch phase {
        case .menstrual: return "менструальная фаза"
        case .follicular: return "фолликулярная фаза"
        case .ovulatory: return "овуляторная фаза"
        case .earlyLuteal: return "ранняя лютеиновая фаза"
        case .lateLuteal: return "поздняя лютеиновая фаза"
        }
    }

    static func patterns(_ n: Int) -> String {
        let abs = Swift.abs(n)
        if abs % 100 / 10 == 1 { return "\(n) разных" }
        switch abs % 10 {
        case 1: return "\(n) разное"
        case 2, 3, 4: return "\(n) разных"
        default: return "\(n) разных"
        }
    }

    /// Причина потери планового объёма — §13.5 требует констатации без
    /// счётчика провалов и без упрёка.
    static func phrase(_ cause: DayOutcome.Cause) -> String {
        switch cause {
        case .skipped: return "день пропущен"
        case .restOverride: return "сегодня вы выбрали отдых"
        case .replaced: return "день заменён"
        case .started: return "день уже начат"
        case .done: return "день выполнен"
        case .past: return "день прошёл"
        case .gridStretch: return "в этот день растяжка"
        case .markupMissing: return "не удалось собрать день"
        case .pregnancy: return "подбор тренировок выключен"
        }
    }

    // MARK: - Ошибки

    public static func message(for code: APIErrorCode) -> String {
        switch code {
        case .unauthorized: return "Нужно войти заново"
        case .jwksUnavailable: return "Сервер входа временно недоступен, попробуйте через минуту"
        case .forbidden: return "Нет доступа к этим данным"
        case .notFound: return "Не найдено"
        case .dateSkew: return "Дата на устройстве сильно расходится с нашей — проверьте часы"
        case .validationFailed: return "Запрос не прошёл проверку"
        case .weekExists: return "Эта неделя уже сгенерирована"
        case .setIDRequired: return "Подход отправлен без идентификатора"
        case .setImmutable: return "Завершённый подход изменить нельзя"
        case .workoutNotStarted: return "Тренировка не начата"
        case .workoutFinished: return "Тренировка уже завершена"
        case .dayNotPlanned: return "Этот день уже закрыт"
        case .generatorDisabled: return "Подбор тренировок выключен"
        case .internal: return "Что-то пошло не так с нашей стороны"
        }
    }
}
