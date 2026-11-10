import SwiftUI
import Charts
import MurmurKit

struct UsageSettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var period = 7
    private let calendar = Calendar.current
    private var filtered: [VoiceUsageSession] {
        guard period != 0 else { return store.sessions }
        let start = calendar.date(byAdding: .day, value: -(period - 1), to: calendar.startOfDay(for: Date()))!
        return store.sessions.filter { $0.startedAt >= start }
    }
    private var totals: VoiceUsageTotals { VoiceUsageTotals(sessions: filtered) }
    private var days: [(date: Date, words: Int)] {
        (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date()))!
            return (date, store.sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: date) }.reduce(0) { $0 + $1.words })
        }
    }
    private var streak: Int {
        let active = Set(store.sessions.filter { $0.words > 0 }.map { calendar.startOfDay(for: $0.startedAt) })
        var date = calendar.startOfDay(for: Date())
        if !active.contains(date) { date = calendar.date(byAdding: .day, value: -1, to: date)! }
        var result = 0
        while active.contains(date) { result += 1; date = calendar.date(byAdding: .day, value: -1, to: date)! }
        return result
    }
    var body: some View {
        let stats = totals
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your voice, adding up.").font(.title2.bold())
                Text(stats.words == 0 ? "Your next prompt starts the story. Speak a little, make room for more." : "Every prompt is a little less typing between you and your next idea.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
            Picker("Period", selection: $period) {
                Text("Today").tag(1)
                Text("7 days").tag(7)
                Text("All tracked").tag(0)
            }.pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                metric("Words dictated", value: stats.words.formatted(), icon: "text.word.spacing")
                metric("Dictation time", value: duration(stats.duration), icon: "mic")
                metric("Prompts completed", value: stats.prompts.formatted(), icon: "text.bubble")
                metric("Typing time saved", value: duration(stats.typingSecondsSaved), icon: "hourglass")
            }.padding(.vertical, 10)
            LabeledContent("Typing the same words at 40 wpm", value: duration(Double(stats.words) / 40 * 60))
            Text("Time includes pauses while recording. Words are counted from completed text. Time saved = words ÷ 40 words/minute, minus dictation time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("This week in words") {
            Chart(days, id: \.date) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words))
                    .cornerRadius(4).foregroundStyle(Color.accentColor.gradient)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { value in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 115).padding(.vertical, 6)
            LabeledContent("Current streak", value: "\(streak) \(streak == 1 ? "day" : "days")")
            LabeledContent("Longest prompt in this period", value: "\(stats.longestPrompt.formatted()) words")
        }
        Section("Gemini API · usage & cost") {
            LabeledContent("Cost at published rates", value: money(stats.estimatedCost))
                .font(.headline)
            LabeledContent(stats.receipts == stats.attempts ? "Input tokens" : "Input tokens · estimated", value: stats.estimatedInputTokens.formatted())
            LabeledContent(stats.receipts == stats.attempts ? "Output tokens" : "Output tokens · estimated", value: stats.estimatedOutputTokens.formatted())
            LabeledContent("Connections with reported usage", value: "\(stats.receipts) of \(stats.attempts)")
            if stats.receipts < stats.attempts {
                Text("Gemini Transcribe Live may finish a prompt without returning token counts. For those connections, Murmur estimates audio at 25 tokens/second and text at roughly 4 characters/token. Older tracked prompts use roughly 1⅓ tokens/word because their text length was not recorded. Language and formatting affect accuracy.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Provider-reported counts") {
                    LabeledContent("Input", value: tokenLabel(stats.inputTokens, available: filtered.contains { $0.attempts.contains { $0.usage?.inputTokens != nil } }))
                    LabeledContent("Output", value: tokenLabel(stats.outputTokens, available: filtered.contains { $0.attempts.contains { $0.usage?.outputTokens != nil } }))
                }
            }
            Text("Includes recording retries and recovery connections, including cancelled recordings. Audio estimates use bytes queued for the service, which may exceed delivered audio if a connection fails. Output estimates use final transcript length; any unfinalized output is unknown. Reported counts replace estimates when available. Setup checks and other apps or devices are not included.")
                .font(.caption).foregroundStyle(.secondary)
            if filtered.contains(where: { $0.outcome == "diagnostic" }) {
                Text("Includes service checks on this Mac. They do not count toward your words or dictation time.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Gemini 3.5 Transcribe Live: $3.50 / 1M audio input tokens and $21.00 / 1M text output tokens. Rates checked 8 November 2026 and saved with each recording. This is a USD estimate, not your Google bill; free tier, credits and taxes can change what you pay.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Gemini pricing", destination: URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!)
                Spacer()
                Link("Google AI Studio usage", destination: URL(string: "https://aistudio.google.com/usage")!)
            }.font(.callout)
        }
        Section {
            Label("On this Mac only", systemImage: "lock.shield")
            Text("Tracking since \(store.trackingStarted.formatted(date: .abbreviated, time: .omitted)). Earlier prompts cannot be backfilled reliably. Usage stores counts and timing, never your audio or prompt text, and stays separate from saved prompt history.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func tokenLabel(_ count: Int, available: Bool) -> String { available ? count.formatted() : "Not reported" }
    private func money(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 4; formatter.maximumFractionDigits = 4
        if amount > 0 && amount < Decimal(string: "0.0001")! { return "< US$0.0001" }
        return formatter.string(from: amount as NSDecimalNumber) ?? "—"
    }
    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) sec" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min \(Int(seconds) % 60) sec" }
        return "\(Int(seconds / 3600)) hr \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min"
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).contentTransition(.numericText())
        }.accessibilityElement(children: .combine)
    }
}
