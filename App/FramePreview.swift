import BoostyCore
import Foundation
import SwiftUI

@MainActor
final class FramePreview: ObservableObject {
    typealias Request = (String, String, String, Double) async throws -> VideoPreview
    @Published private(set) var frame: VideoPreview?
    @Published private(set) var selectedSeconds: Double?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private struct Key: Hashable {
        let blog: String
        let post: String
        let content: String
        let seconds: Double
        func sameVideo(as other: Key) -> Bool {
            blog == other.blog && post == other.post && content == other.content
        }
    }
    private struct Entry {
        let frame: VideoPreview
        let expires: Date
        let cost: Int
    }
    private var cache: [Key: Entry] = [:]
    private var recency: [Key] = []
    private var scope: String?
    private var selected: Key?
    private var selectionID = UUID()
    private var active = true
    private var task: Task<Void, Never>?
    private var pending: (id: UUID, key: Key, task: Task<VideoPreview, Error>)?
    private let request: Request
    private let now: () -> Date

    convenience init(client: BrokerClient) {
        self.init { blog, post, content, seconds in
            try await client.preview(blog: blog, postID: post, contentID: content, seconds: seconds)
        }
    }
    init(request: @escaping Request, now: @escaping () -> Date = Date.init) {
        self.request = request
        self.now = now
    }

    func cancel() {
        selectionID = UUID()
        task?.cancel(); task = nil
        pending?.task.cancel(); pending = nil
        selected = nil
        frame = nil; selectedSeconds = nil; loading = false; error = nil
    }

    func invalidate() {
        cancel()
        active = false
        cache.removeAll(); recency.removeAll(); scope = nil
    }

    func select(post: Post, video: Video, seconds: Double, preferChapters: Bool = false, duration: Double? = nil) {
        guard active else { return }
        let newScope = post.blog + "/" + post.id
        if newScope != scope {
            cancel(); cache.removeAll(); recency.removeAll(); scope = newScope
        }
        guard seconds.isFinite, seconds >= 0, let content = video.contentId, !content.isEmpty else {
            cancel(); selectedSeconds = seconds.isFinite ? seconds : nil
            error = "Кадр недоступен. Перемотка остаётся доступной."
            return
        }
        let length = duration ?? video.duration
        let end = length.isFinite && length > 0 ? max(0, ceil(length) - 1) : 604800
        let key = Key(blog: post.blog, post: post.id, content: content, seconds: seconds)
        if selected == key, loading { return }
        let promoted = pending?.key == key ? pending?.task : nil
        task?.cancel()
        if promoted == nil { pending?.task.cancel(); pending = nil }
        selectionID = UUID()
        let selection = selectionID
        selected = key; selectedSeconds = key.seconds; error = nil
        evictExpired()
        if let exact = cached(key) { frame = exact; loading = false }
        else {
            frame = cache.filter { $0.key.sameVideo(as: key) }
                .min { abs($0.key.seconds - key.seconds) < abs($1.key.seconds - key.seconds) }?.value.frame
            loading = true
        }
        let chapters = post.body.filter {
            $0.type == "timecode" && $0.videoId == video.id && $0.seconds?.isFinite == true
                && $0.seconds! >= 0 && $0.seconds! <= end && $0.seconds! != key.seconds
        }.compactMap(\.seconds).sorted { abs($0-key.seconds) < abs($1-key.seconds) }.prefix(2)
        let neighbors = [min(end, key.seconds + 10), max(0, key.seconds - 10)]
        let candidates = preferChapters ? Array(chapters) + neighbors : neighbors + Array(chapters)
        var seen: Set<Double> = [key.seconds]
        let nearby = candidates.filter { seen.insert($0).inserted }.prefix(4).map {
            Key(blog: key.blog, post: key.post, content: key.content, seconds: $0)
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if loading {
                    if promoted == nil { try await Task.sleep(for: .milliseconds(250)) }
                    guard valid(selection) else { return }
                    let value = try await fetch(key, promoted: promoted)
                    guard valid(selection) else { return }
                    insert(value, for: key)
                    frame = value; loading = false
                }
                try await Task.sleep(for: .milliseconds(100))
                for neighbor in nearby {
                    guard valid(selection) else { return }
                    if cached(neighbor) != nil { continue }
                    do {
                        let value = try await fetch(neighbor)
                        guard valid(selection) else { return }
                        insert(value, for: neighbor)
                    } catch {
                        guard valid(selection) else { return }
                        if denied(error) { clearDenied(); return }
                    }
                }
            } catch {
                guard valid(selection) else { return }
                if denied(error) { clearDenied() }
                else { frame = nil; loading = false; self.error = "Кадр недоступен. Перемотка остаётся доступной." }
            }
        }
    }

    private func valid(_ id: UUID) -> Bool { active && selectionID == id && !Task.isCancelled }
    private func denied(_ error: Error) -> Bool { [401, 403].contains((error as? BrokerError)?.status ?? 0) }
    private func clearDenied() {
        cache.removeAll(); recency.removeAll()
        frame = nil; loading = false; error = "Кадр недоступен. Перемотка остаётся доступной."
    }
    private func fetch(_ key: Key, promoted: Task<VideoPreview, Error>? = nil) async throws -> VideoPreview {
        let operation = promoted ?? Task { try await request(key.blog, key.post, key.content, key.seconds) }
        let id = UUID()
        pending = (id, key, operation)
        defer { if pending?.id == id { pending = nil } }
        let value = try await operation.value
        guard value.seconds == key.seconds else { throw BrokerError(code: "invalid_response") }
        return value
    }
    private func cached(_ key: Key) -> VideoPreview? {
        evictExpired()
        guard let entry = cache[key] else { return nil }
        recency.removeAll { $0 == key }; recency.append(key)
        return entry.frame
    }
    private func evictExpired() {
        let expired = cache.filter { $0.value.expires <= now() }.map(\.key)
        for key in expired { cache[key] = nil }
        recency.removeAll { cache[$0] == nil }
    }
    private func insert(_ frame: VideoPreview, for key: Key) {
        // Bound base64 and identity storage with the same UTF-16 byte estimate as the Samsung client.
        let cost = (frame.image.utf16.count + key.blog.utf16.count + key.post.utf16.count + key.content.utf16.count + 32) * 2
        cache[key] = Entry(frame: frame, expires: now().addingTimeInterval(300), cost: cost)
        recency.removeAll { $0 == key }; recency.append(key)
        evictExpired()
        var bytes = cache.values.reduce(0) { $0 + $1.cost }
        while cache.count > 32 || bytes > 4 * 1024 * 1024 {
            guard let oldest = recency.first else { break }
            bytes -= cache.removeValue(forKey: oldest)?.cost ?? 0
            recency.removeFirst()
        }
    }
}

#if os(tvOS)
struct FramePreviewCard: View {
    @ObservedObject var previews: FramePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let frame = previews.frame,
               let data = Data(base64Encoded: String(frame.image.dropFirst("data:image/jpeg;base64,".count))),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 400, maxHeight: 220)
                if frame.seconds != previews.selectedSeconds {
                    Text("Кадр на \(AppLanguage.duration(frame.seconds))").font(.caption)
                }
            }
            if let seconds = previews.selectedSeconds { Text(AppLanguage.duration(seconds)).monospacedDigit() }
            if previews.loading { ProgressView("Загрузка кадра…") }
            if let error = previews.error { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
