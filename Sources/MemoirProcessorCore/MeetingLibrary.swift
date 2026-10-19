import Foundation

public enum TranscriptText {
    public static func containsSpeech(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !normalized.isEmpty && !["[BLANK_AUDIO]", "[NO_SPEECH]", "[SILENCE]", "(SILENCE)", "<|NOSPEECH|>"].contains(normalized)
    }
}

public struct MeetingSummary: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: String
    public let endedAt: String
    public let status: String
    public let updatedAt: String
    public let transcriptAvailable: Bool
    public let language: String?
    public let durationSeconds: Double?
    public let excerpt: String?
    public let error: String?
    public let revision: Int
}

public struct MeetingSegment: Codable, Identifiable, Sendable {
    public let id: String
    public let start: Double
    public let end: Double
    public let speakerID: String
    public let speaker: String
    public let text: String
}

public struct MeetingDocument: Codable, Sendable {
    public let meeting: MeetingSummary
    public let segments: [MeetingSegment]
}

public struct MeetingSearchRequest: Codable, Sendable {
    public let query: String
    public let offset: Int
    public let limit: Int
}

public struct MeetingTitleRequest: Codable, Sendable {
    public let title: String
    public let expectedRevision: Int
}

public struct MeetingSpeakerRequest: Codable, Sendable {
    public let speakerID: String
    public let name: String
    public let expectedRevision: Int
}

