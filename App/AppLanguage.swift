import BoostyCore
import Foundation

struct PostKey: Hashable, Sendable {
    let blog: String
    let id: String
    init(_ post: Post) { blog = post.blog; id = post.id }
}

extension Post {
    var key: PostKey { PostKey(self) }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, ru
    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var title: String { self == .en ? "English" : "Русский" }

    func text(_ key: String) -> String {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        guard let path = resources.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func date(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func duration(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(min(value, 604800))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func errorKey(_ error: Error) -> String {
        if let error = error as? BrokerError { return error.localizedDescription }
        return "Не удалось выполнить запрос. Попробуйте снова."
    }
}
