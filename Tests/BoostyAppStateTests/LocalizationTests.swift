import BoostyCore
import XCTest
@testable import BoostyAppState

final class LocalizationTests: XCTestCase {
    func testEnglishDefaultCatalogIncludesDynamicBrokerAndProgressErrors() {
        XCTAssertEqual(AppLanguage.en.text(BrokerError(status: 401, code: "reconnect").localizedDescription), "Sign in to your account again.")
        XCTAssertEqual(AppLanguage.ru.text("Повторить"), "Повторить")
        XCTAssertEqual(AppLanguage.en.text("Повторить"), "Try again")
        let progress = "Синхронизация позиции задерживается. До закрытия приложения доступна локальная позиция."
        XCTAssertEqual(AppLanguage.en.text(progress), "Position sync is taking longer than expected. Your local position is available until the app closes.")
    }

    func testMultilineOnboardingUsesRealLineBreakLookup() {
        let key = "1. Наведите камеру на QR-код.\n2. Войдите в Boosty на открывшейся странице.\n3. Подтвердите профиль на телевизоре."
        let translated = AppLanguage.en.text(key)
        XCTAssertEqual(translated, "1. Scan the QR code with your camera.\n2. Sign in to Boosty on the page that opens.\n3. Confirm your profile on the TV.")
        XCTAssertFalse(translated.contains("\\n"))
        XCTAssertEqual(AppLanguage.ru.text(key), key)
    }

    func testSelectedLanguageFormatsPublicationDateAndTime() {
        XCTAssertNotEqual(AppLanguage.en.date(1_700_000_000), AppLanguage.ru.date(1_700_000_000))
        XCTAssertTrue(AppLanguage.en.date(1_700_000_000).contains("2023"))
        XCTAssertTrue(AppLanguage.ru.date(1_700_000_000).contains("2023"))
        XCTAssertEqual(AppLanguage.duration(3605), "1:00:05")
    }
}
