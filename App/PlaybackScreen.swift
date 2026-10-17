import AVFoundation
import AVKit
import BoostyCore
import SwiftUI

struct PlaybackScreen: View {
    let request: PlaybackRequest
    @StateObject private var playback: PlaybackController
    @ObservedObject private var progress: PlaybackProgress
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controls = false

    init(request: PlaybackRequest) {
        self.request = request
        _progress = ObservedObject(wrappedValue: request.progress)
        _playback = StateObject(wrappedValue: PlaybackController(request: request))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NativePlayer(playback: playback, close: { playback.stop(); dismiss() }, controls: { controls = true })
                .ignoresSafeArea()
            if let error = playback.playbackError {
                VStack(spacing: 24) {
                    ErrorBanner(message: error)
                    HStack(spacing: 30) {
                        Button("Обновить ссылку и повторить") { Task { await playback.retry() } }
                        Button("Управление видео", systemImage: "slider.horizontal.3") { controls = true }
                            .accessibilityIdentifier("player-controls")
                        Button("К публикации") { playback.stop(); dismiss() }
                            .accessibilityIdentifier("player-close")
                    }
                }
                .padding(45).background(.black.opacity(0.9))
            } else if let warning = playback.progressWarning ?? progress.warning {
                Text(LocalizedStringKey(warning)).font(.caption).foregroundStyle(.orange)
                    .padding(20).background(.black.opacity(0.75)).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $controls, onDismiss: { playback.cancelScrub() }) {
            PlaybackPanel(playback: playback, close: { controls = false; playback.stop(); dismiss() })
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { playback.activate() }
            else { playback.suspend() }
        }
        .onAppear { if scenePhase != .active { playback.suspend() } }
        .onDisappear { playback.stop() }
    }
}

