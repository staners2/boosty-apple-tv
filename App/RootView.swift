import BoostyCore
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @StateObject private var model: AppModel
    @State private var address = ""
    @Environment(\.scenePhase) private var scenePhase

    init(model: AppModel? = nil) {
        _model = StateObject(wrappedValue: model ?? AppModel())
    }

    var body: some View {
        Group {
            switch model.screen {
            case .server: serverView
            case .connecting:
                VStack(spacing: 28) {
                    ProgressView()
                    Text("Подключение к серверу Boosty…").font(.title3)
                    Button("Изменить сервер") { model.changeServer() }
                }
            case .pairing, .confirmation: pairingView
            case .library: LibraryView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.055))
        .tint(.orange)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) { if model.screen != .library { languageMenu.padding(28) } }
        .onChange(of: scenePhase) { _, value in model.setActive(value == .active) }
        .onAppear { model.setActive(scenePhase == .active) }
        .task {
            address = model.serverAddress
            await model.restore()
        }
        .fullScreenCover(item: $model.playback, onDismiss: {
            Task { await model.playbackClosed() }
        }) { request in
            PlaybackScreen(request: request)
        }
        .environment(\.locale, model.language.locale)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button { model.language = language } label: {
                    Label(language.title, systemImage: model.language == language ? "checkmark.circle.fill" : "globe")
                }
                .accessibilityIdentifier("language-\(language.rawValue)")
            }
        } label: { Label("Язык", systemImage: "globe") }
        .accessibilityIdentifier("language-menu")
    }

    private var serverView: some View {
        VStack(alignment: .leading, spacing: 30) {
            Label("Boosty", systemImage: "play.rectangle.fill")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(.orange)
            Text("Ваши авторы. На большом экране.")
                .font(.title2)
            Text("Укажите HTTPS-адрес вашего сервера Boosty. Вход в аккаунт выполняется на телефоне по QR-коду.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Адрес сервера Boosty", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await model.connect(address) } }
            if let error = model.errorMessage { ErrorBanner(message: error) }
            if model.canRetryStoredSessionRemoval {
                Button("Повторить удаление сохранённой сессии") { model.retryStoredSessionRemoval() }
            }
            Button("Подключить Apple TV", systemImage: "arrow.right.circle.fill") {
                Task { await model.connect(address) }
            }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(maxWidth: 1000)
        .padding(70)
    }

    private var pairingView: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Boosty").font(.system(size: 70, weight: .bold)).foregroundStyle(.orange)
                if model.screen == .confirmation, let profile = model.pendingProfile {
                    Text("Подтвердите профиль").font(.title)
                    ProfileBadge(profile: profile)
                    Text("Проверьте имя перед подключением этого Apple TV к аккаунту.")
                        .foregroundStyle(.secondary)
                    Button("Это мой профиль", systemImage: "checkmark.circle.fill") {
                        Task { await model.confirmProfile() }
                    }
                    .disabled(model.loading)
                    Button("Другой аккаунт") { Task { await model.beginPairing() } }
                } else {
                    Text("Войдите с телефона").font(.title)
                    Text("1. Наведите камеру на QR-код.\n2. Войдите в Boosty на открывшейся странице.\n3. Подтвердите профиль на телевизоре.")
                        .lineSpacing(14)
                    Text("Нужен телефон, привязанный к Boosty. Если вы входите через Google, сначала привяжите номер в настройках Boosty на телефоне.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let pair = model.pair {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(pair.expiresAt / 1000 - context.date.timeIntervalSince1970))
                            Text("Код действует ещё \(AppLanguage.duration(Double(remaining)))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("Новый QR-код", systemImage: "arrow.clockwise") {
                        Task { await model.beginPairing() }
                    }
                }
                if let error = model.errorMessage { ErrorBanner(message: error) }
                if model.needsStoredSessionRecovery {
                    Button("Удалить сессию и войти заново") { Task { await model.clearStoredSessionAndPair() } }
                } else if model.canRetryStoredSessionRemoval {
                    Button("Повторить удаление сохранённой сессии") { model.retryStoredSessionRemoval() }
                }
                Button("Изменить сервер") { model.changeServer() }
            }
            .frame(maxWidth: 850, alignment: .leading)
            if model.screen == .pairing, let pair = model.pair,
               let image = qrImage(pair.qrImage) {
                Image(uiImage: image)
                    .interpolation(.none).resizable().scaledToFit()
                    .padding(24).background(.white)
                    .frame(width: 430, height: 430)
                    .accessibilityLabel("QR-код для входа в Boosty")
            }
        }
        .padding(80)
    }

    private func qrImage(_ value: String) -> UIImage? {
        guard value.hasPrefix("data:image/png;base64,"), value.count < 200_000,
              let data = Data(base64Encoded: String(value.dropFirst("data:image/png;base64,".count))) else { return nil }
        return UIImage(data: data)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label { Text(LocalizedStringKey(message)) } icon: { Image(systemName: "exclamationmark.circle") }
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProfileBadge: View {
    let profile: Profile
    var body: some View {
        HStack(spacing: 18) {
            AsyncImage(url: profile.avatar) { image in image.resizable().scaledToFill() }
                placeholder: { Image(systemName: "person.crop.circle.fill").resizable() }
                .frame(width: 76, height: 76).clipShape(Circle())
            Text(profile.name).font(.title2)
        }
    }
}
