//  Кодирование enum'ов FitCore по их `rawValue`.
//
//  Ретроактивного `extension MuscleSlug: Codable` здесь нет и не будет: это тот
//  же риск, от которого уводит весь пакет (см. doc FitAPI.swift). Конформанс,
//  объявленный снаружи модуля, к тому же конфликтует с любым будущим Codable в
//  самом FitCore. Вместо него — явный перевод через `rawValue`, одинаковый для
//  всех таких полей.

extension KeyedDecodingContainer {
    func decodeRaw<T: RawRepresentable>(_ type: T.Type, forKey key: Key) throws -> T
    where T.RawValue == String {
        let raw = try decode(String.self, forKey: key)
        guard let value = T(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "неизвестное значение «\(raw)»")
        }
        return value
    }

    func decodeRawIfPresent<T: RawRepresentable>(_ type: T.Type, forKey key: Key) throws -> T?
    where T.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "неизвестное значение «\(raw)»")
        }
        return value
    }
}

extension KeyedEncodingContainer {
    mutating func encodeRaw<T: RawRepresentable>(_ value: T, forKey key: Key) throws
    where T.RawValue == String {
        try encode(value.rawValue, forKey: key)
    }

    mutating func encodeRawIfPresent<T: RawRepresentable>(_ value: T?, forKey key: Key) throws
    where T.RawValue == String {
        try encodeIfPresent(value?.rawValue, forKey: key)
    }
}
