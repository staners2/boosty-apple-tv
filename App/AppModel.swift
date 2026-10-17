import BoostyCore
import Foundation
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let post: Post
    let video: Video
    let source: VideoSource
    let startSeconds: Double
    let client: BrokerClient
    let progress: PlaybackProgress
    var previews: FramePreview? = nil
    var onAuthorizationFailure: (@MainActor () async -> Void)? = nil
}

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case server, connecting, pairing, confirmation, library }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "interfaceLanguage") }
    }
    @Published var focusedPost: PostKey?
    @Published private(set) var feedError: String?
    @Published private(set) var sessionNotice: String?
    @Published private(set) var openingID: UUID?
    @Published private(set) var screen: Screen = .server
    @Published private(set) var profile: Profile?
    @Published private(set) var pair: PairCreated?
    @Published private(set) var pendingProfile: Profile?
    @Published private(set) var posts: [Post] = []
    @Published private(set) var subscriptions: [Subscription] = []
    @Published private(set) var selectedBlog: String?
    @Published private(set) var loading = false
    @Published private(set) var preparingVideo = false
    @Published private(set) var subscriptionError: String?
    @Published private(set) var needsStoredSessionRecovery = false
    @Published private(set) var canRetryStoredSessionRemoval = false
    @Published private(set) var playbackRevision = UUID()
    @Published var errorMessage: String?
    @Published var playback: PlaybackRequest?

    private(set) var client: BrokerClient?
    private(set) var progress: PlaybackProgress?
    private(set) var previews: FramePreview?
    private var endpoint: BrokerEndpoint?
    private var nextOffset: String?
    private var pairingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration = UUID()
    private var generation = UUID()
    private var pairGeneration = UUID()
    private var feedGeneration = UUID()
    private var pollGeneration = UUID()
    private var active = true
    private var loadedOffsets = Set<String?>()
    private struct FeedRequest {
        let blog: String?
        let offset: String?
        let append: Bool
    }
    private var failedFeedRequest: FeedRequest?
    private var pendingDeletion: BrokerEndpoint?
    private let storage: any SessionStoring
    private let defaults: UserDefaults
    private let progressFlushTimeout: Duration
    private let makeClient: (BrokerEndpoint) -> BrokerClient

    init(storage: (any SessionStoring)? = nil, defaults: UserDefaults = .standard,
         progressFlushTimeout: Duration = .seconds(25),
         makeClient: @escaping (BrokerEndpoint) -> BrokerClient = { BrokerClient(endpoint: $0) }) {
        self.storage = storage ?? SessionStore()
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "en") ?? .en
        self.progressFlushTimeout = progressFlushTimeout
        self.makeClient = makeClient
    }

    var hasMore: Bool { nextOffset != nil }
    var serverAddress: String { defaults.string(forKey: "brokerAddress") ?? "" }

    func restore() async {
        if !serverAddress.isEmpty { await connect(serverAddress) }
    }

    func connect(_ address: String) async {
        changeServer()
        let current = generation
        screen = .connecting
        do {
            let endpoint = try BrokerEndpoint(address)
            let client = makeClient(endpoint)
            self.endpoint = endpoint
            self.client = client
            defaults.set(endpoint.url.absoluteString, forKey: "brokerAddress")
            if !defaults.bool(forKey: logoutKey(endpoint)) {
                let credentials: SessionCredentials?
                do { credentials = try storage.load(for: endpoint) }
                catch { storedSessionFailed(endpoint); return }
                if let credentials {
                    do { try await client.restoreSession(credentials) }
                    catch {
                        guard isCurrent(current, client) else { return }
                        storedSessionFailed(endpoint)
                        return
                    }
                    guard isCurrent(current, client) else { return }
                    do {
                        let profile = try await client.me()
                        guard isCurrent(current, client) else { return }
                        self.profile = profile
                        progress = PlaybackProgress(client: client)
                        previews = FramePreview(client: client)
                        screen = .library
                        await loadLibrary()
                        return
                    } catch {
                        guard isCurrent(current, client) else { return }
                        guard (error as? BrokerError)?.requiresPairing == true else { throw error }
                        removeStoredSession(endpoint)
                    }
                }
            } else {
                // A logout tombstone prevents restoration after failed Keychain deletion and restart.
                removeStoredSession(endpoint)
            }
            guard isCurrent(current, client) else { return }
            await beginPairing()
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            errorMessage = AppLanguage.errorKey(error)
            screen = .server
        }
    }

    func beginPairing(preservingRecovery: Bool = false) async {
        guard let endpoint else { return }
        resetAccess(preservingRecovery: preservingRecovery)
        let current = generation
        let operation = pairGeneration
        // Discard the old client so an abandoned finish cannot authenticate a replacement flow.
        let client = makeClient(endpoint)
        self.client = client
        needsStoredSessionRecovery = false
        screen = .connecting
        errorMessage = nil
        do {
            let pair = try await client.createPair()
            guard isCurrent(current, client), pairGeneration == operation else { return }
            self.pair = pair
            screen = .pairing
            startPolling(pair: pair, client: client, current: current, operation: operation)
        } catch {
            guard isCurrent(current, client), pairGeneration == operation else { return }
            screen = .pairing
            errorMessage = AppLanguage.errorKey(error)
        }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        pollGeneration = UUID()
        pairingTask?.cancel()
        pairingTask = nil
        if value, screen == .pairing, let pair, let client {
            startPolling(pair: pair, client: client, current: generation, operation: pairGeneration)
        }
    }

    private func startPolling(pair: PairCreated, client: BrokerClient, current: UUID, operation: UUID) {
        guard active else { return }
        let poll = UUID()
        pollGeneration = poll
        pairingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, self.isCurrent(current, client),
                      self.pairGeneration == operation, self.pollGeneration == poll else { return }
                if Date().timeIntervalSince1970 * 1_000 >= pair.expiresAt {
                    self.expirePair()
                    return
                }
                do {
                    let status = try await client.pollPair(id: pair.id, pollKey: pair.pollKey)
                    guard self.active, self.isCurrent(current, client),
                          self.pairGeneration == operation, self.pollGeneration == poll else { return }
                    if status.state == .confirm, let profile = status.profile {
                        self.pendingProfile = profile
                        self.errorMessage = nil
                        self.screen = .confirmation
                        return
                    }
                    self.errorMessage = nil
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    guard self.active, self.isCurrent(current, client),
                          self.pairGeneration == operation, self.pollGeneration == poll,
                          !(error is CancellationError) else { return }
                    if (error as? BrokerError)?.isExpiredPair == true { self.expirePair(); return }
                    self.errorMessage = "Нет связи с сервером. Повторяю проверку входа…"
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                }
            }
        }
    }

    func confirmProfile() async {
        guard let pair, let client, let endpoint, !loading else { return }
        let current = generation
        let operation = pairGeneration
        loading = true
        defer { if generation == current, pairGeneration == operation { loading = false } }
        do {
            let profile = try await client.finishPair(id: pair.id, pollKey: pair.pollKey)
            guard isCurrent(current, client), pairGeneration == operation else { return }
            let session = await client.currentSession()
            guard isCurrent(current, client), pairGeneration == operation else { return }
            guard let session else { throw BrokerError(code: "invalid_response") }
            do {
                try storage.save(session, for: endpoint)
                defaults.removeObject(forKey: logoutKey(endpoint))
                if pendingDeletion == endpoint { pendingDeletion = nil; canRetryStoredSessionRemoval = false }
                sessionNotice = nil
            } catch {
                defaults.set(true, forKey: logoutKey(endpoint))
                sessionNotice = "Вход действует до закрытия приложения. Не удалось сохранить сессию на Apple TV."
            }
            self.profile = profile
            progress = PlaybackProgress(client: client)
            previews = FramePreview(client: client)
            cancelPairing()
            loading = false
            screen = .library
            await loadLibrary()
        } catch {
            guard isCurrent(current, client), pairGeneration == operation else { return }
            errorMessage = AppLanguage.errorKey(error)
            if (error as? BrokerError)?.isExpiredPair == true { expirePair() }
        }
    }

    func changeServer() {
        resetAccess()
        endpoint = nil
        needsStoredSessionRecovery = false
        screen = .server
        errorMessage = nil
    }

    func logout() async {
        guard let client, let endpoint else { changeServer(); return }
        removeStoredSession(endpoint)
        let deletionWarning = canRetryStoredSessionRemoval ? "На Apple TV выполнен выход. Не удалось удалить сохранённую сессию; повторите удаление. Автоматический вход отключён." : nil
        changeServer()
        let current = generation
        errorMessage = deletionWarning
        do { try await client.logout() }
        catch {
            guard generation == current, !Task.isCancelled else { return }
            errorMessage = deletionWarning ?? "На Apple TV выполнен выход. Сервер не подтвердил отзыв сессии: проверьте соединение."
        }
    }

    func retryStoredSessionRemoval() {
        guard let endpoint = pendingDeletion else { return }
        removeStoredSession(endpoint)
        errorMessage = canRetryStoredSessionRemoval
            ? "Не удалось удалить сохранённую сессию. Автоматический вход отключён; повторите удаление."
            : "Сохранённая сессия удалена. Для входа подтвердите профиль по новому QR-коду."
    }

    func clearStoredSessionAndPair() async {
        guard let endpoint else { return }
        removeStoredSession(endpoint)
        await beginPairing()
    }

    func loadLibrary() async {
        guard let client, screen == .library else { return }
        let current = generation
        subscriptionError = nil
        do {
            var offset: Int? = 0
            var all: [Subscription] = []
            var seen = Set<Int>()
            while let cursor = offset, seen.insert(cursor).inserted {
                let page = try await client.subscriptions(offset: cursor)
                guard isCurrent(current, client) else { return }
                all.append(contentsOf: page.items.filter { item in !all.contains(where: { $0.blog == item.blog }) })
                offset = page.nextOffset
            }
            subscriptions = all
        } catch {
            guard isCurrent(current, client) else { return }
            await handle(error, current: current, client: client)
            if isCurrent(current, client), screen == .library { subscriptionError = AppLanguage.errorKey(error) }
        }
        guard isCurrent(current, client), screen == .library else { return }
        await loadFeed(blog: selectedBlog)
    }

    func loadFeed(blog: String?, more: Bool = false) async {
        guard screen == .library else { return }
        if more && (loading || nextOffset == nil) { return }
        if !more {
            feedGeneration = UUID()
            selectedBlog = blog
            posts = []
            focusedPost = nil
            nextOffset = nil
            loadedOffsets = []
        }
        await requestFeed(FeedRequest(blog: blog, offset: more ? nextOffset : nil, append: more))
    }

    func retryFeed() async {
        guard let request = failedFeedRequest, !loading else { return }
        await requestFeed(request)
    }

    func loadMoreIfNeeded(near post: Post) async {
        guard feedError == nil, hasMore, let index = posts.firstIndex(where: { $0.key == post.key }),
              index >= max(0, posts.count - 6) else { return }
        await loadFeed(blog: selectedBlog, more: true)
    }

    private func requestFeed(_ request: FeedRequest) async {
        guard let client, screen == .library else { return }
        let session = generation
        let current = feedGeneration
        loading = true
        feedError = nil
        failedFeedRequest = nil
        errorMessage = subscriptionError ?? sessionNotice
        defer { if generation == session, feedGeneration == current { loading = false } }
        do {
            await progress?.flush(timeout: progressFlushTimeout)
            guard isCurrent(session, client), feedGeneration == current else { return }
            let page = try await client.feed(blog: request.blog, offset: request.offset)
            guard isCurrent(session, client), feedGeneration == current else { return }
            var known = Set<PostKey>()
            posts = ((request.append ? posts : []) + page.items).filter { known.insert($0.key).inserted }
                .sorted {
                    if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
                    if $0.blog != $1.blog { return $0.blog < $1.blog }
                    return $0.id < $1.id
                }
            loadedOffsets.insert(request.offset)
            nextOffset = page.nextOffset.flatMap { loadedOffsets.contains($0) ? nil : $0 }
            if let warning = progress?.warning { errorMessage = warning }
        } catch {
            guard isCurrent(session, client), feedGeneration == current else { return }
            if (error as? BrokerError)?.requiresPairing == true {
                await handle(error, current: session, client: client)
            } else if !(error is CancellationError) {
                feedError = AppLanguage.errorKey(error)
                failedFeedRequest = request
            }
        }
    }

    func qrCode(for url: URL) async throws -> String {
        guard let client, screen == .library else { throw CancellationError() }
        let current = generation
        do {
            let image = try await client.qrCode(for: url)
            guard isCurrent(current, client) else { throw CancellationError() }
            return image
        } catch {
            guard isCurrent(current, client) else { throw CancellationError() }
            await handle(error, current: current, client: client)
            throw error
        }
    }

    func fetchPost(_ post: Post) async throws -> Post {
        guard let client, screen == .library else { throw CancellationError() }
        let current = generation
        do {
            await progress?.flush(timeout: progressFlushTimeout)
            guard isCurrent(current, client) else { throw CancellationError() }
            let fresh = try await client.post(blog: post.blog, id: post.id)
            guard isCurrent(current, client) else { throw CancellationError() }
            return fresh
        } catch {
            guard isCurrent(current, client) else { throw CancellationError() }
            await handle(error, current: current, client: client)
            throw error
        }
    }

    func resumeSeconds(for video: Video) -> Double {
        let position = progress?.localPosition(videoID: video.id) ?? video.resumeSeconds
        return video.duration > 0 ? min(position, video.duration) : position
    }

    func cancelOpening() {
        openingID = nil
        preparingVideo = false
    }

    func play(post: Post, videoID: String, quality: String? = nil, at seconds: Double? = nil) async {
        guard let client, let progress, screen == .library, !preparingVideo else { return }
        let current = generation
        let operation = UUID()
        openingID = operation
        preparingVideo = true
        defer {
            if generation == current, openingID == operation { openingID = nil; preparingVideo = false }
        }
        errorMessage = nil
        do {
            await progress.flush(timeout: progressFlushTimeout)
            guard isCurrent(current, client), openingID == operation else { return }
            let snapshot = progress.snapshot()
            let freshPost = try await client.post(blog: post.blog, id: post.id)
            guard isCurrent(current, client), openingID == operation else { return }
            guard !freshPost.locked, let video = freshPost.videos.first(where: { $0.id == videoID }),
                  let source = quality.flatMap({ choice in video.playableSources.first(where: { $0.quality == choice }) })
                    ?? video.playableSources.first(where: { $0.quality == "hls" || $0.url.pathExtension.lowercased() == "m3u8" })
                    ?? video.playableSources.first(where: { $0.quality == "full_hd" })
                    ?? video.playableSources.first else {
                errorMessage = "Для этого видео нет доступного источника HLS или MP4."
                return
            }
            var serverPosition = video.resumeSeconds
            if seconds == nil {
                do { serverPosition = try await client.progress(blog: freshPost.blog, postID: freshPost.id, videoID: videoID) }
                catch {
                    guard isCurrent(current, client), openingID == operation else { return }
                    guard let failure = error as? BrokerError, !failure.requiresPairing else { throw error }
                    let status = failure.status
                    if let status, status < 500, status != 408, status != 429 { throw error }
                    guard failure.code == "network" || status != nil else { throw error }
                    // The refreshed post already contains the broker cached progress for transient failures.
                }
                guard isCurrent(current, client), openingID == operation else { return }
            }
            let start = seconds ?? progress.localPosition(videoID: videoID, snapshot: snapshot) ?? serverPosition
            guard start.isFinite else { throw BrokerError(code: "invalid_input") }
            playback = PlaybackRequest(post: freshPost, video: video, source: source,
                startSeconds: max(0, video.duration > 0 ? min(start, video.duration) : start), client: client, progress: progress,
                previews: previews, onAuthorizationFailure: { [weak self] in
                    guard let self, self.isCurrent(current, client) else { return }
                    await self.handle(BrokerError(status: 401, code: "reconnect"), current: current, client: client)
                })
        } catch {
            guard isCurrent(current, client), openingID == operation else { return }
            await handle(error, current: current, client: client)
        }
    }

    func playbackClosed() async {
        guard let client, screen == .library else { return }
        let current = generation
        await progress?.flush(timeout: progressFlushTimeout)
        guard isCurrent(current, client) else { return }
        playbackRevision = UUID()
    }

    private func handle(_ error: Error, current: UUID, client: BrokerClient) async {
        guard isCurrent(current, client), !(error is CancellationError) else { return }
        errorMessage = AppLanguage.errorKey(error)
        if (error as? BrokerError)?.requiresPairing == true {
            let operation = UUID()
            recoveryGeneration = operation
            recoveryTask?.cancel()
            let recovery = Task { [weak self] in
                guard let self, self.isCurrent(current, client) else { return }
                if let endpoint = self.endpoint { self.removeStoredSession(endpoint) }
                // Removing an authenticated screen cancels its task; the model owns recovery until reset.
                await self.beginPairing(preservingRecovery: true)
            }
            recoveryTask = recovery
            await recovery.value
            if recoveryGeneration == operation { recoveryTask = nil }
        }
    }

    private func isCurrent(_ current: UUID, _ client: BrokerClient) -> Bool {
        generation == current && self.client === client && !Task.isCancelled
    }

    private func resetAccess(preservingRecovery: Bool = false) {
        if !preservingRecovery {
            recoveryGeneration = UUID()
            recoveryTask?.cancel()
            recoveryTask = nil
        }
        generation = UUID()
        feedGeneration = UUID()
        cancelPairing()
        progress?.invalidate()
        progress = nil
        previews?.invalidate()
        previews = nil
        openingID = nil
        client = nil
        profile = nil
        posts = []
        subscriptions = []
        subscriptionError = nil
        sessionNotice = nil
        feedError = nil
        failedFeedRequest = nil
        loadedOffsets = []
        focusedPost = nil
        selectedBlog = nil
        nextOffset = nil
        playback = nil
        preparingVideo = false
        loading = false
    }

    private func logoutKey(_ endpoint: BrokerEndpoint) -> String { "loggedOut:" + endpoint.url.absoluteString }

    private func removeStoredSession(_ endpoint: BrokerEndpoint) {
        defaults.set(true, forKey: logoutKey(endpoint))
        do {
            try storage.clear(for: endpoint)
            if pendingDeletion == endpoint { pendingDeletion = nil; canRetryStoredSessionRemoval = false }
        } catch {
            pendingDeletion = endpoint
            canRetryStoredSessionRemoval = true
        }
    }

    private func storedSessionFailed(_ endpoint: BrokerEndpoint) {
        defaults.set(true, forKey: logoutKey(endpoint))
        pendingDeletion = endpoint
        canRetryStoredSessionRemoval = true
        needsStoredSessionRecovery = true
        screen = .pairing
        errorMessage = "Сохранённая сессия повреждена или недоступна. Удалите её и войдите по новому QR-коду."
    }

    private func expirePair() {
        cancelPairing()
        loading = false
        screen = .pairing
        errorMessage = "Срок действия QR-кода истёк. Создайте новый код."
    }

    private func cancelPairing() {
        pairGeneration = UUID()
        pollGeneration = UUID()
        pairingTask?.cancel()
        pairingTask = nil
        pair = nil
        pendingProfile = nil
    }
}
