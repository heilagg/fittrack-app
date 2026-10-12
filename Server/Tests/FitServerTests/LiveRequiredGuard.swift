//  Гейт обязательного живого прогона (`FITTRACK_REQUIRE_LIVE=1`).
//
//  Живые наборы выключаются через `.enabled(if:)`, и swift-testing считает
//  выключенный набор пропущенным, а не упавшим: `swift test` без переменных
//  зелёный. Перед слиянием это неприемлемо — зелёный прогон без живой базы
//  ничего не говорит о сервере. В обязательном режиме этот набор падает и
//  называет все недостающие переменные разом.
//
//  Сам набор НЕ выключается: проверка, которую можно пропустить, ничего не
//  сторожит.

import Foundation
import Testing

@Suite("Обязательный живой прогон (FITTRACK_REQUIRE_LIVE)")
struct LiveRequiredGuard {

    @Test func requiredRunHasEveryLiveVariable() {
        guard Live.required else { return }
        let missing = Live.missingGateVariables(in: ProcessInfo.processInfo.environment)
        #expect(missing.isEmpty, """
            FITTRACK_REQUIRE_LIVE=1, но не заданы: \(missing.joined(separator: ", ")). \
            Живые тесты пропустились бы; запуск — Server/scripts/live-tests.sh
            """)
    }

    @Test func fullEnvironmentMissesNothing() {
        let full = Dictionary(uniqueKeysWithValues: Live.gateVariables.map { ($0, "x") })
        #expect(Live.missingGateVariables(in: full).isEmpty)
    }

    /// Каждая переменная по отдельности: снятая одна — названа ровно она.
    @Test(arguments: Live.gateVariables)
    func eachAbsentVariableIsNamed(_ name: String) {
        var environment = Dictionary(uniqueKeysWithValues: Live.gateVariables.map { ($0, "x") })
        environment[name] = nil
        #expect(Live.missingGateVariables(in: environment) == [name])
        environment[name] = ""
        #expect(Live.missingGateVariables(in: environment) == [name])
    }

    /// Список гейтов не короче того, что читают живые наборы: выпавшая из
    /// него переменная снова дала бы тихий пропуск.
    @Test func gateListCoversEveryLiveSwitch() {
        #expect(Set(Live.gateVariables) == [
            "FITTRACK_LIVE_ISSUER", "FITTRACK_ANON_KEY", "FITTRACK_DB_PASSWORD",
            "FITTRACK_SERVICE_ROLE_KEY", "FITTRACK_LIVE_TOKEN", "FITTRACK_EMPTY_JWKS_ISSUER",
        ])
    }
}
