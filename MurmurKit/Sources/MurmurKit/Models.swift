import Foundation
import SwiftUI

public struct Transcription: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let timestamp: Date
    public let device: String

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), device: String) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.device = device
    }

    public var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

@MainActor
public class MurmurStore: ObservableObject {
    @Published public var transcriptions: [Transcription] = []
    @Published public var isRecording = false
    @Published public var isTranscribing = false

    private let storageKey = "murmur_transcriptions"
    private let defaults = UserDefaults(suiteName: "group.com.murmur.shared") ?? .standard

    public init() {
        load()
    }

    public func add(_ text: String, device: String) {
        let t = Transcription(text: text, device: device)
        transcriptions.insert(t, at: 0)
        if transcriptions.count > 50 { transcriptions = Array(transcriptions.prefix(50)) }
        save()
    }

    public func addTranscription(_ t: Transcription) {
        guard !transcriptions.contains(where: { $0.id == t.id }) else { return }
        transcriptions.insert(t, at: 0)
        transcriptions.sort { $0.timestamp > $1.timestamp }
        if transcriptions.count > 50 { transcriptions = Array(transcriptions.prefix(50)) }
        save()
    }

    public func clear() {
        transcriptions.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(transcriptions) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([Transcription].self, from: data) {
            transcriptions = items
        }
    }
}
