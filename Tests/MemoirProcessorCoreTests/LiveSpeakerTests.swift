import Foundation
import Testing
@testable import MemoirProcessorCore

struct LiveSpeakerTests {
    func vector(_ first: Double = 1, _ second: Double = 0) -> [Double] { [first, second] + Array(repeating: 0, count: 254) }
    func chunk(_ sequence: Int = 0, start: Double = 1000) -> LiveAudioChunk {
        LiveAudioChunk(sequence: sequence, sourceTrack: .system, firstSampleHostTimeNs: String(UInt64(start * 1e9)), sampleRateHz: 16_000, pcmBase64: Data(repeating: 0, count: 96_000).base64EncodedString())
    }
    func output(id: String = "1", vector: [Double]? = nil) -> LiveWorkerOutput {
        LiveWorkerOutput(turns: [LiveWorkerTurn(speakerID: id, start: 0, end: 3, quality: 0.9)], speakers: [LiveVoiceSeed(id: id, embedding: vector ?? self.vector(), duration: 3)])
    }

    @Test func namingLearnsOnlyConfirmedVoicesAndRecognisesThemNextMeeting() throws {
        let (store, config, _) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let first = UUID().uuidString
        _ = try store.beginLiveSession(first)
        _ = try store.applyLiveChunk(first, chunk: chunk(), output: output(), threshold: 0.86)
        #expect(try store.listSpeakerProfiles().isEmpty)
        let named = try store.nameLiveSpeaker(first, request: LiveNameRequest(speakerID: "1", name: "Alex", profileID: nil))
        let profile = try #require(named.speakers.first?.profileID)
        #expect(named.speakers.first?.confirmed == true)
        #expect(try store.speakerProfileEmbeddings(embeddingSpace: LiveSpeakerConstants.embeddingSpace)[profile]?.count == 1)
        let next = UUID().uuidString
        _ = try store.beginLiveSession(next)
        let recognised = try store.applyLiveChunk(next, chunk: chunk(), output: output(), threshold: 0.86)
        #expect(recognised.speakers.first?.name == "Alex")
        #expect(recognised.speakers.first?.profileID == profile)
        #expect(recognised.speakers.first?.confirmed == false)
        #expect(try store.speakerProfileEmbeddings(embeddingSpace: LiveSpeakerConstants.embeddingSpace)[profile]?.count == 1)
    }

