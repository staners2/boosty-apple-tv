import BoostyCore
import SwiftUI

@main
struct FixtureApp: App {
    @StateObject private var model: AppModel

    init() {
        FixtureProtocol.install()
        _model = StateObject(wrappedValue: AppModel(storage: FixtureSessions(), makeClient: { endpoint in
            BrokerClient(endpoint: endpoint, session: FixtureProtocol.session())
        }))
    }

    var body: some Scene {
        WindowGroup { RootView(model: model) }
    }
}

@MainActor
private final class FixtureSessions: SessionStoring {
    private var credentials: [BrokerEndpoint: SessionCredentials] = [:]

    func load(for endpoint: BrokerEndpoint) throws -> SessionCredentials? { credentials[endpoint] }

    func save(_ credentials: SessionCredentials, for endpoint: BrokerEndpoint) throws {
        self.credentials[endpoint] = credentials
    }

    func clear(for endpoint: BrokerEndpoint) throws { credentials[endpoint] = nil }
}
