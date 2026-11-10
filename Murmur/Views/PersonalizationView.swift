import SwiftUI
import UniformTypeIdentifiers
import MurmurKit

struct PersonalizationView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: PersonalizationStore
    @State private var tab = "Words"
    @State private var editingWordID: UUID?
    @State private var editingSnippetID: UUID?
    @State private var written = ""
    @State private var spoken = ""
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var scoped = false
    @State private var scopeAppID: String?
    @State private var scopeAppName = ""
    @State private var testText = ""
    @State private var message: String?
    @State private var imported: VoicePersonalization?
    @State private var search = ""
    private var app: String? { scoped ? scopeAppID ?? state.writingAppID : nil }
    var body: some View {
        Group {
            Section {
                Text("Make it sound like you.").font(.title2.bold())
                Text("Save a spelling once. Use your own phrases. Your personal library is saved on this Mac.").foregroundStyle(.secondary)
                Picker("Library", selection: $tab) { Text("Words").tag("Words"); Text("Snippets").tag("Snippets"); Text("Writing").tag("Writing") }.pickerStyle(.segmented)
                if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            if tab == "Words" { words }
            else if tab == "Snippets" { snippets }
            else { writing }
            Section("Preview commands and formatting") {
                TextField("Try a phrase", text: $testText, prompt: Text("A phrase Murmur usually gets wrong…"), axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).labelsHidden()
                if !testText.isEmpty {
                    let result = VoicePersonalizer.process(testText, library: store.library, app: state.writingAppID, style: store.library.style(for: state.writingAppID))
                    Text(result.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text(result.expandedSnippet ? "Snippet expanded" : result.formattedIdentifier ? "Identifier formatted" : result.corrections > 0 ? "Personal spelling applied" : "No spelling changes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This preview stays on your Mac and uses no API tokens. Vocabulary hints take effect during audio recognition and cannot be simulated from text.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack { Button("Import…") { chooseImport() }; Button("Export…") { export() } }
                Text("Import adds missing entries and keeps your existing entries and default style. Exports contain your words, snippets and app preferences; share only what you intend.").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Import this library?", isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } }), titleVisibility: .visible) {
            if let imported {
                Button("Add \(imported.words.count) words, \(imported.snippets.count) phrases and \(imported.appStyles.count) app styles") {
                    perform { let count = try store.merge(imported); message = "Added \(count) entries. Existing entries were kept." }
                    self.imported = nil
                }
            }
            Button("Cancel", role: .cancel) { imported = nil }
        }
    }
    private var words: some View {
        Group {
            Section("Remember a word") {
                TextField("Write it as", text: $written, prompt: Text("CacheManager")).textFieldStyle(.roundedBorder)
                TextField("Heard as", text: $spoken, prompt: Text("cash manager; cache manager")).textFieldStyle(.roundedBorder)
                Text("Optional correction history, separated by semicolons. These are never replacement rules.").font(.caption).foregroundStyle(.secondary)
                scope
                Button(editingWordID == nil ? "Remember spelling" : "Save spelling") {
                    perform { try store.addWord(written: written, spoken: spoken, app: app, replacing: editingWordID); message = "Remembered as a recognition hint for future dictations."; written = ""; spoken = ""; editingWordID = nil }
                }.disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Saved spellings are sent to Gemini as vocabulary hints alongside your speech. Gemini chooses the spelling using the audio and context. Murmur never replaces ordinary words with saved names after recognition.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Learn from your corrections") {
                Toggle("Learn spellings from edits I make in Murmur", isOn: $state.learnFromReview)
                Text("After an edit settles, names and technical spellings corrected in Murmur’s result editor are saved as recognition hints. Grammar changes are not learned. Manage or remove learned words below. This does not train Gemini or read edits in other apps.").font(.caption).foregroundStyle(.secondary)
                Toggle("Suggest spellings after I edit a dictation", isOn: $state.suggestCorrections)
                    .onChange(of: state.suggestCorrections) { _, _ in NotificationCenter.default.post(name: .voiceSettingsChanged, object: nil) }
                Text("For 18 seconds after insertion, Murmur can check edits within its own text while the original field is focused. It suggests small spelling changes in the menu; nothing is learned until you choose Remember. Clipboard-only dictation is not monitored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your words") {
                TextField("Find a word", text: $search).textFieldStyle(.roundedBorder).labelsHidden()
                ForEach(store.library.words.filter { search.isEmpty || ($0.written + " " + $0.spoken).localizedCaseInsensitiveContains(search) }) { word in
                    HStack(alignment: .top) {
                        Toggle("Use \(word.written)", isOn: Binding(get: { word.enabled }, set: { enabled in perform { try store.setWordEnabled(word.id, enabled) } })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(word.written).font(.body.weight(.medium))
                            if !word.spoken.isEmpty { Text("Correction history: " + word.spoken).font(.caption).foregroundStyle(.secondary) }
                            if let app = word.appBundleID { Text(store.library.appStyles.first { $0.bundleID == app }?.name ?? app).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Edit") { editingWordID = word.id; written = word.written; spoken = word.spoken; scopeAppID = word.appBundleID; scopeAppName = word.appBundleID ?? state.writingAppName; scoped = word.appBundleID != nil; message = "Editing \(word.written). Save to update it." }
                        Button("Delete", role: .destructive) { perform { try store.removeWord(word.id) } }
                    }
                }
            }
        }
    }
    private var snippets: some View {
        Group {
            Section("A phrase you use often") {
                TextField("Name", text: $trigger, prompt: Text("review request")).textFieldStyle(.roundedBorder)
                TextEditor(text: $expansion).frame(minHeight: 100).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Snippet text")
                scope
                Button(editingSnippetID == nil ? "Save phrase" : "Save changes") { perform { try store.addSnippet(trigger: trigger, text: expansion, app: app, replacing: editingSnippetID); message = "Saved. Say ‘insert snippet \(trigger)’ to use it."; trigger = ""; expansion = ""; editingSnippetID = nil } }
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Say ‘insert snippet’ followed by its name as the entire dictation. It inserts text, never sends a message or runs a command.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Your phrases") {
                ForEach(store.library.snippets) { snippet in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Insert snippet \(snippet.trigger)").font(.headline)
                            Spacer()
                            Toggle("Use \(snippet.trigger)", isOn: Binding(get: { snippet.enabled }, set: { enabled in perform { try store.setSnippetEnabled(snippet.id, enabled) } })).labelsHidden().toggleStyle(.checkbox)
                        }
                        Text(snippet.text).lineLimit(3).foregroundStyle(.secondary)
                        HStack {
                            if let app = snippet.appBundleID { Text(app).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Edit") { editingSnippetID = snippet.id; trigger = snippet.trigger; expansion = snippet.text; scopeAppID = snippet.appBundleID; scopeAppName = snippet.appBundleID ?? state.writingAppName; scoped = snippet.appBundleID != nil }
                            Button("Delete", role: .destructive) { perform { try store.removeSnippet(snippet.id) } }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private var writing: some View {
        Group {
            Section("Your default") {
                Picker("Writing style", selection: Binding(get: { store.library.defaultStyle }, set: { value in perform { try store.setStyle(value) } })) {
                    ForEach(VoiceWritingStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(store.library.defaultStyle.detail).font(.caption).foregroundStyle(.secondary)
                if let app = state.writingAppID {
                    Button("Use \(store.library.defaultStyle.title) in \(state.writingAppName)") { perform { try store.setStyle(store.library.defaultStyle, app: app, name: state.writingAppName) } }
                }
            }
            Section("Remembered apps") {
                if store.library.appStyles.isEmpty { Text("Choose a style from the menu bar while writing in an app. Murmur will remember it here.").foregroundStyle(.secondary) }
                ForEach(store.library.appStyles) { rule in
                    HStack {
                        Text(rule.name)
                        Spacer()
                        Picker(rule.name, selection: Binding(get: { rule.style }, set: { style in perform { try store.setStyle(style, app: rule.bundleID, name: rule.name) } })) {
                            ForEach(VoiceWritingStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                        Button("Use default") { perform { try store.removeStyle(rule.bundleID) } }
                    }
                }
                Text("App identity chooses the style; Murmur does not read the screen for this. A style is fixed when recording starts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Technical identifiers") {
                Text("In Technical mode, say a complete instruction such as ‘identifier snake case request timeout’ to get request_timeout. Camel case, Pascal case, kebab case and constant case work too.")
                Text("Technical and Verbatim modes keep spoken fillers and repetitions. Natural and Chat use Gemini’s Smart cleanup. Chat only removes a final period on short single-line messages; it preserves questions, numbers and abbreviations.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var scope: some View {
        Toggle("Only in \(scopeAppID == nil ? state.writingAppName : scopeAppName)", isOn: $scoped).disabled(state.writingAppID == nil && scopeAppID == nil)
            .onChange(of: scoped) { _, value in
                if value && scopeAppID == nil { scopeAppID = state.writingAppID; scopeAppName = state.writingAppName }
                if !value { scopeAppID = nil; scopeAppName = "" }
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { message = error.localizedDescription }
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 3_000_000 else { throw PersonalizationStore.InvalidEntry(message: "Choose a library smaller than 3 MB.") }
            imported = try PersonalizationStore.decodeImport(Data(contentsOf: url))
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Murmur-personal-library.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try store.exportData().write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); message = "Library exported." }
    }
}

struct WritingContextView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: PersonalizationStore
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(state.writingAppID == nil ? "Writing style" : state.writingAppName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu(store.library.style(for: state.writingAppID).title) {
                    ForEach(VoiceWritingStyle.allCases, id: \.self) { style in
                        Button(style.title) {
                            do { try store.setStyle(style, app: state.writingAppID, name: state.writingAppName); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    if let app = state.writingAppID, store.library.appStyles.contains(where: { $0.bundleID == app }) {
                        Divider(); Button("Use default") { try? store.removeStyle(app) }
                    }
                }.fixedSize().disabled(state.isActive)
                Button { NotificationCenter.default.post(name: .showWordsSettings, object: nil) } label: { Image(systemName: "character.book.closed") }.buttonStyle(.plain).help("Your words and phrases")
            }
            if let message = error ?? store.storageError { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }
}
