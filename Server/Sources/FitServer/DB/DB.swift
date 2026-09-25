//  DB/ — пул соединений и единственный вход в транзакцию (SPEC §20.4).
//
//  Второй подкаталог `Server/` с кодом. Как и `Auth/`, он не знает ни одной
//  доменной таблицы: здесь нет ни `SessionInput`, ни `Mapping/`, ни FitCore —
//  только соединение, роль, claims и уровень изоляции. Поэтому он написан
//  раньше всего, что зависит от пустого `FitContent`.
//
//  ── Что делает конвейер ────────────────────────────────────────────────────
//
//    заголовок Authorization → `Auth/` → аренда соединения из пула
//      → begin → `set transaction isolation level repeatable read`
//      → `set_config('role', …)` + `set_config('request.jwt.claims', …)`
//      → тело запроса → commit
//
//  ── Почему вход один и почему он же проверяет токен ────────────────────────
//
//  Гарантия §20.4 держится на том, что подстановка произошла ДО первого чтения.
//  Оставленная дисциплине роутов, она нарушается молча: новый роут, забывший
//  её, не падает — он читает. Поэтому арендовать соединение можно только через
//  `Database.withUserTransaction`, и он же зовёт `Auth/` сам, а не принимает
//  уже проверенный токен. Порядок «сначала проверка, потом БД» становится
//  свойством типа, а не соглашением между слоями.
//
//  Второе следствие того же выбора — проверяемость. Вторая половина 20b («до БД
//  запрос не доходит») есть утверждение о том, что соединение не арендовано ни
//  разу, а наблюдать его можно только там, где аренда происходит. Отсюда
//  `leaseCount`: счётчик живёт на боевом пути, а не в заглушке рядом с ним, и
//  20k утверждает, что он ДВИГАЕТСЯ на успешном запросе. Без этой второй
//  половины «ноль» в 20b доказывал бы только то, что счётчик не работает.
//
//  ── Роль подключения (§20.4, §3.2, миграция `0008`) ────────────────────────
//
//  Пул логинится ролью `fitserver`: `noinherit`, без собственных прав, с
//  единственным членством в `authenticated`. Владельцем таблиц входить нельзя,
//  и причина сильнее, чем кажется: у роли `postgres` в Supabase
//  `rolbypassrls = true` — она обходит §3.2 по атрибуту роли, а не по владению,
//  так что `force row level security` её бы не остановил. При входе владельцем
//  забытая подстановка вернула бы все строки всех пользователей; при входе
//  `fitserver` она даёт `permission denied` на первом же чтении.
//
//  Пароль роли — конфигурация среды, в схеме его нет. После `supabase db reset`
//  он исчезает вместе с ролью (CLI удаляет кастомные роли), и 20k обязан
//  сказать об этом внятно, а не выглядеть сломанной изоляцией.
//
//  ── Уровень изоляции ───────────────────────────────────────────────────────
//
//  `repeatable read`, и это не перестраховка. Обещание §20.4 — согласованный
//  срез входа — транзакцией по умолчанию не выполняется: в `read committed`
//  каждое утверждение берёт новый снимок, и вход, собранный пятью запросами,
//  разъезжается ровно так, как §20.4 объявляет невозможным.
//
//  Задаётся отдельным утверждением, а не в `begin`, потому что
//  `PostgresClient.withTransaction` шлёт голый `BEGIN;`. Смысл тот же:
//  `set transaction` действует, пока в транзакции не выполнено ни одного
//  запроса, — а первым идёт именно оно.
//
//  Цена — `40001`. Повтор ровно один, только на этот класс ошибки: откат при
//  `repeatable read` полон, и второй проход перечитывает вход заново. Тело
//  запроса при повторе выполняется ДВАЖДЫ — это его контракт, а не деталь.
//
//  ── Чего здесь нет ─────────────────────────────────────────────────────────
//
//  Vapor: пул и транзакция к HTTP-слою не относятся, и без него 20b и 20k
//  остаются тестами пакета. `service_role`: единственная операция, которой
//  нужны права выше пользовательских, живёт в Edge Function (§20.13).
//  Подключение прямое, не через пулер Supabase: транзакционный пулер перед
//  нашим пулом — это два пула подряд и конец долгоживущему соединению, ради
//  которого §20.13 отказался от серверлесса.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import PostgresNIO

/// Куда и чем подключается пул (§20.4).
///
/// Числа — умолчания с обоснованием, а не измерения: замер потолка
/// конкурентности принадлежит первому нагрузочному срезу, а не этому файлу.
public struct DatabaseConfiguration: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// Пароль роли — конфигурация среды (§20.4). Пустой означает, что
        /// среда не настроена, а не что роль без пароля: молчаливое
        /// подключение без пароля дало бы отказ сервера в момент первого
        /// запроса, а не при старте.
        case passwordNotConfigured
    }

    public let host: String
    public let port: Int

    /// Роль из миграции `0008`, не владелец таблиц (§3.2).
    public let username: String
    public let password: String
    public let database: String

    /// В проде обязателен, локально отсутствует — это разница конфигурации, а
    /// не кода (§20.4).
    public let tls: PostgresClient.Configuration.TLS

    /// При правиле «одно соединение на запрос» (§19.1) это и есть потолок
    /// конкурентности сервера.
    public let maximumConnections: Int

    /// Не ноль: §20.13 исключил серверлесс из-за холодного старта пула, и ноль
    /// возвращал бы его после каждого затишья.
    public let minimumConnections: Int

    /// Столько же, сколько у похода за JWKS (§20.5). Дольше ждать на
    /// критическом пути логирования подхода незачем.
    public let connectTimeout: Duration

    public init(
        host: String,
        port: Int = 5432,
        username: String = "fitserver",
        password: String,
        database: String = "postgres",
        tls: PostgresClient.Configuration.TLS,
        maximumConnections: Int = 20,
        minimumConnections: Int = 2,
        connectTimeout: Duration = .seconds(5)
    ) throws {
        guard !password.isEmpty else { throw Failure.passwordNotConfigured }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.maximumConnections = maximumConnections
        self.minimumConnections = minimumConnections
        self.connectTimeout = connectTimeout
    }

    func makeClientConfiguration() -> PostgresClient.Configuration {
        var configuration = PostgresClient.Configuration(
            host: host, port: port, username: username, password: password,
            database: database, tls: tls
        )
        configuration.options.maximumConnections = maximumConnections
        configuration.options.minimumConnections = minimumConnections
        configuration.options.connectTimeout = connectTimeout
        // `requireBackendKeyData` остаётся умолчанием `true`: снимают его ради
        // прокси вроде RDS Proxy, а мы ходим напрямую (§20.4).
        return configuration
    }
}
