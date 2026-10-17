import BoostyCore
import Foundation
import SwiftUI

@MainActor
final class PlaybackProgress: ObservableObject {
    typealias Writer = (String, Double) async throws -> Void
    struct Snapshot {
        fileprivate let revision: UInt64
        fileprivate let positions: [String: Double]
    }
    private struct Position {
        let revision: UInt64
        let seconds: Double
    }
    @Published private(set) var warning: String?
    private var tail: Task<Void, Never>?
    private var pending: [String: Position] = [:]
    private var latest: [String: Position] = [:]
    private var revision: UInt64 = 0
    private var active = true
    private let write: Writer

    init(writer: @escaping Writer) { write = writer }
    convenience init(client: BrokerClient) {
        self.init { videoID, seconds in try await client.saveProgress(videoID: videoID, seconds: seconds) }
    }

    func enqueue(videoID: String, seconds: Double) {
        guard active, seconds.isFinite, (0...604800).contains(seconds) else { return }
        revision &+= 1
        let position = Position(revision: revision, seconds: seconds)
        pending[videoID] = position
        latest[videoID] = position
        let previous = tail
        tail = Task {
            await previous?.value
            guard active, !Task.isCancelled else { return }
            do {
                try await write(videoID, seconds)
                guard active else { return }
                if pending[videoID]?.revision == position.revision { pending[videoID] = nil }
                if pending.isEmpty { warning = nil }
            } catch {
                guard active else { return }
                warning = "Позиция просмотра не синхронизирована. До закрытия приложения продолжение доступно с локальной позиции. Проверьте соединение."
            }
        }
    }

    func flush(timeout: Duration = .seconds(25)) async {
        guard let tail else { return }
        await withCheckedContinuation { continuation in
            var finished = false
            let timer = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                guard !finished else { return }
                finished = true
                if active {
                    warning = "Синхронизация позиции задерживается. До закрытия приложения доступна локальная позиция."
                }
                continuation.resume()
            }
            Task {
                await tail.value
                guard !finished else { return }
                finished = true
                timer.cancel()
                continuation.resume()
            }
        }
    }
    func snapshot() -> Snapshot {
        Snapshot(revision: revision, positions: pending.mapValues(\.seconds))
    }

    func localPosition(videoID: String, snapshot: Snapshot) -> Double? {
        guard active else { return nil }
        // Acknowledgements may clear pending during a read; a later local seek still takes priority.
        if let position = latest[videoID], position.revision > snapshot.revision { return position.seconds }
        return snapshot.positions[videoID]
    }

    func localPosition(videoID: String) -> Double? { pending[videoID]?.seconds }
    func invalidate() {
        active = false
        pending = [:]
        latest = [:]
        tail?.cancel()
    }
}
