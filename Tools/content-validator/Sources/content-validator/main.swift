import Foundation
import FitContent
import ContentValidator

//  Гейт CI (SPEC §20.11): библиотека, не прошедшая §6.2, §6.6 и правило
//  покрытия, не попадает в сборку сервера. Ненулевой код возврата = красный CI.
//
//  Здесь только разбор аргумента, вывод и код возврата. Сами проверки — в
//  библиотеке `ContentValidator`, и тесты у них там же: что именно проверяется,
//  перечислено в doc-комментарии `Validator`.
//
//  Читает те файлы, что лежат в репозитории, а не бандл: бандл — копия,
//  собранная сборкой, и сверять копию значило бы пропускать файл, который в
//  сборку не попал.

let defaultRelativePath = "Packages/FitContent/Sources/FitContent/Resources"

func resolveRoot() -> URL? {
    if let given = CommandLine.arguments.dropFirst().first {
        return URL(fileURLWithPath: given, isDirectory: true)
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let candidate = cwd.appendingPathComponent(defaultRelativePath)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    switch (count % 100, count % 10) {
    case (11...14, _): return many
    case (_, 1): return one
    case (_, 2...4): return few
    default: return many
    }
}

func die(_ message: String) -> Never {
    // stdout сбрасывается до записи в stderr: иначе сводка и находки
    // перемешиваются в логе CI, и непонятно, к какому прогону что относится.
    fflush(stdout)
    FileHandle.standardError.write(Data("content-validator: \(message)\n".utf8))
    exit(1)
}

guard let root = resolveRoot() else {
    die("""
        каталог контента не найден.
        Запуск: content-validator [путь-к-Resources]
        Без аргумента ожидается запуск из корня репозитория, где лежит
        \(defaultRelativePath)
        """)
}

let library: ContentLibrary
do {
    library = try Content.load(from: root)
} catch {
    // Ошибка формы — уже брак разметки, и дальше проверять нечего: часть файлов
    // не прочитана, и список находок был бы заведомо неполным.
    die("контент не загружается — \(error)")
}

let report = Validator.run(library)

print("content-validator: \(report.exerciseCount) "
      + plural(report.exerciseCount, "упражнение", "упражнения", "упражнений")
      + ", \(report.vectorCount) из \(DayVectorTable.allKeys.count) целевых векторов"
      + ", \(report.stretchCount) "
      + plural(report.stretchCount, "шаблон", "шаблона", "шаблонов") + " растяжки")

if report.coverage.builds > 0 {
    print("покрытие §20.11: \(report.coverage.builds) сборок, "
          + "\(report.coverage.passed) прошли полностью, "
          + "\(report.coverage.relaxedInDeclared) ослаблены в объявленно неполных "
          + "комбинациях (§20.11)")
}
print("консервативный режим §14.1 правилом покрытия не проверяется: осей у "
      + "правила три, и его среди них нет")

guard report.passed else {
    fflush(stdout)
    FileHandle.standardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
    die("\(report.findings.count) "
        + plural(report.findings.count, "ошибка", "ошибки", "ошибок")
        + " разметки — в сборку она не идёт")
}

print("content-validator: разметка прошла все проверки")
