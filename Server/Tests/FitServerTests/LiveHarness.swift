//  Обвяз живых тестов недельного блока (SPEC §20.15).
//
//  Всё, что 20a, 20d и 20j требуют и чего не даёт `swift test` сам по себе:
//  поднятый сервер, настоящие JWT двух пользователей, живой Postgres с
//  применёнными миграциями и включённой RLS.
//
//  ── Запуск ─────────────────────────────────────────────────────────────────
//
//  Одной командой — `Server/scripts/live-tests.sh` (окружение, все переменные
//  и `FITTRACK_REQUIRE_LIVE=1`, см. `LiveRequiredGuard`). Руками:
//
//    supabase start && supabase migration up --local
//    psql ... -c "alter role fitserver with password 'fitserver'"
//
//    FITTRACK_LIVE_ISSUER=http://127.0.0.1:54321/auth/v1 \
//    FITTRACK_ANON_KEY=<publishable key из `supabase status`> \
//    FITTRACK_DB_PASSWORD=fitserver \
//    FITTRACK_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY из `supabase status -o env`> \
//    swift test
//
//  `FITTRACK_SERVICE_ROLE_KEY` нужен только тестам, которые стартуют
//  тренировку: привязанных пользователей (`signUpLinked`) заводит Auth Admin
//  API. Без него такие тесты ПАДАЮТ, а не пропускаются: тихо зелёный набор без
//  гейта хуже красного. Ключ меняется при каждом `supabase start`.
//
//  Без переменных набор пропускается: `swift test` обязан оставаться зелёным
//  без Docker (§20.4, server-domain §4). Пароль роли — конфигурация среды, а не
//  схема (§20.4), и после `supabase db reset` его нужно задать заново: CLI
//  пересоздаёт кастомные роли без пароля.
//
//  ── Посев идёт через границу, а не мимо неё ───────────────────────────────
//
//  Профиль ставится `PATCH /v1/profile` — тем же путём, которым его поставит
//  онбординг §5. Раньше здесь был прямой SQL от `postgres`, потому что пути не
//  существовало; он снят, и это не косметика: посев мимо границы означал, что
//  тесты проверяют сервер на состоянии, которого сервер сам создать не умеет.
//
//  Обход остался ровно один и другого рода — `equipment_profiles`,
//  `user_restrictions` и `parq_responses` фронтенд пишет НАПРЯМУЮ (§20.6), и
//  пути к ним нет и не будет. Для теста это тот же прямой SQL, но он повторяет
//  то, что делает клиент, а не обходит его.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
// Под Linux `URLSession` живёт в FoundationNetworking, а `Foundation` выше не
// импортируется вовсе, если есть FoundationEssentials. Обвязка ходит в
// Supabase Auth по HTTP, и без этого импорта тесты под Linux не собираются.
#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
#endif
import FitAPI
import FitContent
import FitCore
import Logging
import PostgresNIO
import Testing
import Vapor
import VaporTesting
@testable import FitServer

enum Live {
    static let issuer = ProcessInfo.processInfo.environment["FITTRACK_LIVE_ISSUER"]
    static let anonKey = ProcessInfo.processInfo.environment["FITTRACK_ANON_KEY"]
    static let dbPassword = ProcessInfo.processInfo.environment["FITTRACK_DB_PASSWORD"]
    /// Ключ `service_role` ЛОКАЛЬНОГО Supabase (`supabase status -o env`,
    /// `SERVICE_ROLE_KEY`). Нужен одному: создавать привязанных пользователей
    /// через Auth Admin API (`signUpLinked`). Сервер им не пользуется (§20.4).
    static let serviceKey = ProcessInfo.processInfo.environment["FITTRACK_SERVICE_ROLE_KEY"]
    static let dbHost = ProcessInfo.processInfo.environment["FITTRACK_DB_HOST"] ?? "127.0.0.1"
    static let dbPort = Int(ProcessInfo.processInfo.environment["FITTRACK_DB_PORT"] ?? "54322") ?? 54322

    static var enabled: Bool { issuer != nil && anonKey != nil && dbPassword != nil }

    // MARK: - Обязательный прогон

