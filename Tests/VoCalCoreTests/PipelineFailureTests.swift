import Foundation
import Testing
@testable import VoCalCore

/// The taxonomy exists so no two failure classes collapse into one message (the old single
/// "Couldn't analyze the meal" hid the is_estimate decode bug and the noAudio outbox race).
/// These tests pin: distinct copy per class, stable diagnostic codes, honest retryability.
struct PipelineFailureTests {
    private let stages: [PipelineStage] = [.transcribe, .parse, .log]

    @Test("Every failure kind yields a distinct message within a stage")
    func distinctMessagesPerStage() {
        for stage in stages {
            let kinds: [PipelineFailureKind] = [
                .noAudio, .offline, .serverStatus(401), .serverStatus(404), .serverStatus(422),
                .serverStatus(502), .contractMismatch, .unknown,
            ]
            let messages = kinds.map { pipelineFailureCopy(stage: stage, kind: $0).message }
            #expect(Set(messages).count == messages.count, "collapsed messages in \(stage)")
        }
    }

    @Test("Diagnostic codes are stable and stage-scoped")
    func codesAreStable() {
        #expect(pipelineFailureCopy(stage: .transcribe, kind: .noAudio).code == "no_audio")
        #expect(pipelineFailureCopy(stage: .transcribe, kind: .serverStatus(502)).code == "transcribe_502")
        #expect(pipelineFailureCopy(stage: .parse, kind: .contractMismatch).code == "parse_decode")
        #expect(pipelineFailureCopy(stage: .parse, kind: .offline).code == "parse_offline")
        #expect(pipelineFailureCopy(stage: .log, kind: .serverStatus(422)).code == "log_422")
    }

    @Test("Retryability is honest: decode + auth are terminal, transient classes retry")
    func retryability() {
        // Retrying an identical request cannot fix contract drift or an expired session.
        #expect(pipelineFailureCopy(stage: .parse, kind: .contractMismatch).retryable == false)
        #expect(pipelineFailureCopy(stage: .transcribe, kind: .serverStatus(401)).retryable == false)
        // These plausibly succeed on retry.
        #expect(pipelineFailureCopy(stage: .transcribe, kind: .noAudio).retryable)
        #expect(pipelineFailureCopy(stage: .parse, kind: .offline).retryable)
        #expect(pipelineFailureCopy(stage: .transcribe, kind: .serverStatus(502)).retryable)
    }

    @Test("noAudio never claims a server problem — no request was made")
    func noAudioIsLocal() {
        let copy = pipelineFailureCopy(stage: .transcribe, kind: .noAudio)
        #expect(!copy.message.lowercased().contains("server"))
        #expect(copy.message.contains("Try again"))
    }

    @Test("The generic phrase only survives in the unknown fallback")
    func genericOnlyForUnknown() {
        let kinds: [PipelineFailureKind] = [
            .noAudio, .offline, .serverStatus(401), .serverStatus(404), .serverStatus(422),
            .serverStatus(502), .contractMismatch,
        ]
        for stage in stages {
            for kind in kinds {
                let msg = pipelineFailureCopy(stage: stage, kind: kind).message
                #expect(!msg.contains("Couldn't analyze the meal"), "\(stage)/\(kind) fell back to the generic copy")
            }
        }
    }
}
