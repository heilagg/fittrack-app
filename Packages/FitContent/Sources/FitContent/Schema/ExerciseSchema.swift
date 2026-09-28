//  Одно упражнение библиотеки — схема SPEC §6.2, поле в поле.
//
//  Декодирование ручное, а не синтезированное, по трём причинам, и каждая
//  всплыла бы позже как молчаливая:
//
//  1. Словари ключуются значениями (`MuscleSlug`, `Joint`), а не строками.
//     Синтезированный Codable кодирует такой словарь МАССИВОМ пар, а не
//     объектом, — то есть не тем, что записано в §6.2.
//  2. Неизвестный слаг мышцы или сустава обязан падать с именем поля и
//     значением. Пропустить его нельзя: молча потерянный вклад в 0.20 не
//     ломает ничего видимого и смещает подбор навсегда.
//  3. `equipment` — не строки, а требования §6.6 с `machine:<слаг>` внутри.
//
//  **Чего здесь нет: проверок правил.** Сумма вкладов ≈ 1.0, полнота карты
//  суставов, слаг тренажёра из закрытого списка §6.6, резолвинг
//  `alternatives`, `family_load_ratio` в семье больше одного — всё это
//  Tools/content-validator, гейт CI (§19.1, §20.11). Здесь падает только то,
//  что невозможно ПРЕДСТАВИТЬ: неизвестное значение enum'а. Разделение не
//  стилистическое: загрузчик работает в рантайме сервера, и правило,
//  проверенное здесь, упало бы у пользовательницы посреди тренировки вместо
//  того, чтобы упасть в CI.

import FitCore

/// Упражнение библиотеки (SPEC §6.2).
public struct ExerciseSchema: Sendable, Equatable {
    public var slug: String
    public var name: String
    public var pattern: Pattern
    /// Сырые вклады, сумма ≈ 1.0 (§6.3). Проверяет сумму валидатор.
    public var muscleContributions: [MuscleSlug: Double]
    public var equipment: [EquipmentRequirement]
    /// Свободный список (§6.3): словарём §6.6 не ограничен, на выполнимость
    /// не влияет, поэтому остаётся строками.
    public var equipmentOptional: [String]
    public var loadType: LoadType
    public var unilateral: Bool
    /// Полная карта семи суставов (§6.2). Полноту проверяет валидатор;
    /// отсутствующий ключ и здесь, и в `FitCore` читается как `.none`.
    public var jointStress: [Joint: JointStressLevel]
    public var impact: ExerciseImpact
    public var skillLevel: ExperienceLevel
    public var defaultRestSeconds: Int
    public var fatigueCost: Double
    public var alternatives: [String]
    public var progressionFamily: String
    /// Обязателен в семье больше чем из одного упражнения (§6.3) — это
    /// проверяет валидатор, а не тип: по одному файлу размер семьи не виден.
    public var familyLoadRatio: Double?
    public var setupSeconds: Int
    public var cues: [String]
    public var commonErrors: [String]
    public var illustration: String

    public init(
        slug: String,
        name: String,
        pattern: Pattern,
        muscleContributions: [MuscleSlug: Double],
        equipment: [EquipmentRequirement] = [],
        equipmentOptional: [String] = [],
        loadType: LoadType,
        unilateral: Bool = false,
        jointStress: [Joint: JointStressLevel] = [:],
        impact: ExerciseImpact = .none,
        skillLevel: ExperienceLevel = .novice,
        defaultRestSeconds: Int = 90,
        fatigueCost: Double,
        alternatives: [String] = [],
        progressionFamily: String,
        familyLoadRatio: Double? = nil,
        setupSeconds: Int,
        cues: [String] = [],
        commonErrors: [String] = [],
        illustration: String
    ) {
        self.slug = slug
        self.name = name
        self.pattern = pattern
        self.muscleContributions = muscleContributions
        self.equipment = equipment
        self.equipmentOptional = equipmentOptional
        self.loadType = loadType
        self.unilateral = unilateral
        self.jointStress = jointStress
        self.impact = impact
        self.skillLevel = skillLevel
        self.defaultRestSeconds = defaultRestSeconds
        self.fatigueCost = fatigueCost
        self.alternatives = alternatives
        self.progressionFamily = progressionFamily
        self.familyLoadRatio = familyLoadRatio
        self.setupSeconds = setupSeconds
        self.cues = cues
        self.commonErrors = commonErrors
        self.illustration = illustration
    }

    /// Срез §7.5 — то, и только то, что читает планировщик. Строится один раз
    /// при загрузке: `FitCore` от `FitContent` не зависит, и срез собирает
    /// вызывающая сторона (§7.5), которой здесь и является загрузчик.
    public var candidate: ExerciseCandidate {
        ExerciseCandidate(
            slug: slug,
            pattern: pattern,
            muscleContributions: muscleContributions,
            equipment: equipment,
            jointStress: jointStress,
            impact: impact,
            skillLevel: skillLevel,
            progressionFamily: progressionFamily,
            familyLoadRatio: familyLoadRatio,
            fatigueCost: fatigueCost,
            setupSeconds: setupSeconds,
            defaultRestSeconds: defaultRestSeconds,
            unilateral: unilateral,
            loadType: loadType,
            alternatives: alternatives
        )
    }
}

// MARK: - Декодирование

