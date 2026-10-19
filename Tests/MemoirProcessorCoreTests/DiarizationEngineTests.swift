import Foundation
import Testing
@testable import MemoirProcessorCore

struct DiarizationEngineTests {
    @Test func oldConfigurationMigratesAndSelectionSurvivesRoundTrip() throws {
        let original = AppConfig.default().updating(diarizationEnabled: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.memoir.encode(original)) as? [String: Any])
        object.removeValue(forKey: "diarizationEngine")
        let old = try JSONDecoder.memoir.decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.diarizationEngine == .fluidAudio)
        #expect(old.diarizationEnabled)
        let changed = old.updating(diarizationEngine: .pyannote)
        let saved = try JSONDecoder.memoir.decode(AppConfig.self, from: JSONEncoder.memoir.encode(changed))
        #expect(saved.diarizationEngine == .pyannote)
        #expect(saved.authToken == original.authToken)
        #expect(saved.storageRoot == original.storageRoot)
    }

    @Test func sameLengthVoiceSamplesNeverMatchAcrossEngines() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let speakers = ["fluid", "pyannote", "legacy"].map { cluster in
            SessionSpeaker(sessionID: id, clusterID: cluster, displayLabel: cluster, sourceTrack: .system, speakingDurationSeconds: 2, matchedProfileID: nil, matchedProfileName: nil, matchConfidence: nil, assignmentState: .anonymous, representativeText: nil)
        }
        try store.upsertSessionSpeakers(sessionID: id, speakers: speakers)
        let profile = try store.createSpeakerProfile(name: "Alex")
        let spaces = [DiarizationEngine.fluidAudio.embeddingSpace, DiarizationEngine.pyannote.embeddingSpace, "legacy-pyannote-embedding"]
        for (index, cluster) in ["fluid", "pyannote", "legacy"].enumerated() {
            try store.saveSessionSpeakerEmbedding(sessionID: id, clusterID: cluster, vector: [Double(index), 1], embeddingSpace: spaces[index])
            try store.saveEmbedding(profileID: profile.id, sessionID: id, clusterID: cluster, vector: [Double(index), 1], qualityScore: 1)
        }
        for (index, space) in spaces.enumerated() {
            let filtered = try store.speakerProfileEmbeddings(embeddingSpace: space)
            #expect(filtered[profile.id] == [[Double(index), 1]])
        }
        // Opening the database again preserves all old and new samples.
        let reopened = try SessionStore(config: config)
        #expect(try reopened.listSpeakerProfiles().first?.sampleCount == 3)
        #expect(try reopened.speakerProfileEmbeddings()[profile.id] == [[2, 1]])
    }

    @Test func migrationRetainsLegacyVoiceSamples() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        let profile = try store.createSpeakerProfile(name: "Legacy person")
        try store.saveEmbedding(profileID: profile.id, sessionID: id, clusterID: "old", vector: [1, 0], qualityScore: 1)
        try store.database.execute("ALTER TABLE speaker_profile_embeddings DROP COLUMN embedding_space")
        try store.database.execute("ALTER TABLE session_speakers DROP COLUMN embedding_space")
        let migrated = try SessionStore(config: config)
        #expect(try migrated.speakerProfileEmbeddings()[profile.id] == [[1, 0]])
        #expect(try migrated.speakerProfileEmbeddings(embeddingSpace: DiarizationEngine.fluidAudio.embeddingSpace).isEmpty)
        #expect(try migrated.speakerProfileEmbeddings(embeddingSpace: DiarizationEngine.pyannote.embeddingSpace).isEmpty)
    }

    @Test func reprocessingWithAnotherEngineReplacesOldClusters() throws {
        let (store, config, id) = try ReliabilityRegressionTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.storageRoot) }
        func speaker(_ cluster: String) -> SessionSpeaker {
            SessionSpeaker(sessionID: id, clusterID: cluster, displayLabel: cluster, sourceTrack: .system, speakingDurationSeconds: 2, matchedProfileID: nil, matchedProfileName: nil, matchConfidence: nil, assignmentState: .anonymous, representativeText: nil)
        }
        try store.upsertSessionSpeakers(sessionID: id, speakers: [speaker("system:old")])
        try store.saveSessionSpeakerEmbedding(sessionID: id, clusterID: "system:old", vector: [1, 0])
        try store.replaceSessionSpeakers(sessionID: id, speakers: [speaker("system:new")])
        #expect(try store.listSessionSpeakers(sessionID: id).map(\.clusterID) == ["system:new"])
        #expect(try store.sessionSpeakerEmbedding(sessionID: id, clusterID: "system:old") == nil)
    }

    @Test func fluidAudioWorkerResponseSharesTranscriptContract() throws {
        let data = Data(#"{"runtime":"FluidAudio offline VBx","backend":"coreml-cpu+ane","turns":[{"cluster_id":"system:0","start":0,"end":2,"source_track":"system"}],"embeddings":[{"clusterID":"system:0","durationSeconds":2,"embedding":[0.5,0.5],"sourceTrack":"system"}]}"#.utf8)
        let response = try JSONDecoder.memoir.decode(WorkerDiarizationResult.self, from: data)
        #expect(response.turns[0].clusterID == response.embeddings[0].clusterID)
        #expect(response.embeddings[0].embedding == [0.5, 0.5])
        #expect(response.backend == "coreml-cpu+ane")
    }
}
