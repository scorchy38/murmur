import SwiftUI
import MurmurKit

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: MurmurStore
    @State private var selected: UUID?
    @State private var search = ""
    @State private var draft = ""
    @State private var copied = false
    @State private var confirmClear = false
    private var items: [Transcription] {
        store.transcriptions.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }
    private var entry: Transcription? { store.transcriptions.first { $0.id == selected } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(Color.accentColor).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your thoughts").font(.headline)
                        Text("A little less between you and your words.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                List(selection: $selected) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text).font(.callout).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(item.timestamp, style: .date)
                                Text("·")
                                Text(item.device)
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7).tag(item.id)
                        .contextMenu {
                            Button("Copy") { copy(item.text) }
                            Button("Delete", role: .destructive) { store.delete(id: item.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $search, prompt: "Find a thought")
                HStack {
                    Text("\(store.transcriptions.count) saved").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).accessibilityLabel("Settings")
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } detail: {
            if let entry {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.timestamp, format: .dateTime.month(.wide).day().hour().minute()).font(.headline)
                            Text("Captured on \(entry.device)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(draft); copied = true }
                            .buttonStyle(.borderedProminent)
                        ShareLink(item: draft) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share text")
                    }
                    Divider()
                    TextEditor(text: $draft)
                        .font(.system(size: 23, weight: .regular, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Editable copy of saved transcription")
                    HStack {
                        Text("Edits here are a working copy.").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Delete", role: .destructive) { store.delete(id: entry.id); selected = nil }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(32)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "waveform").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Color.accentColor)
                    Text("Make room\nfor a thought.")
                        .font(.system(size: 48, weight: .medium, design: .rounded)).tracking(-1.8).multilineTextAlignment(.center)
                    Text(store.transcriptions.isEmpty ? "Hold Shift to speak. We’ll take care of the words." : "Choose a thought to revisit, edit, or share.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 10) { ShortcutBadge(); Text("Hold to speak").font(.callout).foregroundStyle(.secondary) }
                        .padding(12).voiceGlass(cornerRadius: 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
        }
        .onChange(of: selected) { _, _ in draft = entry?.text ?? ""; copied = false }
        .toolbar {
            ToolbarItem {
                Button("Clear history", systemImage: "trash") { confirmClear = true }.disabled(store.transcriptions.isEmpty)
            }
        }
        .confirmationDialog("Delete all saved transcriptions?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { store.clear(); selected = nil }
        } message: { Text("This removes saved text from this Mac.") }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
