//  Тренировочный блок `/v1/workouts` (SPEC §7.1, §9.3, §20.3, §20.6, §20.9).
//
//  ── Тело ответа собирается в одном месте ──────────────────────────────────
//
//  `WorkoutDTO` отдают три пути — старт, чтение и завершение, — и собирается он
//  здесь один раз. Разнесённая по обработчикам сборка разъехалась бы не
//  падением, а полем: дерево §20.9, посчитанное в двух местах по-разному, даёт
//  два разных экрана на одну и ту же тренировку.
//
//  ── Дерево строится от журнала, а не хранится ─────────────────────────────
//
//  Корень — `Mapping.treeRoot` по подходам ЭТОГО упражнения в ЭТОЙ сессии
//  (§20.9), лестница — из профиля инвентаря самой тренировки, а не текущего
//  умолчания: она могла смениться с тех пор, а веса принадлежат тому инвентарю,
//  на котором тренировка идёт.
//
//  Поле пусто ровно тогда, когда подходов не осталось (§20.3): `remaining_sets
//  = 0`, независимо от того, закрыта тренировка или нет. Привязать пустоту к
//  `finished_at` было нельзя — после досрочного завершения §9.3 у закрытой
//  тренировки остаются незакрытые подходы, а у открытой их может не остаться.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

enum WorkoutRoutes {

    static func register(on routes: any RoutesBuilder, database: Database,
                         library: ContentLibrary) {
        let workouts = routes.grouped("workouts")

        workouts.post { request async throws -> Response in
            try await start(request, database: database, library: library)
        }
        workouts.get(":id") { request async throws -> Response in
            try await show(request, database: database, library: library)
        }
    }

    // MARK: - Тело ответа

    /// `WorkoutDTO` по строке тренировки: состав, подходы и деревья.
    static func body(_ tx: UserTransaction, workout: Mapping.WorkoutRow,
                     library: ContentLibrary) async throws -> WorkoutDTO {
        guard let workoutID = UUID(uuidString: workout.id) else { throw APIError(.internal) }
        let rows = try await Mapping.readWorkoutExercises(tx, workoutID: workoutID)
        let sets = try await Mapping.readWorkoutSets(tx, workoutID: workoutID)
        // Инвентарь ТРЕНИРОВКИ, а не умолчание аккаунта: `equipment_profile_id`
        // принадлежит моменту (§20.3), и лестница дерева обязана быть его.
        let equipment = try await Mapping.readEquipment(
            tx, id: workout.equipmentProfileID.flatMap(UUID.init(uuidString:)))
        let bySlug = Dictionary(library.candidates.map { ($0.slug, $0) },
                                uniquingKeysWith: { first, _ in first })

        let exercises = rows.map { row -> WorkoutExerciseDTO in
            let body = sets.body[row.id] ?? []
            let journal = sets.journal[row.id] ?? []
            // Лестница неизвестного слага — `.none`: разметка могла уехать, и
            // выдумывать квантование под упражнение, которого в срезе нет,
            // значило бы показать веса, которых инвентарь не даёт.
            let ladder = bySlug[row.slug].map {
                WeightLadder.build(loadType: $0.loadType, profile: equipment.profile)
            } ?? .none

            var tree: DecisionTreeDTO?
            let remaining = max(0, row.targetSets - body.count)
            if remaining > 0 {
                let root = Mapping.treeRoot(sets: journal, startWeightKg: row.prescribedKg,
                                            range: row.range, isCalibration: row.isCalibration,
                                            ladder: ladder)
                // Упражнение, завершённое досрочно (§9.3), дерева не получает:
                // решать больше нечего, а узел `terminates` клиент уже видел.
                if !root.terminated {
                    tree = DecisionTree.build(
                        weightKg: root.weightKg, remainingSets: remaining, range: row.range,
                        isCalibration: row.isCalibration,
                        previousWasFailed: root.previousWasFailed,
                        calibrationIncreasesUsed: root.calibrationIncreasesUsed, ladder: ladder)
                }
            }

            return WorkoutExerciseDTO(
                id: row.id,
                prescribed: PrescribedExercise(
                    slug: row.slug, orderIndex: row.orderIndex, targetSets: row.targetSets,
                    targetRepMin: row.targetRepMin, targetRepMax: row.targetRepMax,
                    targetRIR: row.targetRIR, prescribedKg: row.prescribedKg,
                    weightReadiness: row.weightReadiness),
                isCalibration: row.isCalibration,
                substitutedFrom: row.substitutedFrom,
                substitutionReason: row.substitutionReason.flatMap(SubstitutionReason.init(rawValue:)),
                decisionTree: tree,
                sets: body)
        }

        return WorkoutDTO(
            id: workout.id, plannedDayID: workout.plannedDayID,
            sessionKind: SessionKind(rawValue: workout.sessionKind) ?? .fullBody,
            accentMuscle: workout.accentMuscle.flatMap(MuscleSlug.init(rawValue:)),
            startedAt: workout.startedAt, finishedAt: workout.finishedAt,
            readiness: workout.readiness,
            cyclePhase: workout.cyclePhase.flatMap(Phase.init(rawValue:)),
            cycleConfidence: workout.cycleConfidence,
            isCalibration: workout.isCalibration, exercises: exercises)
    }
}