    @Test func retriesAreIdempotentAndSilenceClearsSpeaking() throws {
        let (store, config, _) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let id = UUID().uuidString
        _ = try store.beginLiveSession(id)
        let first = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        #expect(first.speakers.first?.speaking == true)
        _ = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        #expect(try store.database.fetchOne("SELECT COUNT(*) AS n FROM live_turns")?["n"]?.intValue == 1)
        let quiet = try store.applyLiveChunk(id, chunk: chunk(1, start: 1003), output: LiveWorkerOutput(turns: [], speakers: []), threshold: 0.86)
        #expect(quiet.speakers.first?.speaking == false)
        #expect(throws: ProcessorError.self) {
            _ = try store.hasLiveChunk(id, chunk: self.chunk(0, start: 2000))
        }
    }

    @Test func confirmedNamesBridgeToFinalClustersUsingCaptureClock() throws {
        let (store, config, _) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let id = UUID().uuidString
        _ = try store.beginLiveSession(id)
        _ = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        let named = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "1", name: "Alex", profileID: nil))
        let turns = [DiarizationTurn(clusterID: "system:SPEAKER_04", start: 0, end: 3, sourceTrack: .system)]
        let candidate = try store.liveProfileBridge(sessionID: id, turns: turns, zeroHostSeconds: 1000)
        let bridge = try #require(candidate)
        #expect(bridge.profileID == named.speakers.first?.profileID)
        #expect(bridge.confirmed)
        #expect(try store.liveProfileBridge(sessionID: id, turns: turns, zeroHostSeconds: 2000) == nil)
        #expect(try store.liveProfileBridge(sessionID: id, turns: [DiarizationTurn(clusterID: "mic:4", start: 0, end: 3, sourceTrack: .mic)], zeroHostSeconds: 1000) == nil)
    }

    @Test func ambiguousProfilesAreNotAutomaticallyNamed() {
        let v = vector()
        #expect(LiveVoiceMatching.confidentMatch(v, bank: ["a": [v], "b": [v]], threshold: 0.86) == nil)
        #expect(LiveVoiceMatching.confidentMatch(v, bank: ["a": [vector(0, 1)]], threshold: 0.86) == nil)
        #expect(LiveVoiceMatching.confidentMatch(v, bank: ["a": [v]], threshold: 0.86)?.id == "a")
    }

    @Test func severalVoiceSamplesForOnePersonShowOneCard() throws {
        let (store, config, _) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let id = UUID().uuidString
        _ = try store.beginLiveSession(id)
        _ = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        let named = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "1", name: "Alex", profileID: nil))
        let profile = try #require(named.speakers.first?.profileID)
        _ = try store.applyLiveChunk(id, chunk: chunk(1, start: 1003), output: output(id: "2", vector: vector(0, 1)), threshold: 0.86)
        let joined = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "2", name: "Alex", profileID: profile))
        #expect(joined.speakers.count == 1)
        #expect(joined.speakers.first?.id == "2")
        #expect(joined.speakers.first?.speaking == true)
        #expect(try store.liveSeeds(id).count == 2)
    }

    @Test func mergedBatchClustersRespectLiveNamesWithoutTrainingMixedVoices() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        _ = try store.beginLiveSession(id)
        _ = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        _ = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "1", name: "Alex", profileID: nil))
        _ = try store.applyLiveChunk(id, chunk: chunk(1, start: 1003), output: output(id: "2", vector: vector(0, 1)), threshold: 0.86)
        _ = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "2", name: "Jamie", profileID: nil))
        let reconciled = try store.reconcileLiveTurns(sessionID: id,
            turns: [DiarizationTurn(clusterID: "system:merged", start: 0, end: 6, sourceTrack: .system)], zeroHostSeconds: 1000)
        #expect(reconciled.mixedClusters == ["system:merged"])
        #expect(Set(reconciled.turns.map(\.clusterID)).count == 2)
        #expect(reconciled.turns.map(\.start) == [0, 3])
    }

    @Test func wordTimesKeepSpeakerChangesInsideOneASRSegment() {
        let first = "system:1", second = "system:2"
        func speaker(_ cluster: String, _ name: String) -> SessionSpeaker {
            SessionSpeaker(sessionID: "session", clusterID: cluster, displayLabel: name, sourceTrack: .system,
                speakingDurationSeconds: 3, matchedProfileID: nil, matchedProfileName: nil, matchConfidence: 1,
                assignmentState: .confirmed, representativeText: nil)
        }
        let segment = TranscriptSegment(start: 0, end: 6, speaker: nil, speakerSource: .system, text: "Hello Jamie.",
            words: [TranscriptWord(start: 0, end: 2, text: " Hello"), TranscriptWord(start: 3, end: 5, text: " Jamie.")])
        let split = TranscriptSpeakerAlignment.apply(to: [segment],
            turns: [DiarizationTurn(clusterID: first, start: 0, end: 3, sourceTrack: .system),
                    DiarizationTurn(clusterID: second, start: 3, end: 6, sourceTrack: .system)],
            speakersByCluster: [first: speaker(first, "Alex"), second: speaker(second, "Jamie")])
        #expect(split.map(\.speaker) == ["Alex", "Jamie"])
        #expect(split.map(\.text) == ["Hello", "Jamie."])
        #expect(split[1].start == 3)
    }

    @Test func namingAFinishedTranscriptEnrolsItsVoice() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let cluster = "system:1"
        try store.upsertSessionSpeakers(sessionID: id, speakers: [SessionSpeaker(sessionID: id, clusterID: cluster,
            displayLabel: "Speaker 1", sourceTrack: .system, speakingDurationSeconds: 4, matchedProfileID: nil,
            matchedProfileName: nil, matchConfidence: nil, assignmentState: .anonymous, representativeText: nil)])
        try store.saveSessionSpeakerEmbedding(sessionID: id, clusterID: cluster, vector: vector(), embeddingSpace: DiarizationEngine.fluidAudio.embeddingSpace)
        try store.writeTranscriptArtifacts(sessionID: id, transcript: CanonicalTranscript(sessionID: id,
            sourceFiles: ["system": "system.wav"], transcription: TranscriptionMetadata(engine: "whisperkit", model: "base", language: "en"),
            segments: [TranscriptSegment(start: 0, end: 4, speaker: "Speaker 1", speakerID: cluster, clusterID: cluster, speakerSource: .system, text: "Hello there.")]))
        try store.setProcessingState(sessionID: id, state: .completed)
        let current = try store.meetingDocument(sessionID: id)
        _ = try store.renameMeetingSpeaker(sessionID: id, speakerID: cluster, name: "Alex", expectedRevision: current.meeting.revision)
        let profiles = try store.listSpeakerProfiles()
        let profile = try #require(profiles.first)
        #expect(profile.name == "Alex")
        #expect(try store.speakerProfileEmbeddings(embeddingSpace: DiarizationEngine.fluidAudio.embeddingSpace)[profile.id] == [vector()])
    }

    @Test func malformedLiveAudioCannotReachInference() throws {
        let bad = LiveAudioChunk(sequence: -1, sourceTrack: .manual, firstSampleHostTimeNs: "bad", sampleRateHz: 0, pcmBase64: "bad")
        #expect(throws: ProcessorError.self) { _ = try bad.validatedPCM() }
        #expect(try chunk().validatedPCM().count == 96_000)
    }

    @Test func correctedNamesReplaceTheirTrainingSampleAndClosedSessionsStayClosed() throws {
        let (store, config, _) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let id = UUID().uuidString
        _ = try store.beginLiveSession(id)
        _ = try store.applyLiveChunk(id, chunk: chunk(), output: output(), threshold: 0.86)
        let original = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "1", name: "Alex", profileID: nil))
        let corrected = try store.nameLiveSpeaker(id, request: LiveNameRequest(speakerID: "1", name: "Sam", profileID: nil))
        let bank = try store.speakerProfileEmbeddings(embeddingSpace: LiveSpeakerConstants.embeddingSpace)
        #expect(bank[try #require(original.speakers.first?.profileID)] == nil)
        #expect(bank[try #require(corrected.speakers.first?.profileID)]?.count == 1)
        _ = try store.closeLiveSession(id)
        #expect(try store.beginLiveSession(id).closed)
        _ = try store.applyLiveChunk(id, chunk: chunk(1, start: 1003), output: output(id: "2", vector: vector(0, 1)), threshold: 0.86)
        #expect(try store.liveSnapshot(id).speakers.count == 1)
    }
}
