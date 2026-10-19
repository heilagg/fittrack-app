//  Картинки упражнений (SPEC §6.5): сопоставление слага с каталогом
//  free-exercise-db и ключ `illustration`, который из него следует.
//
//  Разметка упражнений не меняется: ключ подставляет загрузчик. Найденному
//  слагу — `catalog/<match>/<слаг>`, ненайденному остаётся заглушка
//  `placeholder/…` из его файла. Так «картинки нет» по-прежнему видно и в
//  разметке, и в ответе API.

import Foundation

/// Файл `Resources/illustrations.json`.
public struct IllustrationMap: Sendable, Equatable, Decodable {
    public enum Match: String, Sendable, Equatable, Decodable {
        /// То же движение и тот же снаряд.
        case exact
        /// То же движение, снаряд на картинке другой.
        case close
    }

    public struct Entry: Sendable, Equatable, Decodable {
        /// Идентификатор упражнения в каталоге.
        public var id: String
        public var match: Match
        /// Кадры каталога идут финишем вперёд; выгрузка их меняет местами.
        public var reversed: Bool

        enum CodingKeys: String, CodingKey { case id, match, reversed }

        public init(id: String, match: Match, reversed: Bool = false) {
            self.id = id
            self.match = match
            self.reversed = reversed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            match = try c.decode(Match.self, forKey: .match)
            reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        }
    }

    public var exercises: [String: Entry]
    /// Позы растяжки и кардио (§12.3): тот же каталог и те же правила (§6.5).
    public var poses: [String: Entry]

    enum CodingKeys: String, CodingKey { case exercises, poses }

    public init(exercises: [String: Entry], poses: [String: Entry] = [:]) {
        self.exercises = exercises
        self.poses = poses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exercises = try c.decode([String: Entry].self, forKey: .exercises)
        poses = try c.decodeIfPresent([String: Entry].self, forKey: .poses) ?? [:]
    }

    /// Ключ `illustration` найденного слага (§6.5).
    public static func key(slug: String, match: Match) -> String {
        "catalog/\(match.rawValue)/\(slug)"
    }

    /// Упражнения с подставленным ключом. Слаг сопоставления, которого нет в
    /// библиотеке, — ошибка: картинка для него никуда бы не попала, и
    /// опечатка в слаге осталась бы незамеченной.
    public func applied(to exercises: [ExerciseSchema]) throws -> [ExerciseSchema] {
        let known = Set(exercises.map(\.slug))
        if let unknown = self.exercises.keys.sorted().first(where: { !known.contains($0) }) {
            throw ContentError.malformedFile(path: "illustrations.json",
                                             reason: "слага «\(unknown)» нет среди упражнений")
        }
        return exercises.map { exercise in
            guard let entry = self.exercises[exercise.slug] else { return exercise }
            var copy = exercise
            copy.illustration = Self.key(slug: exercise.slug, match: entry.match)
            return copy
        }
    }

    /// Позы с подставленным ключом — то же правило, что у упражнений.
    public func applied(to poses: [PoseSchema]) throws -> [PoseSchema] {
        let known = Set(poses.map(\.slug))
        if let unknown = self.poses.keys.sorted().first(where: { !known.contains($0) }) {
            throw ContentError.malformedFile(path: "illustrations.json",
                                             reason: "слага «\(unknown)» нет среди поз")
        }
        return poses.map { pose in
            guard let entry = self.poses[pose.slug] else { return pose }
            var copy = pose
            copy.illustration = Self.key(slug: pose.slug, match: entry.match)
            return copy
        }
    }
}