extension ExerciseSchema: Decodable {
    private enum Key: String, CodingKey {
        case slug, name, pattern
        case muscleContributions = "muscle_contributions"
        case equipment
        case equipmentOptional = "equipment_optional"
        case loadType = "load_type"
        case unilateral
        case jointStress = "joint_stress"
        case impact
        case skillLevel = "skill_level"
        case defaultRestSeconds = "default_rest_seconds"
        case fatigueCost = "fatigue_cost"
        case alternatives
        case progressionFamily = "progression_family"
        case familyLoadRatio = "family_load_ratio"
        case setupSeconds = "setup_seconds"
        case cues
        case commonErrors = "common_errors"
        case illustration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)

        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decodeRaw(Pattern.self, forKey: .pattern)
        muscleContributions = try c.decodeKeyed(MuscleSlug.self, Double.self,
                                                forKey: .muscleContributions)
        equipment = try c.decodeIfPresent([String].self, forKey: .equipment)?
            .map { try ContentFormat.requirement(from: $0, in: c, forKey: .equipment) } ?? []
        equipmentOptional = try c.decodeIfPresent([String].self, forKey: .equipmentOptional) ?? []
        loadType = try c.decodeRaw(LoadType.self, forKey: .loadType)
        unilateral = try c.decodeIfPresent(Bool.self, forKey: .unilateral) ?? false
        jointStress = try c.decodeKeyed(Joint.self, JointStressLevel.self, forKey: .jointStress)
        impact = try c.decodeRaw(ExerciseImpact.self, forKey: .impact)
        skillLevel = try c.decodeRaw(ExperienceLevel.self, forKey: .skillLevel)
        // Дефолт 90 с — §19.2 п.3, закрытый пункт: разметка поднимает его там,
        // где есть причина, и опускает на изоляции.
        defaultRestSeconds = try c.decodeIfPresent(Int.self, forKey: .defaultRestSeconds) ?? 90
        fatigueCost = try c.decode(Double.self, forKey: .fatigueCost)
        alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        progressionFamily = try c.decode(String.self, forKey: .progressionFamily)
        familyLoadRatio = try c.decodeIfPresent(Double.self, forKey: .familyLoadRatio)
        setupSeconds = try c.decode(Int.self, forKey: .setupSeconds)
        cues = try c.decodeIfPresent([String].self, forKey: .cues) ?? []
        commonErrors = try c.decodeIfPresent([String].self, forKey: .commonErrors) ?? []
        illustration = try c.decode(String.self, forKey: .illustration)
    }
}

/// Разбор значений, у которых форма §6.2 не совпадает с формой типа `FitCore`.
enum ContentFormat {
    /// Требование инвентаря из строки словаря §6.6.
    ///
    /// Слаг тренажёра здесь НЕ сверяется с закрытым списком §6.6: `machine:leg_pres`
    /// с опечаткой представим, и ловит его валидатор. Непредставимо только
    /// значение вне словаря целиком — на нём и падаем.
    static func requirement<K: CodingKey>(
        from raw: String,
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> EquipmentRequirement {
        switch raw {
        case "bench_flat": return .benchFlat
        case "bench_adjustable": return .benchAdjustable
        case "pullup_bar": return .pullupBar
        case "bands": return .bands
        case "kettlebells": return .kettlebells
        case "cable_machine": return .cableMachine
        case "step_platform": return .stepPlatform
        case "plyo_box": return .plyoBox
        default:
            let prefix = "machine:"
            guard raw.hasPrefix(prefix), raw.count > prefix.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "значение вне словаря инвентаря §6.6: «\(raw)»")
            }
            return .machine(String(raw.dropFirst(prefix.count)))
        }
    }
}

extension KeyedDecodingContainer {
    /// Значение enum'а по его `rawValue`, с именем поля в ошибке.
    /// `Decodable` от типа не требуется и не может требоваться: типы `FitCore`
    /// его не объявляют — ядро не знает ни про JSON, ни про проводной формат.
    func decodeRaw<T: RawRepresentable>(
        _ type: T.Type, forKey key: Key
    ) throws -> T where T.RawValue == String {
        let raw = try decode(String.self, forKey: key)
        guard let value = T(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "неизвестное значение «\(raw)» для \(T.self)")
        }
        return value
    }

    /// Словарь, ключуемый значением enum'а. Синтезированный Codable дал бы
    /// здесь массив пар, а §6.2 записывает объект.
    func decodeKeyed<RawKey: RawRepresentable & Hashable, V: Decodable>(
        _ keyType: RawKey.Type, _ valueType: V.Type, forKey key: Key
    ) throws -> [RawKey: V] where RawKey.RawValue == String {
        let raw = try decodeIfPresent([String: V].self, forKey: key) ?? [:]
        var result: [RawKey: V] = [:]
        for (rawKey, value) in raw {
            result[try typed(RawKey.self, rawKey, forKey: key)] = value
        }
        return result
    }

    /// То же, но и значение — enum по `rawValue`: `joint_stress` отображает
    /// сустав в степень, и ни один из двух типов `FitCore` не `Decodable`.
    func decodeKeyed<RawKey: RawRepresentable & Hashable, RawValue: RawRepresentable>(
        _ keyType: RawKey.Type, _ valueType: RawValue.Type, forKey key: Key
    ) throws -> [RawKey: RawValue] where RawKey.RawValue == String, RawValue.RawValue == String {
        let raw = try decodeIfPresent([String: String].self, forKey: key) ?? [:]
        var result: [RawKey: RawValue] = [:]
        for (rawKey, rawValue) in raw {
            guard let value = RawValue(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: self,
                    debugDescription: "неизвестное значение «\(rawValue)» для \(RawValue.self)")
            }
            result[try typed(RawKey.self, rawKey, forKey: key)] = value
        }
        return result
    }

    private func typed<RawKey: RawRepresentable>(
        _ type: RawKey.Type, _ raw: String, forKey key: Key
    ) throws -> RawKey where RawKey.RawValue == String {
        guard let value = RawKey(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "неизвестный ключ «\(raw)» для \(RawKey.self)")
        }
        return value
    }
}