extension SessionStore {
    func migrateMeetingLibrary() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meeting_documents (
                session_id TEXT PRIMARY KEY, title_override TEXT, language TEXT,
                duration_seconds REAL, revision INTEGER NOT NULL DEFAULT 0,
                source_mtime REAL, modified_at TEXT NOT NULL
            );
            """)
        try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS meeting_search USING fts5(session_id UNINDEXED, title, transcript, tokenize='unicode61 remove_diacritics 2');")
        // Upgrade existing recordings as well as new ones. Comparing mtimes also
        // repairs an index left behind by a crash between file and database writes.
        for row in try database.fetchAll("SELECT s.session_id, d.source_mtime FROM sessions s LEFT JOIN meeting_documents d USING(session_id)") {
            guard let id = row["session_id"]?.stringValue else { continue }
            let url = artifactPath(sessionID: id, name: "transcript.json")
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970
            let indexed = try database.fetchOne("SELECT session_id FROM meeting_search WHERE session_id = ?", bindings: [.text(id)]) != nil
            if !indexed || modified != row["source_mtime"]?.doubleValue {
                do {
                    let transcript = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder.memoir.decode(CanonicalTranscript.self, from: Data(contentsOf: url)) : nil
                    try indexMeetingTranscript(sessionID: id, transcript: transcript)
                } catch {
                    try appendLog(sessionID: id, line: "Existing transcript is unreadable; omitted from the search index.")
                    try indexMeetingTranscript(sessionID: id, transcript: nil)
                }
            }
        }
    }

    func indexMeetingTranscript(sessionID: String, transcript: CanonicalTranscript?) throws {
        try database.transaction {
            guard let row = try database.fetchOne("SELECT session_name FROM sessions WHERE session_id = ?", bindings: [.text(sessionID)]) else { return }
            let url = artifactPath(sessionID: sessionID, name: "transcript.json")
            let modified = transcript == nil ? nil : try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970
            try database.execute("""
                INSERT INTO meeting_documents(session_id, language, duration_seconds, source_mtime, modified_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET language=excluded.language,
                    duration_seconds=excluded.duration_seconds, source_mtime=excluded.source_mtime,
                    modified_at=excluded.modified_at, revision=meeting_documents.revision+1
                """, bindings: [.text(sessionID), transcript.map { .text($0.transcription.language) } ?? .null,
                    transcript?.segments.map(\.end).max().map(SQLiteValue.double) ?? .null,
                    modified.map(SQLiteValue.double) ?? .null, .text(Time.nowString())])
            let title = try database.fetchOne("SELECT title_override FROM meeting_documents WHERE session_id=?", bindings: [.text(sessionID)])?["title_override"]?.stringValue ?? row["session_name"]?.stringValue ?? "Meeting"
            try database.execute("DELETE FROM meeting_search WHERE session_id=?", bindings: [.text(sessionID)])
            try database.execute("INSERT INTO meeting_search(session_id,title,transcript) VALUES (?,?,?)", bindings: [.text(sessionID), .text(title), .text(transcript?.segments.filter { TranscriptText.containsSpeech($0.text) }.map { "\(Self.meetingSegment($0).speaker): \($0.text)" }.joined(separator: "\n") ?? "")])
        }
    }

    public func searchMeetings(query: String = "", offset: Int = 0, limit: Int = 100) throws -> [MeetingSummary] {
        guard query.utf8.count <= 1024, offset >= 0, (1...100).contains(limit) else {
            throw ProcessorError(code: "invalid_request", message: "Invalid meeting search or page size.", retryable: false)
        }
        let terms = query.split { !$0.isLetter && !$0.isNumber }.prefix(20).map { "\"\($0)\"*" }
        if terms.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let filter = terms.isEmpty ? "" : "WHERE s.session_id IN (SELECT session_id FROM meeting_search WHERE meeting_search MATCH ?)"
        var bindings: [SQLiteValue] = terms.isEmpty ? [] : [.text(terms.joined(separator: " AND "))]
        bindings += [.integer(Int64(limit)), .integer(Int64(offset))]
        return try database.fetchAll("""
            SELECT s.*, d.title_override, d.language, d.duration_seconds, d.revision, d.source_mtime,
                   d.modified_at FROM sessions s LEFT JOIN meeting_documents d USING(session_id)
            \(filter) ORDER BY s.recording_started_at DESC, s.session_id DESC LIMIT ? OFFSET ?
            """, bindings: bindings).map { row in
                let id = row["session_id"]?.stringValue ?? ""
                var excerpt: String?
                if !terms.isEmpty {
                    excerpt = try database.fetchOne("SELECT snippet(meeting_search,2,'','',' … ',24) AS excerpt FROM meeting_search WHERE session_id=? AND meeting_search MATCH ?", bindings: [.text(id), .text(terms.joined(separator: " AND "))])?["excerpt"]?.stringValue
                }
                return summary(row, excerpt: excerpt)
            }
    }

    public func meetingDocument(sessionID: String) throws -> MeetingDocument {
        try database.synchronized {
            try validateSessionID(sessionID)
            guard let row = try database.fetchOne("SELECT s.*, d.title_override, d.language, d.duration_seconds, d.revision, d.source_mtime, d.modified_at FROM sessions s LEFT JOIN meeting_documents d USING(session_id) WHERE s.session_id=?", bindings: [.text(sessionID)]) else {
                throw ProcessorError(code: "session_not_found", message: "Meeting does not exist.", retryable: false)
            }
            let transcript = try loadMeetingTranscript(sessionID: sessionID)
            return MeetingDocument(meeting: summary(row), segments: transcript?.segments.filter { TranscriptText.containsSpeech($0.text) }.map(Self.meetingSegment) ?? [])
        }
    }

    public func renameMeeting(sessionID: String, title: String, expectedRevision: Int) throws -> MeetingDocument {
        try database.synchronized {
            let current = try meetingDocument(sessionID: sessionID)
            try checkRevision(current, expectedRevision)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 240, !title.contains("\n") else {
                throw ProcessorError(code: "invalid_request", message: "Use a meeting title between 1 and 240 characters.", retryable: false)
            }
            if try database.fetchOne("SELECT session_id FROM meeting_documents WHERE session_id=?", bindings: [.text(sessionID)]) == nil {
                try indexMeetingTranscript(sessionID: sessionID, transcript: nil)
            }
            try database.transaction {
                try database.execute("UPDATE meeting_documents SET title_override=?, revision=revision+1, modified_at=? WHERE session_id=?", bindings: [.text(title), .text(Time.nowString()), .text(sessionID)])
                try database.execute("UPDATE meeting_search SET title=? WHERE session_id=?", bindings: [.text(title), .text(sessionID)])
            }
            return try meetingDocument(sessionID: sessionID)
        }
    }

    public func renameMeetingSpeaker(sessionID: String, speakerID: String, name: String, expectedRevision: Int) throws -> MeetingDocument {
        try database.synchronized {
            let current = try meetingDocument(sessionID: sessionID)
            try checkRevision(current, expectedRevision)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120, !name.contains("\n"), current.segments.contains(where: { $0.speakerID == speakerID }) else {
                throw ProcessorError(code: "invalid_request", message: "Choose an existing speaker and a name between 1 and 120 characters.", retryable: false)
            }
            guard current.meeting.status == "completed", let transcript = try loadMeetingTranscript(sessionID: sessionID) else {
                throw ProcessorError(code: "session_busy", message: "Wait for transcription to finish before naming speakers.", retryable: true)
            }
            let vector = try sessionSpeakerEmbedding(sessionID: sessionID, clusterID: speakerID)
            let profile = try vector.map { _ in try resolveNamedProfile(name: name, profileID: nil) }
            let updated = CanonicalTranscript(sessionID: transcript.sessionID, sourceFiles: transcript.sourceFiles, transcription: transcript.transcription, segments: transcript.segments.map { segment in
                guard Self.meetingSegment(segment).speakerID == speakerID else { return segment }
                return TranscriptSegment(id: segment.id, start: segment.start, end: segment.end, speaker: name,
                    speakerID: profile?.id ?? segment.speakerID ?? speakerID, clusterID: segment.clusterID,
                    speakerSource: segment.speakerSource, speakerConfidence: profile == nil ? segment.speakerConfidence : 1, text: segment.text, words: segment.words)
            })
            try writeTranscriptArtifacts(sessionID: sessionID, transcript: updated)
            try database.execute("UPDATE session_speakers SET display_label=? WHERE session_id=? AND cluster_id=?", bindings: [.text(name), .text(sessionID), .text(speakerID)])
            if let profile, let vector {
                try database.execute("UPDATE session_speakers SET matched_profile_id=?,matched_profile_name=?,assignment_state='confirmed',match_confidence=1 WHERE session_id=? AND cluster_id=?", bindings: [.text(profile.id), .text(profile.name), .text(sessionID), .text(speakerID)])
                let space = try database.fetchOne("SELECT embedding_space FROM session_speakers WHERE session_id=? AND cluster_id=?", bindings: [.text(sessionID), .text(speakerID)])?["embedding_space"]?.stringValue ?? "legacy-pyannote-embedding"
                try saveVoiceSample(profileID: profile.id, sessionID: sessionID, clusterID: speakerID, vector: vector, quality: 1, space: space)
            }
            return try meetingDocument(sessionID: sessionID)
        }
    }

    private func checkRevision(_ document: MeetingDocument, _ expected: Int) throws {
        guard document.meeting.revision == expected else {
            throw ProcessorError(code: "meeting_conflict", message: "This meeting changed on the processor. Refresh it and try again.", retryable: false)
        }
    }

    private func loadMeetingTranscript(sessionID: String) throws -> CanonicalTranscript? {
        let url = artifactPath(sessionID: sessionID, name: "transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.memoir.decode(CanonicalTranscript.self, from: Data(contentsOf: url))
    }

    private func summary(_ row: [String: SQLiteValue], excerpt: String? = nil) -> MeetingSummary {
        MeetingSummary(id: row["session_id"]?.stringValue ?? "", title: row["title_override"]?.stringValue ?? row["session_name"]?.stringValue ?? "Meeting",
            startedAt: row["recording_started_at"]?.stringValue ?? "", endedAt: row["recording_ended_at"]?.stringValue ?? "",
            status: row["processing_state"]?.stringValue ?? row["ingestion_state"]?.stringValue ?? "created",
            updatedAt: max(row["updated_at"]?.stringValue ?? "", row["modified_at"]?.stringValue ?? ""),
            transcriptAvailable: row["source_mtime"]?.doubleValue != nil, language: row["language"]?.stringValue,
            durationSeconds: row["duration_seconds"]?.doubleValue, excerpt: excerpt,
            error: row["error_message"]?.stringValue, revision: row["revision"]?.intValue ?? 0)
    }

    private static func meetingSegment(_ segment: TranscriptSegment) -> MeetingSegment {
        let source = segment.speakerSource?.rawValue ?? "unknown"
        let identity = segment.clusterID ?? segment.speakerID ?? (source == "unknown" ? "label:\(segment.speaker ?? "Speaker")" : "track:\(source)")
        return MeetingSegment(id: segment.id.uuidString, start: segment.start, end: segment.end, speakerID: identity,
            speaker: segment.speaker ?? (source == "mic" ? "Me" : source == "system" ? "Others" : "Speaker"), text: segment.text)
    }
}