private struct PlaybackPanel: View {
    @ObservedObject var playback: PlaybackController
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedChapter: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(playback.video.title.isEmpty ? playback.request.post.title : playback.video.title)
                    .font(.title2).bold()
                HStack {
                    Text("\(AppLanguage.duration(playback.selectedPosition)) / \(AppLanguage.duration(playback.duration))")
                        .monospacedDigit().accessibilityIdentifier("player-position")
                    Spacer()
                    if playback.currentSource.quality == "hls" { Text("Авто") }
                    else { Text(playback.currentSource.label) }
                }
                segmentedTimeline
                if let chapter = playback.timeline.chapter(at: playback.selectedPosition) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chapter.title ?? chapter.description ?? "").font(.headline)
                            .accessibilityIdentifier("player-current-chapter")
                        if let description = chapter.description, description != chapter.title {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if playback.preparing { ProgressView("Подготовка видео…") }
                if playback.seeking { ProgressView("Перемотка…") }
                if let error = playback.playbackError { ErrorBanner(message: error) }
                if playback.scrubSeconds != nil { scrubControls }
                else { playbackControls }
                if let previews = playback.request.previews,
                   playback.scrubSeconds != nil || focusedChapter != nil {
                    FramePreviewCard(previews: previews).accessibilityIdentifier("frame-preview")
                }
                if playback.scrubSeconds == nil {
                    ForEach(playback.timeline.chapters, id: \.seconds) { chapter in
                        if let seconds = chapter.seconds {
                            Button {
                                playback.seek(to: seconds)
                                playback.request.previews?.cancel()
                            } label: {
                                HStack(alignment: .top, spacing: 20) {
                                    Text(AppLanguage.duration(seconds)).monospacedDigit()
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(chapter.title ?? "")
                                        if let description = chapter.description { Text(description).font(.caption) }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(playback.preparing)
                            .focused($focusedChapter, equals: seconds)
                            .accessibilityIdentifier("player-chapter:\(Int(seconds))")
                        }
                    }
                }
                HStack(spacing: 24) {
                    Button("К просмотру") { playback.cancelScrub(); dismiss() }
                        .accessibilityIdentifier("player-return")
                    Button("К публикации", action: close).accessibilityIdentifier("player-close")
                }
            }.padding(60)
        }
        .onChange(of: focusedChapter) { _, seconds in
            if let seconds { playback.previewChapter(seconds) }
            else if playback.scrubSeconds == nil { playback.request.previews?.cancel() }
        }
        .onExitCommand {
            if playback.scrubSeconds != nil { playback.cancelScrub() }
            else { dismiss() }
        }
        .onPlayPauseCommand { playback.togglePlayback() }
        .onDisappear { playback.cancelScrub() }
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button {
                playback.togglePlayback()
            } label: {
                Label(LocalizedStringKey(playback.ended ? "Повторить видео" : playback.isPlaying ? "Пауза" : "Продолжить"),
                      systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
            }.accessibilityIdentifier("player-toggle")
            Button("Перемотать", systemImage: "timeline.selection") { playback.beginScrub() }
                .disabled(playback.duration <= 0).accessibilityIdentifier("player-scrub")
            Menu {
                ForEach(playback.video.playableSources) { source in
                    Button {
                        Task { await playback.changeQuality(source) }
                    } label: {
                        if source.quality == "hls" { Text("Авто") }
                        else { Text(source.label) }
                    }
                    .accessibilityIdentifier("player-quality:\(source.quality)")
                }
            } label: { Label("Качество", systemImage: "gearshape") }
                .accessibilityIdentifier("player-quality")
            Button("С начала", systemImage: "backward.end.fill") { playback.restart() }
                .accessibilityIdentifier("player-restart")
        }
        .disabled(playback.preparing || playback.seeking)
    }

    private var scrubControls: some View {
        HStack(spacing: 24) {
            Button("−10 с") { playback.moveScrub(by: -10) }.accessibilityIdentifier("scrub-backward")
            Button("+10 с") { playback.moveScrub(by: 10) }.accessibilityIdentifier("scrub-forward")
            Button("Перейти") { playback.commitScrub() }.accessibilityIdentifier("scrub-confirm")
            Button("Отменить") { playback.cancelScrub() }.accessibilityIdentifier("scrub-cancel")
        }
    }

    private var segmentedTimeline: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 6) {
                ForEach(playback.timeline.segments) { segment in
                    let width = max(0, (geometry.size.width - CGFloat(max(0, playback.timeline.segments.count - 1)) * 6)
                                    * (segment.end - segment.start) / playback.duration)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(.orange)
                                    .frame(width: width * segment.fill(at: playback.selectedPosition))
                            }.frame(height: 12)
                        if let chapter = playback.timeline.chapter(at: segment.start) {
                            Text(chapter.title ?? chapter.description ?? "")
                                .font(.caption2).lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }.frame(width: width, alignment: .leading)
                }
            }
        }
        .frame(height: 48)
        .accessibilityLabel("Шкала глав")
        .accessibilityIdentifier("player-timeline")
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    @ObservedObject var playback: PlaybackController
    @Environment(\.locale) private var locale
    let close: () -> Void
    let controls: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close, playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.delegate = context.coordinator
        updateMenus(controller, coordinator: context.coordinator)
        return controller
    }

    private func updateMenus(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        let language = AppLanguage(rawValue: locale.language.languageCode?.identifier ?? "en") ?? .en
        guard coordinator.menuLanguage != language else { return }
        coordinator.menuLanguage = language
        let chapters = playback.request.post.body.compactMap { block -> UIAction? in
            guard block.type == "timecode", block.videoId == playback.request.video.id,
                  let seconds = block.seconds, seconds.isFinite, seconds >= 0 else { return nil }
            return UIAction(title: block.title ?? language.text("Глава"), image: UIImage(systemName: "list.bullet")) { _ in
                playback.seek(to: seconds)
            }
        }
        let controlsAction = UIAction(title: language.text("Управление видео"),
                                      image: UIImage(systemName: "slider.horizontal.3"),
                                      identifier: UIAction.Identifier("player-controls")) { _ in controls() }
        controller.transportBarCustomMenuItems = [controlsAction]
        if !chapters.isEmpty {
            controller.transportBarCustomMenuItems.append(UIMenu(title: language.text("Главы"),
                image: UIImage(systemName: "list.bullet.rectangle"), children: chapters))
        }
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        updateMenus(controller, coordinator: context.coordinator)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.playback.stop()
        controller.player = nil
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let close: () -> Void
        let playback: PlaybackController
        var menuLanguage: AppLanguage?
        init(close: @escaping () -> Void, playback: PlaybackController) {
            self.close = close
            self.playback = playback
        }
        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool { true }
        func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in
                playback.stop()
                close()
            }
        }
    }
}
