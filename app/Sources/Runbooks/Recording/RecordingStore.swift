import Foundation

/// File naming + sidecar metadata for recordings. Lives under Application
/// Support so it survives independent of the repo working tree.
struct RecordingStore {
    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ai-runbooks/recordings", isDirectory: true)
    }

    func newRecordingURL(startedAt: Date) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: startedAt)
        return directory.appendingPathComponent("recording-\(stamp).mov")
    }

    /// Writes `<name>.json` next to the `.mov` describing the capture.
    func writeSidecar(for movURL: URL, startedAt: Date, duration: TimeInterval, display: String) {
        let sidecar = movURL.deletingPathExtension().appendingPathExtension("json")
        let meta: [String: Any] = [
            "started_at": Self.isoFormatter.string(from: startedAt),
            "duration": duration,
            "display": display,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: sidecar)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}
