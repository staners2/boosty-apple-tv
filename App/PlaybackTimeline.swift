import BoostyCore
import AVFoundation
import Foundation

struct PlaybackTimeline {
    struct Segment: Identifiable {
        let start: Double
        let end: Double
        var id: Double { start }
        func fill(at seconds: Double) -> Double {
            guard seconds.isFinite, end > start else { return 0 }
            return min(1, max(0, (seconds - start) / (end - start)))
        }
    }
    let chapters: [PostBodyBlock]
    let segments: [Segment]
    let duration: Double

    init(body: [PostBodyBlock], videoID: String, duration: Double) {
        self.duration = duration
        var seen = Set<Double>()
        chapters = body.filter {
            guard $0.type == "timecode", $0.videoId == videoID, let seconds = $0.seconds,
                  seconds.isFinite, seconds >= 0 else { return false }
            if duration.isFinite, duration > 0, seconds >= duration { return false }
            return seen.insert(seconds).inserted
        }.sorted { $0.seconds! < $1.seconds! }
        let boundaries = [0] + chapters.compactMap(\.seconds).filter { $0 > 0 } + [duration]
        segments = duration.isFinite && duration > 0
            ? zip(boundaries, boundaries.dropFirst()).map { Segment(start: $0, end: $1) } : []
    }

    func chapter(at seconds: Double) -> PostBodyBlock? {
        chapters.last { ($0.seconds ?? 0) <= seconds }
    }

    var navigationMetadata: [AVTimedMetadataGroup] {
        guard duration.isFinite, duration > 0 else { return [] }
        return chapters.enumerated().compactMap { index, chapter in
            guard let start = chapter.seconds else { return nil }
            let end = index + 1 < chapters.count ? chapters[index + 1].seconds ?? duration : duration
            let title = [chapter.title, chapter.description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? AppLanguage.duration(start)
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            return AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600)))
        }
    }

}
