//  Находка валидатора. Уровней серьёзности нет намеренно: всё, что находит
//  валидатор, — это брак разметки, который §20.11 не пускает в сборку сервера.
//  «Предупреждение», которое не красит CI, через неделю никто не читает.

/// Одна ошибка разметки: где и что.
public struct Finding: Equatable, Sendable {
    /// Раздел SPEC, чьё правило нарушено, — чтобы читающий вывод CI шёл в
    /// спеку, а не в исходник валидатора.
    public let rule: String
    /// Что именно нарушено: слаг упражнения, пара вектора, комбинация.
    public let subject: String
    public let message: String

    public var line: String { "[\(rule)] \(subject): \(message)" }
}

/// Накопитель находок. Проверки не бросают исключений и не останавливаются на
/// первой ошибке: разметку правят пачкой, и список из сорока строк за один
/// прогон дешевле сорока прогонов по одной.
public final class FindingCollector {
    public private(set) var findings: [Finding] = []

    public init() {}

    public func add(rule: String, subject: String, _ message: String) {
        findings.append(Finding(rule: rule, subject: subject, message: message))
    }

    public var isEmpty: Bool { findings.isEmpty }

    /// Находки, относящиеся к правилу, — для тестов: они утверждают, ЧТО
    /// нашлось, а не сколько всего строк напечаталось.
    public func findings(rule: String) -> [Finding] {
        findings.filter { $0.rule == rule }
    }
}