    /// `FITTRACK_REQUIRE_LIVE=1`: живые тесты обязаны пройти, а не пропуститься.
    ///
    /// Без переменных набор молча зелёный (шапка файла) — это правильно для
    /// `swift test` без Docker и опасно для прогона перед слиянием: одна
    /// забытая переменная выглядит так же, как успех. В этом режиме
    /// `LiveRequiredGuard` падает и называет каждую недостающую.
    /// `Server/scripts/live-tests.sh` ставит его всегда.
    static let required = requiredMode(in: ProcessInfo.processInfo.environment)

    /// Режим включает ровно `1`: опечатка в имени или значении не должна
    /// тихо выключать гейт, поэтому разбор вынесен и проверен отдельно.
    static func requiredMode(in environment: [String: String]) -> Bool {
        environment["FITTRACK_REQUIRE_LIVE"] == "1"
    }

    /// Все переменные, без которых хоть один живой тест пропускается: три
    /// гейта `enabled` (и 20k), ключ `service_role` для `signUpLinked` и две
    /// переменные `LiveJWKSChecks`.
    static let gateVariables = [
        "FITTRACK_LIVE_ISSUER",
        "FITTRACK_ANON_KEY",
        "FITTRACK_DB_PASSWORD",
        "FITTRACK_SERVICE_ROLE_KEY",
        "FITTRACK_LIVE_TOKEN",
        "FITTRACK_EMPTY_JWKS_ISSUER",
    ]

    /// Какие из `gateVariables` в окружении не заданы. Пустая строка считается
    /// незаданной: `export FITTRACK_ANON_KEY=` после неудачного `supabase
    /// status` — та же ошибка, что пропущенная переменная.
    static func missingGateVariables(in environment: [String: String]) -> [String] {
        gateVariables.filter { environment[$0, default: ""].isEmpty }
    }

    enum Failure: Error, CustomStringConvertible {
        case signUp(Int, String)
        case seed(String)

        var description: String {
            switch self {
            case .signUp(let status, let body): return "signup \(status): \(body)"
            case .seed(let message): return "посев: \(message)"
            }
        }
    }

    /// Настоящий анонимный пользователь: настоящий `auth.uid()` и токен,
    /// подписанный ключом из живого JWKS.
    struct User: Sendable {
        let id: UUID
        let token: String

        var headers: HTTPHeaders { HTTPHeaders([("Authorization", "Bearer \(token)")]) }
    }

    static func signUpAnonymous() async throws -> User {
        var request = URLRequest(url: URL(string: issuer! + "/signup")!)
        request.httpMethod = "POST"
        request.setValue(anonKey!, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.signUp(status, String(decoding: data, as: UTF8.self))
        }
        struct Body: Decodable {
            struct User: Decodable { let id: UUID }
            let access_token: String
            let user: User
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return User(id: body.user.id, token: body.access_token)
    }

    /// Настоящий ПРИВЯЗАННЫЙ пользователь: подтверждённый email, пароль,
    /// `is_anonymous = false` в токене. Заводится Auth Admin API, а не письмом:
    /// путь через Mailpit проверяет e2e веба, а здесь нужен сам токен для
    /// гейта §20.5 (`POST /v1/workouts`), и ждать письма в каждом тесте
    /// значило бы замедлить набор на порядок.
    static func signUpLinked() async throws -> User {
        guard let serviceKey else {
            throw Failure.seed("не задан FITTRACK_SERVICE_ROLE_KEY: привязанных пользователей не завести")
        }
        let email = "linked-\(UUID().uuidString.lowercased())@example.com"
        let password = UUID().uuidString

        func post(_ path: String, key: String, bearer: String? = nil,
                  body: [String: Any]) async throws -> Data {
            var request = URLRequest(url: URL(string: issuer! + path)!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "apikey")
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw Failure.signUp(status, String(decoding: data, as: UTF8.self))
            }
            return data
        }

        _ = try await post("/admin/users", key: serviceKey, bearer: serviceKey,
                           body: ["email": email, "password": password, "email_confirm": true])
        let data = try await post("/token?grant_type=password", key: anonKey!,
                                  body: ["email": email, "password": password])
        struct Body: Decodable {
            struct User: Decodable { let id: UUID; let is_anonymous: Bool? }
            let access_token: String
            let user: User
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard body.user.is_anonymous != true else { throw Failure.seed("пользователь анонимен") }
        return User(id: body.user.id, token: body.access_token)
    }

    // MARK: - Посев

    /// Прямое соединение владельцем — только для посева и только пока нет
    /// `PATCH /v1/profile` (см. шапку файла).
    static func ownerClient(_ logger: Logger) -> PostgresClient {
        var configuration = PostgresClient.Configuration(
            host: dbHost, port: dbPort, username: "postgres", password: "postgres",
            database: "postgres", tls: .disable)
        configuration.options.minimumConnections = 0
        return PostgresClient(configuration: configuration, backgroundLogger: logger)
    }

    /// Минимальный профиль через `PATCH /v1/profile` — тем же путём, что и
    /// онбординг §5.
    ///
    /// Три дня (пн/ср/пт) и уровень выше новичка — чтобы сетка §7.2 дала три
    /// РАЗНЫХ типа дня (верх / низ / full body), а не три одинаковых: на
    /// одинаковых часть утверждений о плане выродилась бы.
    /// Набор дней задаётся параметром, потому что `/today` проверяется на обоих
    /// его исходах: «сегодня тренировочный» и «сегодня нет». Подменить сам день
    /// нельзя — §20.7 держит присланную дату в сутках от серверной, — поэтому
    /// двигается профиль, а не календарь.
    static func seedProfile(_ app: Application, _ user: User,
                            weekdays: [Int] = [1, 3, 5]) async throws {
        let body = PatchProfileRequest(
            sexAtBirth: .some("female"), birthYear: .some(1994), heightCm: .some(168),
            experienceLevel: .some(.intermediate), goal: .some(.hypertrophy),
            trainingWeekdays: .some(weekdays), sessionMinutes: 60, cycleTracking: .off)
        try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            guard response.status == .ok else {
                throw Failure.seed("PATCH /v1/profile → \(response.status.code): "
                                   + String(buffer: response.body))
            }
            // Полноты здесь не проверяем: профиль становится полным только с
            // инвентарём по умолчанию (§20.6), а его фронтенд пишет следом.
        }
    }

