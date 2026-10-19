//  `Content` для типов `FitAPI` (SPEC §20.2).
//
//  Vapor умеет читать и писать тела только у типов, объявивших `Content`. Типы
//  границы живут в `FitAPI`, и Vapor там отсутствует по построению: тот же
//  пакет линкует iOS, которому веб-фреймворк не нужен и вреден.
//
//  Поэтому соответствие объявлено здесь — в единственном модуле, который и так
//  знает про Vapor. Это ретроактивное соответствие, и оно безопасно ровно
//  потому, что `Content` ничего не добавляет к ПРОВОЛОЧНОЙ форме: он даёт тип
//  по умолчанию (`application/json`) и точку входа кодировщика, а сама форма
//  задана вручную написанными `CodingKeys` в `FitAPI` (§20.2). Риск, от которого
//  уводит весь пакет — синтезированная форма, привязанная к именам случаев
//  Swift, — здесь не возникает: ни один из этих типов синтезированной формы не
//  имеет.
//
//  Список закрыт намеренно: соответствие получают ровно тела §20.3, и ни одного
//  типа сверх них. `ReasonDTO`, `DecisionTreeDTO` и прочие внутренности едут
//  полями этих тел и своего `Content` не требуют.

import FitAPI
import Vapor

// Запросы (§20.3).
extension GenerateWeekPlanRequest: @retroactive Content {}
extension PatchPlannedDayRequest: @retroactive Content {}
extension RebuildWeekPlanRequest: @retroactive Content {}
extension StartWorkoutRequest: @retroactive Content {}
extension LogSetRequest: @retroactive Content {}
extension SubstituteExerciseRequest: @retroactive Content {}
extension FinishWorkoutRequest: @retroactive Content {}
extension PatchProfileRequest: @retroactive Content {}
extension StartStretchSessionRequest: @retroactive Content {}
extension FinishStretchSessionRequest: @retroactive Content {}

// Ответы (§20.3).
extension WeekPlanResponseDTO: @retroactive Content {}
extension FinishWorkoutResponseDTO: @retroactive Content {}
extension ProfileDTO: @retroactive Content {}
extension TodayCardDTO: @retroactive Content {}
extension WorkoutDTO: @retroactive Content {}
extension WorkoutExerciseDTO: @retroactive Content {}
extension LogSetResponseDTO: @retroactive Content {}
extension ExerciseAlternativeDTO: @retroactive Content {}
extension StretchSessionDTO: @retroactive Content {}
extension StretchHistoryDTO: @retroactive Content {}
extension ProgressDTO: @retroactive Content {}
extension APIErrorEnvelope: @retroactive Content {}
