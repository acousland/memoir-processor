import Foundation

public enum LiveSpeakerConstants {
    public static let embeddingSpace = "fluidaudio-live-wespeaker-v2-0.17.7"
}

public struct LiveAudioChunk: Codable, Sendable {
    public let sequence: Int
    public let sourceTrack: SpeakerSource
    public let firstSampleHostTimeNs: String
    public let sampleRateHz: Int
    public let pcmBase64: String

    public func validatedPCM() throws -> Data {
        guard sequence >= 0, sequence < 100_000, [.system, .mic].contains(sourceTrack),
              let host = UInt64(firstSampleHostTimeNs), host > 0,
              [16_000, 44_100, 48_000].contains(sampleRateHz),
              pcmBase64.utf8.count <= 600_000,
              let data = Data(base64Encoded: pcmBase64), data.count % 2 == 0,
              data.count >= sampleRateHz / 2, data.count <= sampleRateHz * 8 else {
            throw ProcessorError(code: "invalid_request", message: "Invalid live audio chunk.", retryable: false)
        }
        return data
    }

    public var hostSeconds: Double { Double(firstSampleHostTimeNs).flatMap { $0.isFinite ? $0 / 1_000_000_000 : nil } ?? 0 }
    public var duration: Double { Double((Data(base64Encoded: pcmBase64)?.count ?? 0) / 2) / Double(sampleRateHz) }
}

public struct LiveNameRequest: Codable, Sendable {
    public let speakerID: String
    public let name: String
    public let profileID: String?
}

public struct LiveSpeakerCard: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let profileID: String?
    public let confirmed: Bool
    public let confidence: Double?
    public let lastSeenHostSeconds: Double
    public let sourceTrack: SpeakerSource
    public let speaking: Bool
}

public struct LiveSpeakerSnapshot: Codable, Sendable {
    public let sessionID: String
    public let speakers: [LiveSpeakerCard]
    public let people: [SpeakerProfile]
    public let closed: Bool
}

public struct LiveVoiceSeed: Codable, Sendable {
    public let id: String
    public let embedding: [Double]
    public let duration: Double
}

public struct LiveWorkerTurn: Codable, Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double
    public let quality: Double
}

public struct LiveWorkerOutput: Codable, Sendable {
    public let turns: [LiveWorkerTurn]
    public let speakers: [LiveVoiceSeed]
}

public struct LiveProfileBridge: Sendable {
    public let profileID: String
    public let name: String
    public let confirmed: Bool
    public let confidence: Double
}

public enum LiveVoiceMatching {
    public static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return -1 }
        let norm = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / norm
    }

    public static func confidentMatch(_ vector: [Double], bank: [String: [[Double]]], threshold: Double) -> (id: String, score: Double)? {
        let scores = bank.map { id, vectors in (id, vectors.map { similarity(vector, $0) }.max() ?? -1) }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= max(0.9, threshold),
              scores.count < 2 || best.1 - scores[1].1 >= 0.05 else { return nil }
        return best
    }
}

private struct LabelledLiveInterval {
    let start: Double
    let end: Double
    let source: SpeakerSource
    let profile: LiveProfileBridge
}

private struct LiveIntervalIndex {
    let bySource: [SpeakerSource: [LabelledLiveInterval]]
    let maxDuration: Double

    init(_ intervals: [LabelledLiveInterval]) {
        bySource = Dictionary(grouping: intervals, by: \.source).mapValues { $0.sorted { $0.start < $1.start } }
        maxDuration = intervals.map { $0.end - $0.start }.max() ?? 0
    }

    func intersecting(_ turn: DiarizationTurn) -> [LabelledLiveInterval] {
        let intervals = bySource[turn.sourceTrack] ?? []
        var low = 0, high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if intervals[middle].start < turn.start - maxDuration { low = middle + 1 }
            else { high = middle }
        }
        var result: [LabelledLiveInterval] = []
        while low < intervals.count && intervals[low].start < turn.end {
            if intervals[low].end > turn.start { result.append(intervals[low]) }
            low += 1
        }
        return result
    }
}

