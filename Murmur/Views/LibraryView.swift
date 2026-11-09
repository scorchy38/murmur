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
                    Image("StatusBarIcon").renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompts").font(.headline)
                        Text("Your dictation history").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search prompts", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 16).padding(.bottom, 8)
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
                HStack {
                    Text("\(store.transcriptions.count) saved").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).accessibilityLabel("Settings")
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            if let entry {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.timestamp, format: .dateTime.month(.wide).day().hour().minute())
                                .font(.headline).lineLimit(1)
                            Text("Captured on \(entry.device)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(draft); copied = true }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                        ShareLink(item: draft) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.bordered).accessibilityLabel("Share prompt")
                    }
                    Divider()
                    TextEditor(text: $draft)
                        .font(.system(size: 19, weight: .regular))
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Editable copy of saved transcription")
                    HStack {
                        Text("Edits here are a working copy.").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button("Delete", role: .destructive) { store.delete(id: entry.id); selected = nil }
                            .buttonStyle(.borderless).fixedSize()
                    }
                }
                .padding(24)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "waveform").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(Color.accentColor)
                    Text("Your prompts,\nready to use.")
                        .font(.system(size: 36, weight: .medium, design: .rounded)).tracking(-1.8).multilineTextAlignment(.center)
                    Text(store.transcriptions.isEmpty ? "\(appState.shortcutInstruction) to speak. We’ll take care of the words." : "Choose a prompt to read, edit, or share.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 10) { ShortcutBadge(); Text("Hold to speak").font(.callout).foregroundStyle(.secondary) }
                        .padding(12).voiceGlass(cornerRadius: 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .frame(minWidth: 520)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 580, idealHeight: 720)
        .onAppear {
            if selected == nil { selected = store.transcriptions.first?.id; draft = entry?.text ?? "" }
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
