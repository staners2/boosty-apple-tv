import BoostyCore
import SwiftUI

struct PostView: View {
    @ObservedObject var model: AppModel
    let initialPost: Post
    @State private var detail: Post?
    @State private var detailError: String?
    @State private var loading = true
    @State private var phoneLink: PhoneLink?
    @FocusState private var focusedChapter: Int?

    private var post: Post { detail ?? initialPost }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: post.author).font(.headline).foregroundStyle(.orange)
                    Text(verbatim: post.title).font(.title).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: model.language.date(post.publishedAt))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
                if loading { ProgressView() }
                if let error = detailError {
                    ErrorBanner(message: error)
                    Button("Повторить загрузку") { Task { await refresh() } }
                }
                if post.locked {
                    Label("Для просмотра нужна подписка на автора в Boosty", systemImage: "lock.fill")
                        .foregroundStyle(.orange).focusable()
                } else {
                    ForEach(post.videos) { video in videoCard(video) }
                }
                if model.preparingVideo { ProgressView("Обновление ссылки на видео…") }
                if let error = model.errorMessage { ErrorBanner(message: error) }
                ForEach(Array(post.body.enumerated()), id: \.offset) { index, block in
                    bodyBlock(block, index: index)
                }
                if !loading, !post.locked, post.videos.isEmpty, post.body.isEmpty {
                    Text("В этой публикации пока нет содержимого.").foregroundStyle(.secondary).focusable()
                }
            }
            .frame(maxWidth: 1240, alignment: .leading)
            .padding(.horizontal, 80).padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("post-reader")
        .task(id: model.playbackRevision) { await refresh() }
        .onChange(of: focusedChapter) { _, index in
            guard let index, post.body.indices.contains(index) else { model.previews?.cancel(); return }
            let block = post.body[index]
            guard let seconds = block.seconds, let video = post.videos.first(where: { $0.id == block.videoId }) else { return }
            model.previews?.select(post: post, video: video, seconds: seconds, preferChapters: true)
        }
        .onDisappear { model.cancelOpening(); model.previews?.cancel() }
        .sheet(item: $phoneLink) { link in
            PhoneLinkView(link: link, model: model).accessibilityIdentifier("phone-link-qr")
        }
    }

    private func videoCard(_ video: Video) -> some View {
        HStack(alignment: .top, spacing: 28) {
            RemoteImage(url: video.preview ?? post.preview, title: video.title)
                .frame(width: 320, height: 180).clipped()
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: video.title.isEmpty ? post.title : video.title).font(.headline)
                if video.duration > 0 { Text(verbatim: AppLanguage.duration(video.duration)).foregroundStyle(.secondary) }
                HStack(spacing: 24) {
                    Button { Task { await model.play(post: post, videoID: video.id) } } label: {
                        if model.resumeSeconds(for: video) > 0 {
                            Label("Продолжить с \(AppLanguage.duration(model.resumeSeconds(for: video)))", systemImage: "play.fill")
                        } else { Label("Смотреть видео", systemImage: "play.fill") }
                    }
                    .disabled(video.playableSources.isEmpty || model.preparingVideo)
                    .accessibilityIdentifier("post-play:\(video.id)")
                    if model.resumeSeconds(for: video) > 0 {
                        Button("С начала") { Task { await model.play(post: post, videoID: video.id, at: 0) } }
                            .disabled(model.preparingVideo)
                    }
                    if video.playableSources.count > 1 {
                        Menu("Качество") {
                            ForEach(video.playableSources) { source in
                                Button(source.label) { Task { await model.play(post: post, videoID: video.id, quality: source.quality) } }
                            }
                        }.disabled(model.preparingVideo)
                    }
                }
                if video.playableSources.isEmpty {
                    Text("Нет источника HLS или MP4, поддерживаемого Apple TV.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private func bodyBlock(_ block: PostBodyBlock, index: Int) -> some View {
        switch block.type {
        case "text":
            if let text = block.text {
                ForEach(Array(readingSections(text).enumerated()), id: \.offset) { section, text in
                    ReadingSection(text: text)
                        .accessibilityIdentifier("reader-block:\(index):\(section)")
                }
            }
        case "image":
            RemoteImage(url: block.url, title: block.title ?? "")
                .frame(maxWidth: 1200, maxHeight: 620).padding(24).focusable()
                .accessibilityIdentifier("reader-block:\(index)")
        case "timecode":
            if !post.locked, let videoID = block.videoId, let seconds = block.seconds,
               seconds.isFinite, seconds >= 0, post.videos.contains(where: { $0.id == videoID }) {
                VStack(alignment: .leading, spacing: 16) {
                    Button { Task { await model.play(post: post, videoID: videoID, at: seconds) } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(AppLanguage.duration(seconds))  \(block.title ?? "")", systemImage: "list.bullet.rectangle")
                            if let description = block.description { Text(verbatim: description).font(.caption) }
                        }
                    }
                    .disabled(model.preparingVideo)
                    .focused($focusedChapter, equals: index)
                    .accessibilityIdentifier("chapter:\(videoID):\(Int(min(seconds, 604800)))")
                    if focusedChapter == index, let previews = model.previews { FramePreviewCard(previews: previews).accessibilityIdentifier("frame-preview") }
                }
            }
        case "link", "file":
            if let url = block.url {
                Button { phoneLink = PhoneLink(url: url, title: block.title ?? post.title) } label: {
                    Label(block.title ?? post.title, systemImage: block.type == "file" ? "doc" : "link")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("phone-link:\(index)")
            }
        default: EmptyView()
        }
    }

    private func refresh() async {
        loading = true
        detailError = nil
        defer { loading = false }
        do { detail = try await model.fetchPost(initialPost) }
        catch is CancellationError {}
        catch { if !Task.isCancelled { detailError = AppLanguage.errorKey(error) } }
    }
}

private struct ReadingSection: View {
    let text: String
    @FocusState private var focused: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.body).lineSpacing(10)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 18)
            .background(.white.opacity(focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(focused ? 0.4 : 0), lineWidth: 2)
            }
            .focusable().focused($focused)
            .focusEffectDisabled()
    }
}
