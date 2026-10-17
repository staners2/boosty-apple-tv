import Foundation

public struct BrokerError: Error, LocalizedError, Sendable {
    public let status: Int?
    public let code: String
    public let isExpiredPair: Bool
    public var requiresPairing: Bool { status == 401 || code == "reconnect" }

    public init(status: Int? = nil, code: String, isExpiredPair: Bool = false) {
        self.status = status
        // Only machine-readable error codes may cross into presentation or diagnostics.
        self.code = code.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) == nil ? "request_failed" : code
        self.isExpiredPair = isExpiredPair
    }

    public var errorDescription: String? {
        if isExpiredPair { return "Время входа истекло. Создайте новый QR-код." }
        if requiresPairing { return "Войдите в аккаунт снова." }
        if status == 429 { return "Слишком много запросов. Попробуйте позже." }
        switch code {
        case "invalid_input": return "Проверьте введённые данные."
        case "invalid_response": return "Сервис вернул некорректный ответ."
        case "network": return "Не удалось подключиться к сервису. Проверьте соединение."
        default: return "Не удалось выполнить запрос. Попробуйте снова."
        }
    }

    static let invalidInput = BrokerError(code: "invalid_input")
    static let invalidResponse = BrokerError(code: "invalid_response")
}