    /// То, что фронтенд пишет НАПРЯМУЮ (§20.6): инвентарь, ограничения, PAR-Q.
    /// Пути к ним нет и не планируется, так что тест повторяет клиента, а не
    /// обходит границу.
    static func seedClientOwnedTables(_ user: User, logger: Logger) async throws {
        let client = ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await insertEquipment(client, user, isDefault: true, logger: logger)
                _ = try await client.query("""
                    insert into parq_responses (user_id, answers, has_red_flag, acknowledged,
                                                completed_at)
                    values (\(user.id), '{}'::jsonb, false, true, now())
                    on conflict (user_id) do nothing
                    """, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Одна строка инвентаря, как её пишет шаг 7 онбординга (§5). `isDefault`
    /// параметром: правило полноты читает именно флаг (§20.3, §20.6), и тест
    /// обязан уметь написать строку без него.
    static func seedEquipment(_ user: User, isDefault: Bool, logger: Logger) async throws {
        let client = ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await insertEquipment(client, user, isDefault: isDefault, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Сам `insert`, без своего клиента: `seedClientOwnedTables` держит одно
    /// соединение на весь посев, и второй клиент на ту же задачу удваивал бы
    /// число соединений у каждого теста — Supabase упирается в 100 слотов.
    private static func insertEquipment(_ client: PostgresClient, _ user: User,
                                        isDefault: Bool, logger: Logger) async throws {
        _ = try await client.query("""
            insert into equipment_profiles (id, user_id, name, is_default, dumbbells_kg,
                                            plates_kg, barbell_kg, bands, pullup_bar, bench)
            values (\(UUID()), \(user.id), 'Зал', \(isDefault),
                    '{4,6,8,10,12,14,16,18,20,24,28,32}', '{1.25,2.5,5,10,20}', 20,
                    true, true, 'adjustable')
            on conflict do nothing
            """, logger: logger)
    }

    /// Полный посев: профиль через границу, остальное — как это делает
    /// фронтенд. Порядок несущий: `equipment_profiles` ссылается на `profiles`
    /// внешним ключом, так что профиль обязан появиться первым.
    static func seed(_ app: Application, _ user: User, logger: Logger,
                     weekdays: [Int] = [1, 3, 5]) async throws {
        try await seedProfile(app, user, weekdays: weekdays)
        try await seedClientOwnedTables(user, logger: logger)
    }

    /// Оверрайд дня — тоже прямым SQL и по той же причине, что инвентарь:
    /// `daily_checkins` фронтенд пишет НАПРЯМУЮ (§20.6), пути к ним нет.
    static func setOverride(_ user: User, on date: CalendarDay, value: String,
                            logger: Logger) async throws {
        let client = ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                _ = try await client.query("""
                    insert into daily_checkins (id, user_id, checkin_date, override)
                    values (\(UUID()), \(user.id), \(Mapping.LocalTime.iso(date))::date,
                            \(value))
                    on conflict (user_id, checkin_date)
                      do update set override = excluded.override
                    """, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Начатая тренировка

    /// Профиль, неделя из одного СЕГОДНЯШНЕГО дня и начатая по нему тренировка.
    ///
    /// Фикстур общий на все тренировочные тесты: три копии одного посева
    /// разъехались бы в мелочи (другой набор дней, другой инвентарь), и
    /// утверждения разных файлов перестали бы говорить об одном и том же.
    ///
    /// День ровно один и он сегодняшний: только такой можно начать, и
    /// утверждения не зависят от того, в какой день недели идёт прогон.
    static func startedWorkout(_ app: Application, _ user: User,
                               logger: Logger) async throws -> WorkoutDTO {
        let today = Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
        let weekday = (today.dayNumber + 3) % 7 + 1
        let day = DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow")
        try await seed(app, user, logger: logger, weekdays: [weekday])

        let generate = GenerateWeekPlanRequest(
            weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)), day: day)
        var dayID: String?
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(generate) }) { response in
            guard response.status == .created else {
                throw Failure.seed("POST /v1/week-plans → \(response.status.code): "
                                   + String(buffer: response.body))
            }
            dayID = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                             from: Data(buffer: response.body))
                .plan.days.first?.dayID
        }
        guard let dayID else { throw Failure.seed("неделя без дней") }

        var workout: WorkoutDTO?
        let start = StartWorkoutRequest(plannedDayID: dayID, day: day)
        try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(start) }) { response in
            guard response.status == .created else {
                throw Failure.seed("POST /v1/workouts → \(response.status.code): "
                                   + String(buffer: response.body))
            }
            workout = try JSONDecoder().decode(WorkoutDTO.self, from: Data(buffer: response.body))
        }
        guard let workout else { throw Failure.seed("старт без тела") }
        return workout
    }

    /// Пара `date`/`tz`, которой пользуются тренировочные тесты.
    static var today: DayContext {
        let zone = TimeZone(identifier: "Europe/Moscow")!
        return DayContext(date: Mapping.LocalTime.iso(Mapping.LocalTime.day(of: Date(), in: zone)),
                          tz: zone.identifier)
    }

    // MARK: - Сервер

    static func quietLogger(_ label: String) -> Logger {
        var logger = Logger(label: label)
        logger.logLevel = .critical
        return logger
    }

    static func makeDatabase(_ logger: Logger) async throws -> Database {
        let auth = try AuthConfiguration(issuer: issuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: auth), configuration: auth)
        // Без набора ключей любой токен получил бы 503, и тест упал бы в месте,
        // не имеющем отношения к утверждению.
        try await cache.start()
        return Database(
            configuration: try DatabaseConfiguration(
                host: dbHost, port: dbPort, password: dbPassword!, tls: .disable,
                minimumConnections: 0),
            verifier: TokenVerifier(configuration: auth, cache: cache),
            logger: logger)
    }

    /// Поднимает сервер со всеми смонтированными путями и отдаёт его телу теста.
    ///
    /// `run()` пула крутится в той же группе и отменяется по выходу: без него
    /// `withUserTransaction` соединения не получит.
    static func withServer(_ label: String,
                           _ body: @escaping @Sendable (Application) async throws -> Void) async throws {
        try await withServer(label) { app, _ in try await body(app) }
    }

    /// То же, но телу достаётся и пул: часть утверждений ставится НЕ на тело
    /// ответа, а на строки, которые путь записал (`exercise_states`,
    /// `workouts`). Читаются они транзакцией той же пользовательницы, то есть
    /// через RLS §3.2 и ту же точку входа, что у сервера, — а не владельцем
    /// базы в обход.
    static func withServer(
        _ label: String,
        _ body: @escaping @Sendable (Application, Database) async throws -> Void
    ) async throws {
        let logger = quietLogger(label)
        let database = try await makeDatabase(logger)
        let library = try Content.loadBundled()
        let store = try ContentStore(library: library)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await database.run() }
            group.addTask {
                try await withApp { app in
                    app.logger = logger
                    Routes.register(on: app, content: store, library: library, database: database)
                    try await body(app, database)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
