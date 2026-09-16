import Foundation
import AppKit
import MulticastCore

/// Appends the session record to disk while the capture runs.
///
/// Plain JSON Lines: one object per line, appendable, and readable afterwards
/// with grep, jq, or a spreadsheet. Nothing here needs the app to still be
/// running, which is the whole point -- the dropout happened at 10:40 and you
/// are looking at 2pm.
public final class SessionWriter {
    public static let folderName = "MulticastView"

    /// Sessions older than this are pruned on startup.
    public var retentionDays: Int
    /// Hard cap per session file, so an unattended capture cannot fill a disk.
    public var maximumBytes: Int

    public private(set) var url: URL?
    public private(set) var bytesWritten = 0
    public private(set) var isTruncated = false
    public private(set) var lastError: String?

    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "MulticastView.session-writer", qos: .utility)

    public init(retentionDays: Int = 30, maximumBytes: Int = 256 * 1024 * 1024) {
        self.retentionDays = retentionDays
        self.maximumBytes = maximumBytes
    }

    deinit { close() }

    /// ~/Library/Application Support/MulticastView/Sessions
    public static func sessionsDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    public func begin(interface: String, at now: Date = Date()) {
        close()
        bytesWritten = 0
        isTruncated = false
        lastError = nil

        guard let directory = SessionWriter.sessionsDirectory() else {
            lastError = "Could not find the Application Support directory"
            return
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let safeInterface = interface.replacingOccurrences(of: "/", with: "-")
            let file = directory.appendingPathComponent("\(formatter.string(from: now))-\(safeInterface).jsonl")

            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
            url = file
            pruneOldSessions(in: directory, now: now)
        } catch {
            lastError = error.localizedDescription
            handle = nil
            url = nil
        }
    }

    /// Writing happens off the caller's thread; the caller is the UI timer and
    /// must not wait on a disk.
    public func append(_ events: [SessionEvent]) {
        guard !events.isEmpty, handle != nil, !isTruncated else { return }
        let text = events.map(\.jsonLine).joined(separator: "\n") + "\n"
        let data = Data(text.utf8)

        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            guard self.bytesWritten + data.count <= self.maximumBytes else {
                self.isTruncated = true
                let notice = "{\"kind\":\"truncated\",\"summary\":\"Session log hit its size limit and stopped.\"}\n"
                try? handle.write(contentsOf: Data(notice.utf8))
                return
            }
            do {
                try handle.write(contentsOf: data)
                self.bytesWritten += data.count
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    public func close() {
        let closing = handle
        handle = nil
        queue.async {
            try? closing?.synchronize()
            try? closing?.close()
        }
    }

    /// Keeps the folder from growing without bound across months of services.
    private func pruneOldSessions(in directory: URL, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        for entry in entries where entry.pathExtension == "jsonl" {
            guard entry != url else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    public static func revealInFinder() {
        guard let directory = sessionsDirectory() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
