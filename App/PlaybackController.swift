import AVFoundation
#if os(tvOS)
import AVKit
#endif
import BoostyCore
import SwiftUI

@MainActor
final class PlaybackController: ObservableObject {
    let player: AVPlayer
    let request: PlaybackRequest
    @Published private(set) var playbackError: String?
    @Published private(set) var progressWarning: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var ended = false
    @Published private(set) var preparing = true
    @Published private(set) var seeking = false
    @Published private(set) var scrubSeconds: Double?
    @Published private(set) var currentSource: VideoSource
    @Published private(set) var video: Video

    private var itemObservation: NSKeyValueObservation?
    private var pauseObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastQueuedSeconds: Int?
    private var ready = false
    private var stopped = false
    private var active = true
    private var wantsPlayback = true
    private var installationID = UUID()
    private var sourceOperationID = UUID()
    private var lastPosition: Double
    private var seekID = UUID()
    private let makeItem: (VideoSource) -> AVPlayerItem

    init(request: PlaybackRequest, player: AVPlayer = AVPlayer(),
         makeItem: @escaping (VideoSource) -> AVPlayerItem = { source in
             AVPlayerItem(asset: AVURLAsset(url: source.url, options: [AVURLAssetHTTPUserAgentKey: BrokerClient.userAgent]))
         }) {
        self.request = request
        self.player = player
        self.makeItem = makeItem
        lastPosition = request.startSeconds
        currentSource = request.source
        video = request.video
        duration = request.video.duration.isFinite ? max(0, request.video.duration) : 0
        position = request.startSeconds
        #if os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playbackError = "Не удалось включить звук. Закройте плеер и повторите попытку."
        }
        #endif
        pauseObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
                if player.timeControlStatus == .paused { self?.savePosition(force: true) }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updatePosition()
                self.savePosition(force: false)
            }
        }
        install(source: request.source, at: request.startSeconds)
    }

    func retry() async {
        guard active, !stopped else { return }
        let current = installationID
        sourceOperationID = UUID()
        let operation = sourceOperationID
        playbackError = nil
        wantsPlayback = true
        do {
            let post = try await request.client.post(blog: request.post.blog, id: request.post.id)
            guard active, !stopped, installationID == current, sourceOperationID == operation, !Task.isCancelled else { return }
            guard !post.locked, let video = post.videos.first(where: { $0.id == request.video.id }),
                  let source = video.playableSources.first(where: { $0.quality == currentSource.quality })
                    ?? video.playableSources.first else {
                playbackError = "Видео больше недоступно. Вернитесь к публикации и проверьте подписку."
                return
            }
            self.video = video
            install(source: source, at: lastPosition)
        } catch {
            guard active, !stopped, installationID == current, sourceOperationID == operation, !Task.isCancelled else { return }
            if (error as? BrokerError)?.requiresPairing == true, let reconnect = request.onAuthorizationFailure {
                stop()
                await reconnect()
                return
            }
            playbackError = "Не удалось обновить ссылку на видео. Проверьте соединение или войдите снова."
        }
    }

    var timeline: PlaybackTimeline { PlaybackTimeline(body: request.post.body, videoID: video.id, duration: duration) }
    var selectedPosition: Double { scrubSeconds ?? position }

    func changeQuality(_ source: VideoSource) async {
        guard active, !stopped, !preparing else { return }
        let current = installationID
        sourceOperationID = UUID()
        let operation = sourceOperationID
        updatePosition()
        let seconds = position
        let resume = (ready ? player.rate > 0 : wantsPlayback) && !ended
        wantsPlayback = resume
        savePosition(force: true)
        player.pause()
        preparing = true
        playbackError = nil
        cancelScrub()
        do {
            let post = try await request.client.post(blog: request.post.blog, id: request.post.id)
            guard active, !stopped, current == installationID, sourceOperationID == operation, !Task.isCancelled else { return }
            guard !post.locked, let fresh = post.videos.first(where: { $0.id == video.id }),
                  let replacement = fresh.playableSources.first(where: { $0.quality == source.quality }) else {
                throw BrokerError(code: "source_unavailable")
            }
            video = fresh
            install(source: replacement, at: seconds)
        } catch {
            guard active, !stopped, current == installationID, sourceOperationID == operation, !Task.isCancelled else { return }
            if (error as? BrokerError)?.requiresPairing == true, let reconnect = request.onAuthorizationFailure {
                stop()
                await reconnect()
                return
            }
            preparing = false
            playbackError = "Не удалось сменить качество. Повторите попытку или выберите другой источник."
        }
    }

    func togglePlayback() {
        guard ready, active, !stopped, !preparing else { return }
        if ended { restart(); return }
        if player.rate > 0 {
            wantsPlayback = false; player.pause(); isPlaying = false; savePosition(force: true)
        } else {
            wantsPlayback = true; player.play(); isPlaying = true
        }
    }

    func restart() { performSeek(to: 0, resume: true) }

    func beginScrub() {
        guard ready, active, !stopped, !preparing, !seeking, duration > 0 else { return }
        if scrubSeconds == nil { updatePosition(); scrubSeconds = position }
        previewSelection()
    }

    func moveScrub(by seconds: Double) {
        guard seconds.isFinite else { return }
        beginScrub()
        guard let selected = scrubSeconds else { return }
        scrubSeconds = clamp(selected + seconds)
        previewSelection()
    }

    func commitScrub() {
        guard let seconds = scrubSeconds else { return }
        cancelScrub()
        seek(to: seconds)
    }

    func cancelScrub() {
        scrubSeconds = nil
        request.previews?.cancel()
    }

    func previewChapter(_ seconds: Double) {
        request.previews?.select(post: request.post, video: video, seconds: seconds,
                                 preferChapters: true, duration: duration)
    }

    private func previewSelection() {
        guard let seconds = scrubSeconds else { return }
        request.previews?.select(post: request.post, video: video, seconds: floor(seconds), duration: duration)
    }

    private func clamp(_ seconds: Double) -> Double {
        max(0, min(seconds, duration > 0 ? max(0, duration - 0.5) : seconds))
    }

    func seek(to seconds: Double) {
        performSeek(to: seconds, resume: ended)
    }

    private func performSeek(to seconds: Double, resume: Bool) {
        guard ready, active, !stopped, !preparing, seconds.isFinite, seconds >= 0,
              let item = player.currentItem else { return }
        let current = installationID
        seekID = UUID()
        let operation = seekID
        let target = clamp(seconds)
        seeking = true
        playbackError = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] complete in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.stopped, self.seekID == operation,
                      self.installationID == current, self.player.currentItem === item else { return }
                self.seeking = false
                guard complete else {
                    self.playbackError = "Не удалось перемотать видео. Повторите попытку или смените качество."
                    return
                }
                self.position = target
                self.lastPosition = target
                self.ended = false
                if resume { self.wantsPlayback = true; self.player.play(); self.isPlaying = true }
                self.savePosition(force: true)
            }
        }
    }

    func suspend() {
        guard !stopped else { return }
        savePosition(force: true)
        active = false
        wantsPlayback = false
        installationID = UUID()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        isPlaying = false
        seeking = false
        cancelScrub()
    }

    func activate() {
        guard !active, !stopped else { return }
        active = true
        // Reprepare an interrupted initial seek, but foregrounding never requests playback.
        install(source: currentSource, at: lastPosition)
    }

    func stop() {
        guard !stopped else { return }
        savePosition(force: true)
        stopped = true
        active = false
        wantsPlayback = false
        installationID = UUID()
        ready = false
        player.pause()
        isPlaying = false
        cancelScrub()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        itemObservation = nil
        pauseObservation = nil
        player.replaceCurrentItem(with: nil)
        #if os(tvOS)
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { progressWarning = "Аудиосессия не завершилась штатно." }
        #endif
    }

    private func install(source: VideoSource, at seconds: Double) {
        guard active, !stopped else { return }
        installationID = UUID()
        let current = installationID
        currentSource = source
        player.currentItem?.cancelPendingSeeks()
        ready = false
        preparing = true
        seeking = false
        ended = false
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        let item = makeItem(source)
        #if os(tvOS)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = (request.video.title.isEmpty ? request.post.title : request.video.title) as NSString
        title.extendedLanguageTag = "und"
        let author = AVMutableMetadataItem()
        author.identifier = .iTunesMetadataTrackSubTitle
        author.value = request.post.author as NSString
        author.extendedLanguageTag = "und"
        item.externalMetadata = [title, author]
        item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timeline.navigationMetadata)]
        #endif
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.stopped, self.installationID == current, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    let duration = item.duration.seconds
                    if duration.isFinite && duration > 0 { self.duration = duration }
                    #if os(tvOS)
                    item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: self.timeline.navigationMetadata)]
                    #endif
                    let start = max(0, duration.isFinite && duration > 0 ? min(seconds, duration) : seconds)
                    self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] complete in
                        Task { @MainActor [weak self] in
                            guard let self, self.active, !self.stopped, self.installationID == current, self.player.currentItem === item else { return }
                            self.preparing = false
                            guard complete else {
                                self.playbackError = "Не удалось перемотать видео. Повторите попытку или смените качество."
                                return
                            }
                            self.ready = true
                            self.lastPosition = start
                            self.position = start
                            self.isPlaying = self.wantsPlayback
                            if self.wantsPlayback { self.player.play() }
                        }
                    }
                case .failed:
                    self.preparing = false
                    self.playbackError = "Не удалось воспроизвести видео. Обновите ссылку; при повторной ошибке выберите другое качество."
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.installationID == current, self.player.currentItem === item else { return }
                self.updatePosition()
                self.ended = true
                self.isPlaying = false
                self.savePosition(force: true)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func updatePosition() {
        guard ready, active, !stopped else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 { position = seconds; lastPosition = seconds }
        if let value = player.currentItem?.duration.seconds, value.isFinite, value > 0 { duration = value }
    }

    private func savePosition(force: Bool) {
        guard ready, active, !stopped else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0, seconds <= 604800 else { return }
        lastPosition = seconds
        let wholeSeconds = Int(seconds)
        if let last = lastQueuedSeconds, request.progress.warning == nil,
           wholeSeconds == last || (!force && abs(wholeSeconds - last) < 15) { return }
        lastQueuedSeconds = wholeSeconds
        request.progress.enqueue(videoID: request.video.id, seconds: seconds)
    }
}
