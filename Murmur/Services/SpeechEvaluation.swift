#if DEBUG || MURMUR_EVALUATION
import Foundation
import MurmurKit

/// Developer-run, synthetic-audio integration check. Never reads the microphone.
@MainActor
func evaluateSyntheticSpeech(directory: URL) async -> Int32 {
    FileHandle.standardOutput.write(Data("EVALUATION_STARTING\n".utf8))
    let credentialInput = FileHandle.standardInput.readDataToEndOfFile()
    let supplied = String(data: credentialInput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let saved = supplied.isEmpty ? (CommandLine.arguments.contains("--authorize-keychain") ? await VoiceCredential.readAsync() : VoiceCredential.read(interactive: false)) : supplied
    guard let credential = saved else {
        print("EVALUATION_UNAVAILABLE: saved credential requires authorization")
        return 2
    }
    FileHandle.standardOutput.write(Data("EVALUATION_CREDENTIAL_AVAILABLE\n".utf8))
    struct Case: Decodable { let name: String; let audio: String; let mode: VoiceWritingStyle; let expected: String; let recoverEarlyFinals: Bool? }
    struct Receipt: Encodable { let name: String; let passed: Bool; let seconds: Double; let reason: String; let output: String; let recoveryEnabled: Bool; let audioSeconds: Double; let boundaries: [VoiceProviderBoundary]; let finalizationSeconds: Double? }
    let usage = UsageStore() // A test process must not overwrite the running app's ledger.
    var receipts: [Receipt] = []
    do {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
        for fixture in cases {
            let started = Date()
            let sessionID = UUID()
            var attempt = VoiceAttemptSummary()
            let data = try Data(contentsOf: directory.appendingPathComponent((fixture.audio as NSString).lastPathComponent))
            guard !data.isEmpty, data.count <= VoiceAudio.bytesPerSecond * 480, data.count.isMultiple(of: 2) else { throw VoiceFailure.unsupported }
            let stream = NativeVoiceStream(credential: credential, language: "en", vocabulary: ["CacheManager", "Murmur", "Codex"], keepaliveEnabled: false, mode: fixture.mode.transcriptionMode, recoverEarlyFinals: fixture.recoverEarlyFinals ?? true)
            var continuation: AsyncStream<VoiceEvent>.Continuation!
            let events = AsyncStream<VoiceEvent> { continuation = $0 }
            stream.onEvent = { continuation.yield($0) }
            let timeout = Task { try? await Task.sleep(for: .seconds(Double(data.count) / Double(VoiceAudio.bytesPerSecond) + 30)); if !Task.isCancelled { continuation.yield(.failure(.connection)) } }
            var sender: Task<Void, Never>?
            var transcript = VoiceTranscript()
            var boundaries: [VoiceProviderBoundary] = []
            var inputClosedAt: Date?
            var lastProgress = Date.distantPast
            var failure: VoiceFailure?
            usage.record(VoiceUsageSession(id: sessionID, startedAt: started, duration: 0, words: 0, outcome: "active", attempts: [attempt]))
            stream.start()
            for await event in events {
                if event == .ready {
                    sender = Task {
                        for offset in stride(from: 0, to: data.count, by: 3200) {
                            guard !Task.isCancelled else { return }
                            let frame = data.subdata(in: offset..<min(data.count, offset + 3200))
                            attempt.queuedAudioBytes += frame.count
                            stream.send(frame)
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        stream.finish()
                    }
                }
                if case .usage(let receipt) = event { attempt.usage = receipt; attempt.reportedTokens = receipt.totalTokens }
                if case .providerBoundary(let boundary) = event {
                    boundaries.append(boundary)
                    if let data = try? JSONEncoder().encode(boundary) { FileHandle.standardOutput.write(Data(("PROVIDER_CONTROL " + String(decoding: data, as: UTF8.self) + "\n").utf8)) }
                }
                if case .progress(let progress) = event {
                    attempt.streamProgress = progress
                    if Date().timeIntervalSince(lastProgress) >= 15 {
                        lastProgress = Date()
                        let line = "LIVE_PROGRESS case=\(fixture.name) sent_seconds=\(Double(progress.sentAudioBytes)/32000) messages=\(progress.receivedMessages) finals=\(progress.finalMessages) resumes=\(max(0, (progress.activityStarts ?? 1)-1))\n"
                        FileHandle.standardOutput.write(Data(line.utf8))
                    }
                }
                if event == .inputClosed { inputClosedAt = Date() }
                if case .transportFailure(let failure) = event { attempt.transportFailure = failure }
                transcript.accept(event)
                if case .failure(let reason) = event { failure = reason; break }
                if event == .finalized { break }
            }
            sender?.cancel(); timeout.cancel(); stream.cancel(); continuation.finish()
            attempt.estimatedOutputTokens = VoiceUsageSession.estimateTextTokens(transcript.preview)
            attempt.outcome = failure == nil ? "completed" : "error"
            let receipt = VoiceUsageSession(id: sessionID, startedAt: started, duration: 0, words: 0, outcome: "diagnostic", attempts: [attempt])
            usage.record(receipt)
            let pending = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Evaluations", isDirectory: true)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let receiptFile = pending.appendingPathComponent(sessionID.uuidString + ".json")
            try JSONEncoder().encode(receipt).write(to: receiptFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptFile.path)
            var library = VoicePersonalization.starter
            if let index = library.words.firstIndex(where: { $0.written == "CacheManager" }) { library.words[index].spoken = "cash manager; cache manager" }
            let result = VoicePersonalizer.process(transcript.preview, library: library, app: nil, style: fixture.mode)
            let passed = failure == nil && result.text.localizedCaseInsensitiveContains(fixture.expected)
            receipts.append(Receipt(name: fixture.name, passed: passed, seconds: Date().timeIntervalSince(started), reason: failure?.rawValue ?? (passed ? "matched" : "unexpected recognition"), output: result.text, recoveryEnabled: fixture.recoverEarlyFinals ?? true, audioSeconds: Double(data.count)/32000, boundaries: boundaries, finalizationSeconds: inputClosedAt.map { Date().timeIntervalSince($0) }))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipts).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        print("SPEECH_EVALUATION: \(receipts.filter(\.passed).count)/\(receipts.count) passed")
        return receipts.allSatisfy(\.passed) ? 0 : 1
    } catch {
        print("SPEECH_EVALUATION_FAILED: unable to complete synthetic fixture run")
        return 1
    }
}
#endif
