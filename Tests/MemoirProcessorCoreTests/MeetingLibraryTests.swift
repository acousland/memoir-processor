import Foundation
import Testing
@testable import MemoirProcessorCore

struct MeetingLibraryTests {
    private func fixture() throws -> (SessionStore, AppConfig, String) {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        let transcript = CanonicalTranscript(sessionID: id, sourceFiles: ["system": "system.wav", "mic": "mic.wav"],
            transcription: TranscriptionMetadata(engine: "whisperkit", model: "base", language: "en"), segments: [
                TranscriptSegment(start: 0.2, end: 2.7, speaker: nil, speakerSource: .mic, text: "Let's discuss the café launch."),
                TranscriptSegment(start: 3, end: 6.8, speaker: nil, speakerSource: .system, text: "The budget is approved for November.")
            ])
        try store.writeTranscriptArtifacts(sessionID: id, transcript: transcript)
        try store.setProcessingState(sessionID: id, state: .completed)
        return (store, config, id)
    }

    @Test func libraryReturnsRealTranscriptAndSearchesItsContents() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let document = try store.meetingDocument(sessionID: id)
        #expect(document.meeting.transcriptAvailable)
        #expect(document.meeting.language == "en")
        #expect(document.meeting.durationSeconds == 6.8)
        #expect(document.segments.map(\.speaker) == ["Me", "Others"])
        #expect(try store.searchMeetings(query: "cafe").map(\.id) == [id])
        #expect(try store.searchMeetings(query: "budg Nov").map(\.id) == [id])
        #expect(try store.searchMeetings(query: "\" OR *").isEmpty)
        #expect(try store.searchMeetings(query: "***").isEmpty)
    }

    @Test func speakerNamingPreservesIDsTimingAndExports() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let original = try store.meetingDocument(sessionID: id)
        let updated = try store.renameMeetingSpeaker(sessionID: id, speakerID: "track:system", name: "Alex", expectedRevision: original.meeting.revision)
        #expect(updated.segments.map(\.id) == original.segments.map(\.id))
        #expect(updated.segments.map(\.start) == original.segments.map(\.start))
        #expect(updated.segments[1].speaker == "Alex")
        #expect(updated.segments[1].speakerID == "track:system")
        #expect(updated.segments[0].speaker == "Me")
        #expect(try String(contentsOf: store.artifactPath(sessionID: id, name: "transcript.srt"), encoding: .utf8).contains("[Alex]"))
        #expect(try store.searchMeetings(query: "Alex").map(\.id) == [id])
        #expect(throws: ProcessorError.self) {
            try store.renameMeetingSpeaker(sessionID: id, speakerID: "track:system", name: "Stale", expectedRevision: original.meeting.revision)
        }
    }

    @Test func titleIsSeparateFromUploadMetadataAndIndexed() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let original = try store.meetingDocument(sessionID: id)
        let renamed = try store.renameMeeting(sessionID: id, title: "Planning review", expectedRevision: original.meeting.revision)
        #expect(renamed.meeting.title == "Planning review")
        #expect(try store.fetchStatus(sessionID: id).sessionName == "Probe")
        #expect(try store.searchMeetings(query: "Planning").map(\.id) == [id])
        #expect(throws: ProcessorError.self) { try store.renameMeeting(sessionID: id, title: "", expectedRevision: renamed.meeting.revision) }
    }

    @Test func existingTranscriptsAreBackfilledAndRemovedWithSession() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        try store.database.execute("DELETE FROM meeting_search")
        try store.database.execute("DELETE FROM meeting_documents")
        let reopened = try SessionStore(config: config)
        #expect(try reopened.searchMeetings(query: "budget").map(\.id) == [id])
        try reopened.removeSession(sessionID: id)
        #expect(try reopened.searchMeetings(query: "budget").isEmpty)
        #expect(try reopened.database.fetchAll("SELECT * FROM meeting_documents").isEmpty)
    }

    @Test func invalidPathsAndPagesAreRejected() throws {
        let (store, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        #expect(throws: ProcessorError.self) { try store.meetingDocument(sessionID: "../../config.json") }
        #expect(throws: ProcessorError.self) { try store.searchMeetings(offset: -1) }
        #expect(throws: ProcessorError.self) { try store.searchMeetings(limit: 101) }
    }

    @Test func silenceMarkersAreExcludedFromLibraryAndSearch() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let transcript = CanonicalTranscript(sessionID: id, sourceFiles: ["system": "system.wav"], transcription: TranscriptionMetadata(engine: "whisperkit", model: "base", language: "en"), segments: [
            TranscriptSegment(start: 0, end: 1, speaker: nil, speakerSource: .system, text: "[BLANK_AUDIO]"),
            TranscriptSegment(start: 2, end: 3, speaker: nil, speakerSource: .system, text: "The meeting is ready.")
        ])
        try store.writeTranscriptArtifacts(sessionID: id, transcript: transcript)
        #expect(try store.meetingDocument(sessionID: id).segments.map(\.text) == ["The meeting is ready."])
        #expect(try store.searchMeetings(query: "BLANK_AUDIO").isEmpty)
        #expect(TranscriptText.containsSpeech("We saw [BLANK_AUDIO] in the log."))
        #expect(!TranscriptText.containsSpeech(" [silence] "))
    }

    @Test func corruptOldTranscriptDoesNotStopTheService() throws {
        let (store, config, id) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        try Data("invalid transcript".utf8).write(to: store.artifactPath(sessionID: id, name: "transcript.json"))
        let reopened = try SessionStore(config: config)
        #expect(try reopened.searchMeetings().first?.transcriptAvailable == false)
    }
}
