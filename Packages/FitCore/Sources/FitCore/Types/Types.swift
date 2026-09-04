//  Types — базовые значимые типы предметной области.
//
//  Здесь живут: MuscleSlug, Pattern, LoadType, Feedback, Phase, Goal,
//  ExperienceLevel, ReasonCode, а также собственные CalendarDay/Timestamp.
//
//  Почему свои дата-типы, а не Foundation.Date/Calendar: тесты фаз цикла
//  (SPEC §11) и детренированности (SPEC §9.7) иначе плавают от часового
//  пояса и перехода на летнее время.
//
//  ReasonCode — enum кодов причин. Русские формулировки живут в
//  App/FitTrack/Localization, не здесь.
//
//  Остальные типы добавляются по мере реализации соответствующих модулей.
//  LoadType понадобился первым — как зависимость Equipment/WeightLadder.

/// Способ округления/квантования веса упражнения (SPEC §6.3).
public enum LoadType: String, Sendable, Equatable, Hashable, CaseIterable {
    case bodyweight
    case bodyweightLoaded = "bodyweight_loaded"
    case dumbbell
    case barbell
    case machine
    case cable
    case band
    case kettlebell
}
