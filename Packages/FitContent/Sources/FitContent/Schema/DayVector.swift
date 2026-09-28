//  Таблица целевых векторов (SPEC §7.3) — вторая половина контента, наравне с
//  библиотекой.
//
//  Почему отдельным файлом от упражнений, а не полем в них: вектор клиенту не
//  отдаётся вовсе — это вход планировщика на сервере. Попав в байты
//  `/v1/content/exercises`, он отдал бы наружу внутренности подбора и связал бы
//  `ETag` библиотеки с правкой вектора (§20.11).
//
//  Ключ — пара (тип дня, акцент), и вектор пары задаётся целиком: правила
//  «акцент преобразует базовый вектор» нет (§7.3 п.3). Пар сто (§20.11): пять
//  типов дня, несущих вектор, на 19 мышц §6.4 плюс «без акцента».
//
//  Правила §7.3 (доли неотрицательны, сумма ≈ 1.0, у вектора с акцентом доля
//  акцентной мышцы наибольшая, вектор есть у каждой пары) проверяет валидатор,
//  а не этот тип — по тому же разделению, что у `ExerciseSchema`.

import FitCore

/// Пара (тип дня, акцент) — ключ таблицы §7.3.
public struct DayVectorKey: Sendable, Equatable, Hashable {
    public var kind: SessionKind
    /// `nil` — день без акцента, полноправный ключ, а не отсутствие ключа.
    public var accent: MuscleSlug?

    public init(kind: SessionKind, accent: MuscleSlug? = nil) {
        self.kind = kind
        self.accent = accent
    }
}

/// Строка таблицы: пара и её доли по мышцам.
public struct DayVector: Sendable, Equatable {
    public var key: DayVectorKey
    public var shares: [MuscleSlug: Double]

    public init(key: DayVectorKey, shares: [MuscleSlug: Double]) {
        self.key = key
        self.shares = shares
    }
}

extension DayVector: Decodable {
    private enum Key: String, CodingKey {
        case kind = "session_kind"
        case accent = "accent_muscle"
        case shares
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decodeRaw(SessionKind.self, forKey: .kind)
        var accent: MuscleSlug?
        if let raw = try c.decodeIfPresent(String.self, forKey: .accent) {
            guard let muscle = MuscleSlug(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .accent, in: c,
                    debugDescription: "неизвестный слаг акцента «\(raw)»")
            }
            accent = muscle
        }
        key = DayVectorKey(kind: kind, accent: accent)
        shares = try c.decodeKeyed(MuscleSlug.self, Double.self, forKey: .shares)
    }
}

/// Готовая таблица с доступом по паре.
public struct DayVectorTable: Sendable, Equatable {
    public let vectors: [DayVectorKey: [MuscleSlug: Double]]

    public init(_ rows: [DayVector]) {
        var table: [DayVectorKey: [MuscleSlug: Double]] = [:]
        for row in rows { table[row.key] = row.shares }
        vectors = table
    }

    /// Вектор пары либо `nil` — дыра в разметке. Планировщик на неё отвечает
    /// `ReasonCode.dayVectorMissing` и день не собирает (§7.3); ловить её
    /// раньше — работа валидатора.
    public func vector(kind: SessionKind, accent: MuscleSlug? = nil) -> [MuscleSlug: Double]? {
        vectors[DayVectorKey(kind: kind, accent: accent)]
    }

    /// Типы дня, которые несут вектор (§7.2): `rest` и `stretch` вектора не
    /// имеют, и пары с ними в таблице не бывает.
    public static let vectorBearingKinds: [SessionKind] =
        [.fullBody, .upper, .lower, .push, .pull]

    /// Все сто пар §20.11 — то, что обязана покрыть разметка и проверить
    /// приёмка. Порядок детерминирован: типы в порядке объявления, акценты —
    /// «без акцента», затем мышцы в порядке `MuscleSlug`.
    public static var allKeys: [DayVectorKey] {
        vectorBearingKinds.flatMap { kind in
            [DayVectorKey(kind: kind, accent: nil)]
                + MuscleSlug.allCases.map { DayVectorKey(kind: kind, accent: $0) }
        }
    }
}
