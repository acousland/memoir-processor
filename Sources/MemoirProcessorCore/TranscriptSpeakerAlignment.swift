import Foundation

public enum TranscriptSpeakerAlignment {
    public static func apply(to segments: [TranscriptSegment], turns: [DiarizationTurn], speakersByCluster: [String: SessionSpeaker]) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            let words = segment.words ?? []
            let wordText = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let hasWords = !words.isEmpty && wordText == segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let units = hasWords ? words : [TranscriptWord(start: segment.start, end: segment.end, text: segment.text)]
            var groups: [(cluster: String?, words: [TranscriptWord])] = []
            for word in units {
                let candidates = turns.filter { turn in
                    (segment.speakerSource == nil || segment.speakerSource == turn.sourceTrack) &&
                    turn.start <= word.end && turn.end >= word.start
                }
                let matched = candidates.max {
                    max(0, min($0.end, word.end) - max($0.start, word.start)) < max(0, min($1.end, word.end) - max($1.start, word.start))
                }
                let cluster = matched?.clusterID
                if groups.last?.cluster == cluster, !groups.isEmpty { groups[groups.count - 1].words.append(word) }
                else { groups.append((cluster, [word])) }
            }
            return groups.compactMap { group in
                guard let first = group.words.first, let last = group.words.last else { return nil }
                let speaker = group.cluster.flatMap { speakersByCluster[$0] }
                let text = group.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(id: groups.count == 1 ? segment.id : UUID(), start: first.start, end: last.end,
                    speaker: speaker?.displayLabel ?? segment.speaker,
                    speakerID: speaker?.matchedProfileID ?? group.cluster ?? segment.speakerID,
                    clusterID: group.cluster ?? segment.clusterID,
                    speakerSource: speaker?.sourceTrack ?? segment.speakerSource,
                    speakerConfidence: speaker?.matchConfidence ?? segment.speakerConfidence,
                    text: text, words: hasWords ? group.words : segment.words)
            }
        }
    }
}
