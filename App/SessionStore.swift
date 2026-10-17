import BoostyCore
import Foundation
import Security

@MainActor
protocol SessionStoring {
    func load(for endpoint: BrokerEndpoint) throws -> SessionCredentials?
    func save(_ credentials: SessionCredentials, for endpoint: BrokerEndpoint) throws
    func clear(for endpoint: BrokerEndpoint) throws
}

struct SessionStore: SessionStoring {
    private let service = "\(Bundle.main.bundleIdentifier ?? "org.boostytv.appletv").session"

    func load(for endpoint: BrokerEndpoint) throws -> SessionCredentials? {
        var query = query(for: endpoint)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StorageError(status: status)
        }
        return try JSONDecoder().decode(SessionCredentials.self, from: data)
    }

    func save(_ credentials: SessionCredentials, for endpoint: BrokerEndpoint) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = query(for: endpoint)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StorageError(status: added) }
        } else if status != errSecSuccess {
            throw StorageError(status: status)
        }
    }

    func clear(for endpoint: BrokerEndpoint) throws {
        let status = SecItemDelete(query(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError(status: status)
        }
    }

    private func query(for endpoint: BrokerEndpoint) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: endpoint.url.absoluteString]
    }

    private struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Не удалось открыть защищённое хранилище сессии (\(status))." }
    }
}
