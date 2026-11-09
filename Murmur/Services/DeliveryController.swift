import AppKit
import MurmurKit

@MainActor
protocol VoiceTextDelivering: AnyObject {
    func capture()
    func insert(_ text: String) -> TextInserter.Outcome
    func undo() -> Bool
    func clear()
    func expireUndo()
    func activateOriginal()
}

/// Owns only Murmur's clipboard write, never a general clipboard history.
@MainActor
final class ClipboardDelivery {
    private let pasteboard: NSPasteboard
    private var previous: [[NSPasteboard.PasteboardType: Data]]?
    private var writtenChange: Int?
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var canRestore: Bool { previous != nil && writtenChange == pasteboard.changeCount }

    @discardableResult func copy(_ text: String, retainPrevious: Bool = true) -> Bool {
        expire()
        let items = pasteboard.pasteboardItems ?? []
        let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        var size = 0
        var mayRestore = retainPrevious && !items.contains { item in item.types.contains { privateTypes.contains($0.rawValue) } }
        if mayRestore {
            for item in items {
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { continue }
                    size += data.count
                    guard size <= 1_048_576 else { mayRestore = false; break }
                    values[type] = data
                }
                if !mayRestore { break }
                if values.isEmpty && !item.types.isEmpty { mayRestore = false; break }
                snapshot.append(values)
            }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else { return false }
        if mayRestore { previous = snapshot; writtenChange = pasteboard.changeCount }
        return true
    }
    func restore() -> Bool {
        guard canRestore, let previous else { expire(); return false }
        defer { expire() }
        let items = previous.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }
    func expire() { previous = nil; writtenChange = nil }
}

@MainActor
final class DeliveryController {
    enum Status: String { case none, inserted, copied, changed, unavailable, clipboardFailed, undone }
    private let clipboard: ClipboardDelivery
    private let inserter: any VoiceTextDelivering
    private var expiry: Task<Void, Never>?
    private var inserted = false
    private var undoAvailable = false
    private(set) var status: Status = .none
    private(set) var message = ""
    private(set) var text = ""
    var retainClipboardForUndo: () -> Bool = { true }
    var onChange: (() -> Void)?
    var canUndo: Bool { undoAvailable && (inserted || clipboard.canRestore) }
    var canRetry: Bool { !text.isEmpty && [.changed, .unavailable].contains(status) }
    init(clipboard: ClipboardDelivery? = nil, inserter: (any VoiceTextDelivering)? = nil) {
        self.clipboard = clipboard ?? ClipboardDelivery(); self.inserter = inserter ?? TextInserter()
    }
    func capture(allowInsertion: Bool = true) {
        expire(); text = ""; status = .none; message = ""
        if allowInsertion { inserter.capture() } else { inserter.clear() }
        onChange?()
    }
    func discardAnchor() { inserter.clear() }
    @discardableResult func deliver(_ text: String, insert: Bool) -> Status {
        expire()
        self.text = text
        let copied = clipboard.copy(text, retainPrevious: retainClipboardForUndo())
        if insert { applyInsertion(text, copied: copied) }
        else { status = copied ? .copied : .clipboardFailed; message = copied ? "Copied. Ready to paste." : "Clipboard unavailable. Your result is ready to review." }
        undoAvailable = inserted || clipboard.canRestore
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.expire(); self?.onChange?()
        }
        onChange?()
        return status
    }
    func copyAgain() {
        guard !text.isEmpty else { return }
        _ = deliver(text, insert: false)
    }
    func prepareOriginalField() { if inserted || canRetry { inserter.activateOriginal() } }
    func retryOriginalField() {
        guard canRetry else { return }
        // The inserter rechecks the captured process, element, text and selection.
        applyInsertion(text, copied: false)
        undoAvailable = inserted || clipboard.canRestore
        onChange?()
    }
    func undo() {
        guard canUndo else { return }
        let fieldRestored = inserted ? inserter.undo() : false
        let clipboardRestored = clipboard.restore()
        if inserted && !fieldRestored {
            message = clipboardRestored ? "Clipboard restored. The field changed, so its text was left untouched." : "The field or clipboard changed. Nothing was overwritten."
        } else {
            message = fieldRestored ? "Last insertion undone." : clipboardRestored ? "Previous clipboard restored." : "Clipboard changed. Nothing was overwritten."
        }
        expire(); status = .undone; onChange?()
    }
    func expireClipboard() { clipboard.expire(); onChange?() }
    func expire() {
        expiry?.cancel(); expiry = nil
        clipboard.expire(); inserter.expireUndo()
        inserted = false; undoAvailable = false
    }
    private func applyInsertion(_ text: String, copied: Bool) {
        switch inserter.insert(text) {
        case .inserted: inserted = true; status = .inserted; message = "Inserted into your original field."
        case .changed: status = .changed; message = "Your field or cursor changed. \(copied ? "Copied instead;" : "Return to the original field, then") try again or review the result."
        case .unavailable: status = .unavailable; message = copied ? "Copied. This field couldn't accept direct insertion." : "The original field is unavailable. Copy or review your result."
        }
    }
}