extension SessionStore {
    func migrateLiveSpeakers() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS live_sessions (
                session_id TEXT PRIMARY KEY, closed INTEGER NOT NULL DEFAULT 0, processed_through REAL NOT NULL DEFAULT 0, updated_at TEXT NOT NULL
            );
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS live_speakers (
                session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, vector_json TEXT NOT NULL,
                duration REAL NOT NULL DEFAULT 0, profile_id TEXT, confirmed INTEGER NOT NULL DEFAULT 0,
                confidence REAL, last_seen REAL NOT NULL DEFAULT 0, source_track TEXT NOT NULL,
                PRIMARY KEY(session_id, speaker_id)
            );
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS live_chunks (
                session_id TEXT NOT NULL, source_track TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL,
                PRIMARY KEY(session_id, source_track, sequence)
            );
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS live_turns (
                session_id TEXT NOT NULL, speaker_id TEXT NOT NULL, source_track TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL
            );
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS live_turns_session ON live_turns(session_id);")
    }

    public func beginLiveSession(_ sessionID: String) throws -> LiveSpeakerSnapshot {
        guard UUID(uuidString: sessionID) != nil else { throw liveError("Invalid live session ID.") }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        let count = try database.fetchOne("SELECT COUNT(*) AS count FROM live_sessions WHERE closed=0 AND updated_at>?", bindings: [.text(cutoff)])?["count"]?.intValue ?? 0
        let exists = try database.fetchOne("SELECT session_id FROM live_sessions WHERE session_id=?", bindings: [.text(sessionID)]) != nil
        guard count < 8 || exists else {
            throw ProcessorError(code: "live_busy", message: "The processor is handling too many live recordings.", retryable: true)
        }
        try database.execute("INSERT INTO live_sessions(session_id,updated_at) VALUES (?,?) ON CONFLICT(session_id) DO NOTHING", bindings: [.text(sessionID), .text(Time.nowString())])
        return try liveSnapshot(sessionID)
    }

    public func liveSnapshot(_ sessionID: String) throws -> LiveSpeakerSnapshot {
        guard UUID(uuidString: sessionID) != nil,
              let session = try database.fetchOne("SELECT closed,processed_through FROM live_sessions WHERE session_id=?", bindings: [.text(sessionID)]) else {
            throw ProcessorError(code: "live_not_found", message: "Live speaker session not found.", retryable: false)
        }
        let rows = try database.fetchAll("""
            SELECT l.*, p.display_name, p.archived FROM live_speakers l
            LEFT JOIN speaker_profiles p ON l.profile_id=p.speaker_profile_id
            WHERE session_id=? ORDER BY length(speaker_id), speaker_id
            """, bindings: [.text(sessionID)])
        let latest = session["processed_through"]?.doubleValue ?? 0
        let cards = rows.map { row in
            let id = row["speaker_id"]?.stringValue ?? ""
            let available = row["archived"]?.boolValue != true
            let profile = available ? row["profile_id"]?.stringValue : nil
            let last = row["last_seen"]?.doubleValue ?? 0
            return LiveSpeakerCard(id: id, name: profile == nil ? "Speaker \(id)" : row["display_name"]?.stringValue ?? "Speaker \(id)",
                profileID: profile, confirmed: row["confirmed"]?.boolValue ?? false,
                confidence: row["confidence"]?.doubleValue, lastSeenHostSeconds: last,
                sourceTrack: SpeakerSource(rawValue: row["source_track"]?.stringValue ?? "") ?? .unknown,
                speaking: last > 0 && latest - last < 0.75)
        }
        // Several acoustic clusters can belong to the same named person. Keep
        // one card, using the most recent raw identity for corrections.
        let grouped = Dictionary(grouping: cards) { $0.profileID.map { "person:" + $0 } ?? "voice:" + $0.id }
        let peopleCards = grouped.values.sorted {
            ($0.compactMap { Int($0.id) }.min() ?? 0) < ($1.compactMap { Int($0.id) }.min() ?? 0)
        }.compactMap { group -> LiveSpeakerCard? in
            guard let recent = group.max(by: { $0.lastSeenHostSeconds < $1.lastSeenHostSeconds }) else { return nil }
            return LiveSpeakerCard(id: recent.id, name: recent.name, profileID: recent.profileID,
                confirmed: recent.confirmed, confidence: recent.confidence, lastSeenHostSeconds: recent.lastSeenHostSeconds,
                sourceTrack: recent.sourceTrack, speaking: group.contains(where: \.speaking))
        }
        return LiveSpeakerSnapshot(sessionID: sessionID, speakers: peopleCards, people: try listSpeakerProfiles(), closed: session["closed"]?.boolValue ?? false)
    }

    public func closeLiveSession(_ sessionID: String) throws -> LiveSpeakerSnapshot {
        _ = try liveSnapshot(sessionID)
        try database.execute("UPDATE live_sessions SET closed=1,updated_at=? WHERE session_id=?", bindings: [.text(Time.nowString()), .text(sessionID)])
        return try liveSnapshot(sessionID)
    }

    public func liveSeeds(_ sessionID: String) throws -> [LiveVoiceSeed] {
        try database.fetchAll("SELECT speaker_id,vector_json,duration FROM live_speakers WHERE session_id=?", bindings: [.text(sessionID)]).compactMap { row in
            guard let id = row["speaker_id"]?.stringValue, let json = row["vector_json"]?.stringValue,
                  let vector = try? JSONDecoder.memoir.decode([Double].self, from: Data(json.utf8)) else { return nil }
            return LiveVoiceSeed(id: id, embedding: vector, duration: row["duration"]?.doubleValue ?? 0)
        }
    }

    public func hasLiveChunk(_ sessionID: String, chunk: LiveAudioChunk) throws -> Bool {
        guard let row = try database.fetchOne("SELECT digest FROM live_chunks WHERE session_id=? AND source_track=? AND sequence=?", bindings: [.text(sessionID), .text(chunk.sourceTrack.rawValue), .integer(Int64(chunk.sequence))]) else {
            let latest = try database.fetchOne("SELECT MAX(sequence) AS latest FROM live_chunks WHERE session_id=? AND source_track=?", bindings: [.text(sessionID), .text(chunk.sourceTrack.rawValue)])?["latest"]?.intValue ?? -1
            guard chunk.sequence > latest else { throw liveError("Stale live audio chunk.") }
            return false
        }
        guard row["digest"]?.stringValue == Hashing.sha256Hex(for: try JSONEncoder.memoir.encode(chunk)) else { throw liveError("Live chunk sequence was reused with different audio.") }
        return true
    }

    public func applyLiveChunk(_ sessionID: String, chunk: LiveAudioChunk, output: LiveWorkerOutput, threshold: Double) throws -> LiveSpeakerSnapshot {
        try database.transaction {
            guard !(try liveSnapshot(sessionID).closed) else { return try liveSnapshot(sessionID) }
            if try hasLiveChunk(sessionID, chunk: chunk) { return try liveSnapshot(sessionID) }
            let bank = try speakerProfileEmbeddings(embeddingSpace: LiveSpeakerConstants.embeddingSpace)
            let profiles = Dictionary(uniqueKeysWithValues: try listSpeakerProfiles().map { ($0.id, $0) })
            let currentRows = try database.fetchAll("SELECT speaker_id,profile_id,confirmed,confidence FROM live_speakers WHERE session_id=?", bindings: [.text(sessionID)])
            let current = Dictionary(uniqueKeysWithValues: currentRows.compactMap { row -> (String, [String: SQLiteValue])? in
                guard let id = row["speaker_id"]?.stringValue else { return nil }; return (id, row)
            })
            guard output.speakers.count <= 64, output.turns.count <= 200 else { throw liveError("Too many live speakers or turns.") }
            for seed in output.speakers {
                guard let number = Int(seed.id), (1...64).contains(number), seed.embedding.count == 256,
                      seed.embedding.allSatisfy(\.isFinite), seed.duration.isFinite, seed.duration >= 0 else { throw liveError("Invalid live voice embedding.") }
                let turns = output.turns.filter { $0.speakerID == seed.id && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= chunk.duration + 0.1 }
                guard let last = turns.map(\.end).max() else { continue }
                let existing = current[seed.id]
                let match = LiveVoiceMatching.confidentMatch(seed.embedding, bank: bank.filter { profiles[$0.key] != nil }, threshold: threshold)
                let existingProfile = existing?["profile_id"]?.stringValue.flatMap { profiles[$0] == nil ? nil : $0 }
                let profileID = existingProfile ?? match?.id
                let confirmed = existingProfile != nil && (existing?["confirmed"]?.boolValue ?? false)
                try database.execute("""
                    INSERT INTO live_speakers(session_id,speaker_id,vector_json,duration,profile_id,confirmed,confidence,last_seen,source_track)
                    VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(session_id,speaker_id) DO UPDATE SET
                    vector_json=excluded.vector_json,duration=excluded.duration,profile_id=excluded.profile_id,
                    confirmed=excluded.confirmed,confidence=excluded.confidence,last_seen=excluded.last_seen,source_track=excluded.source_track
                    """, bindings: [.text(sessionID), .text(seed.id), .text(String(data: try JSONEncoder.memoir.encode(seed.embedding), encoding: .utf8)!),
                        .double(seed.duration), profileID.map(SQLiteValue.text) ?? .null, .integer(confirmed ? 1 : 0),
                        ((existingProfile == nil ? nil : existing?["confidence"]?.doubleValue) ?? match?.score).map(SQLiteValue.double) ?? .null, .double(chunk.hostSeconds + last), .text(chunk.sourceTrack.rawValue)])
                if confirmed, let profileID, seed.duration >= 2.5, seed.duration <= 30,
                   (bank[profileID]?.isEmpty ?? true) || (bank[profileID]?.map { LiveVoiceMatching.similarity(seed.embedding, $0) }.max() ?? -1) >= 0.95 {
                    try saveVoiceSample(profileID: profileID, sessionID: sessionID, clusterID: "live:" + seed.id,
                        vector: seed.embedding, quality: seed.duration, space: LiveSpeakerConstants.embeddingSpace)
                }
                for turn in turns {
                    try database.execute("INSERT INTO live_turns(session_id,speaker_id,source_track,start,end) VALUES (?,?,?,?,?)", bindings: [.text(sessionID), .text(seed.id), .text(chunk.sourceTrack.rawValue), .double(chunk.hostSeconds + turn.start), .double(chunk.hostSeconds + min(turn.end, chunk.duration))])
                }
            }
            try database.execute("INSERT INTO live_chunks(session_id,source_track,sequence,digest) VALUES (?,?,?,?)", bindings: [.text(sessionID), .text(chunk.sourceTrack.rawValue), .integer(Int64(chunk.sequence)), .text(Hashing.sha256Hex(for: try JSONEncoder.memoir.encode(chunk)))])
            try database.execute("UPDATE live_sessions SET updated_at=?,processed_through=MAX(processed_through,?) WHERE session_id=?", bindings: [.text(Time.nowString()), .double(chunk.hostSeconds + chunk.duration), .text(sessionID)])
            return try liveSnapshot(sessionID)
        }
    }

    public func nameLiveSpeaker(_ sessionID: String, request: LiveNameRequest) throws -> LiveSpeakerSnapshot {
        try database.transaction {
            _ = try liveSnapshot(sessionID)
            guard let row = try database.fetchOne("SELECT vector_json,duration FROM live_speakers WHERE session_id=? AND speaker_id=?", bindings: [.text(sessionID), .text(request.speakerID)]) else { throw liveError("Speaker not found.") }
            let profile = try resolveNamedProfile(name: request.name, profileID: request.profileID)
            try database.execute("UPDATE live_speakers SET profile_id=?,confirmed=1,confidence=1 WHERE session_id=? AND speaker_id=?", bindings: [.text(profile.id), .text(sessionID), .text(request.speakerID)])
            if let json = row["vector_json"]?.stringValue, let vector = try? JSONDecoder.memoir.decode([Double].self, from: Data(json.utf8)),
               (row["duration"]?.doubleValue ?? 0) >= 2.5 {
                try saveVoiceSample(profileID: profile.id, sessionID: sessionID, clusterID: "live:" + request.speakerID, vector: vector, quality: row["duration"]?.doubleValue ?? 0, space: LiveSpeakerConstants.embeddingSpace)
            }
            return try liveSnapshot(sessionID)
        }
    }

    public func resolveNamedProfile(name: String, profileID: String?) throws -> SpeakerProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline) else { throw liveError("Choose a name between 1 and 120 characters.") }
        let profiles = try listSpeakerProfiles()
        if let profileID {
            guard let profile = profiles.first(where: { $0.id == profileID }) else { throw liveError("Person not found.") }
            return profile
        }
        let matching = profiles.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        if matching.count == 1 { return matching[0] }
        return try createSpeakerProfile(name: name)
    }

    public func pendingLiveVoiceSamples() throws -> [(profileID: String, sessionID: String, clusterID: String)] {
        try database.fetchAll("""
            SELECT e.speaker_profile_id,e.source_session_id,e.cluster_id FROM speaker_profile_embeddings e
            JOIN speaker_profiles p ON e.speaker_profile_id=p.speaker_profile_id
            WHERE p.archived=0 AND e.embedding_space!=? AND NOT EXISTS (
                SELECT 1 FROM speaker_profile_embeddings live WHERE live.speaker_profile_id=p.speaker_profile_id AND live.embedding_space=?
            ) ORDER BY e.quality_score DESC LIMIT 64
            """, bindings: [.text(LiveSpeakerConstants.embeddingSpace), .text(LiveSpeakerConstants.embeddingSpace)]).compactMap { row in
                guard let profile = row["speaker_profile_id"]?.stringValue, let session = row["source_session_id"]?.stringValue,
                      let cluster = row["cluster_id"]?.stringValue else { return nil }
                return (profile, session, cluster)
            }
    }

    public func saveVoiceSample(profileID: String, sessionID: String, clusterID: String, vector: [Double], quality: Double, space: String) throws {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.count <= 1024 else { throw liveError("Invalid voice sample.") }
        try database.execute("DELETE FROM speaker_profile_embeddings WHERE source_session_id=? AND cluster_id=? AND embedding_space=?", bindings: [.text(sessionID), .text(clusterID), .text(space)])
        try database.execute("""
            INSERT INTO speaker_profile_embeddings(embedding_id,speaker_profile_id,source_session_id,cluster_id,vector_json,quality_score,created_at,embedding_space)
            VALUES (?,?,?,?,?,?,?,?)
            """, bindings: [.text(UUID().uuidString), .text(profileID), .text(sessionID), .text(clusterID), .text(String(data: try JSONEncoder.memoir.encode(vector), encoding: .utf8)!), .double(quality), .text(Time.nowString()), .text(space)])
        try database.execute("UPDATE speaker_profiles SET updated_at=?,last_seen_at=? WHERE speaker_profile_id=?", bindings: [.text(Time.nowString()), .text(Time.nowString()), .text(profileID)])
    }

    /// Human-labelled live turns may split a batch cluster that merged people.
    /// Embeddings from a split cluster must never train either person's voice.
    public func reconcileLiveTurns(sessionID: String, turns: [DiarizationTurn], zeroHostSeconds: Double) throws -> (turns: [DiarizationTurn], mixedClusters: Set<String>) {
        let index = try liveIntervalIndex(sessionID: sessionID, zeroHostSeconds: zeroHostSeconds)
        guard !index.bySource.isEmpty else { return (turns, []) }
        var result: [DiarizationTurn] = []
        var mixed: Set<String> = []
        for (cluster, clusterTurns) in Dictionary(grouping: turns, by: \.clusterID) {
            if bridge(turns: clusterTurns, index: index) != nil {
                result.append(contentsOf: clusterTurns)
                continue
            }
            for turn in clusterTurns {
                let intervals = index.intersecting(turn).map { interval in
                    (start: max(turn.start, interval.start), end: min(turn.end, interval.end), profile: interval.profile.profileID)
                }
                let cuts = Set([turn.start, turn.end] + intervals.flatMap { [$0.start, $0.end] }).sorted()
                for (start, end) in zip(cuts, cuts.dropFirst()) where end - start > 0.001 {
                    let middle = (start + end) / 2
                    let profiles = Set(intervals.filter { $0.start <= middle && $0.end >= middle }.map(\.profile))
                    let id: String
                    if profiles.count == 1, let profile = profiles.first {
                        id = "\(turn.sourceTrack.rawValue):live:\(profile)"
                        mixed.insert(cluster)
                    } else { id = cluster }
                    result.append(DiarizationTurn(clusterID: id, start: start, end: end, sourceTrack: turn.sourceTrack))
                }
            }
        }
        return (result.sorted { $0.start < $1.start }, mixed)
    }

    public func isLiveProfileConfirmed(sessionID: String, profileID: String) throws -> Bool {
        try database.fetchOne("SELECT speaker_id FROM live_speakers WHERE session_id=? AND profile_id=? AND confirmed=1 LIMIT 1", bindings: [.text(sessionID), .text(profileID)]) != nil
    }

    public func liveProfileBridge(sessionID: String, turns: [DiarizationTurn], zeroHostSeconds: Double) throws -> LiveProfileBridge? {
        bridge(turns: turns, index: try liveIntervalIndex(sessionID: sessionID, zeroHostSeconds: zeroHostSeconds))
    }

    private func liveIntervalIndex(sessionID: String, zeroHostSeconds: Double) throws -> LiveIntervalIndex {
        let rows = try database.fetchAll("""
            SELECT t.*, l.profile_id,l.confirmed,l.confidence,p.display_name FROM live_turns t
            JOIN live_speakers l USING(session_id,speaker_id)
            JOIN speaker_profiles p ON l.profile_id=p.speaker_profile_id
            WHERE t.session_id=? AND p.archived=0 AND (l.confirmed=1 OR l.confidence>=0.9)
            """, bindings: [.text(sessionID)])
        return LiveIntervalIndex(rows.compactMap { row in
            guard let profileID = row["profile_id"]?.stringValue,
                  let source = row["source_track"]?.stringValue.flatMap(SpeakerSource.init(rawValue:)),
                  let start = row["start"]?.doubleValue, let end = row["end"]?.doubleValue,
                  start.isFinite, end.isFinite, end > start else { return nil }
            return LabelledLiveInterval(start: start - zeroHostSeconds, end: end - zeroHostSeconds, source: source,
                profile: LiveProfileBridge(profileID: profileID, name: row["display_name"]?.stringValue ?? "Speaker",
                    confirmed: row["confirmed"]?.boolValue ?? false, confidence: row["confidence"]?.doubleValue ?? 0))
        })
    }

    private func bridge(turns: [DiarizationTurn], index: LiveIntervalIndex) -> LiveProfileBridge? {
        let duration = turns.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard duration > 0 else { return nil }
        var overlaps: [String: Double] = [:]
        var details: [String: LiveProfileBridge] = [:]
        for turn in turns {
            for interval in index.intersecting(turn) {
                let profile = interval.profile
                overlaps[profile.profileID, default: 0] += max(0, min(turn.end, interval.end) - max(turn.start, interval.start))
                let old = details[profile.profileID]
                details[profile.profileID] = LiveProfileBridge(profileID: profile.profileID, name: profile.name,
                    confirmed: profile.confirmed || (old?.confirmed ?? false), confidence: max(profile.confidence, old?.confidence ?? 0))
            }
        }
        let sorted = overlaps.sorted { $0.value > $1.value }
        guard let best = sorted.first, best.value / duration >= 0.6,
              sorted.count < 2 || sorted[1].value / duration < 0.2 else { return nil }
        return details[best.key]
    }

    private func liveError(_ message: String) -> ProcessorError { ProcessorError(code: "invalid_request", message: message, retryable: false) }
}
