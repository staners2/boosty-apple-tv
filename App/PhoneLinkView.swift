import BoostyCore
import SwiftUI
import UIKit

struct PhoneLink: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct PhoneLinkView: View {
    let link: PhoneLink
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = UUID()

    var body: some View {
        VStack(spacing: 30) {
            Text(verbatim: link.title).font(.title).multilineTextAlignment(.center)
            Text("Откройте ссылку на телефоне").font(.title2)
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 430, height: 430).padding(24).background(.white)
                    .accessibilityLabel("QR-код ссылки для телефона")
            } else if let error {
                ErrorBanner(message: error)
                Button("Повторить") { retry = UUID() }
            } else { ProgressView("Создание QR-кода…") }
            Button("Вернуться к публикации") { dismiss() }
        }
        .padding(60)
        .task(id: retry) {
            image = nil
            error = nil
            do {
                let value = try await model.qrCode(for: link.url)
                try Task.checkCancellation()
                guard let separator = value.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(value[value.index(after: separator)...])),
                      let decoded = UIImage(data: data) else { throw BrokerError(code: "invalid_response") }
                image = decoded
            } catch {
                if !Task.isCancelled { self.error = AppLanguage.errorKey(error) }
            }
        }
        .onExitCommand { dismiss() }
    }
}
