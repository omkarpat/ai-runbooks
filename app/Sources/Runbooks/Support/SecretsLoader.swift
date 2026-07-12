import Foundation

/// Resolves secrets (API keys) for local dev. Prefers the process environment,
/// then falls back to a `.env` file found by walking up from the current
/// directory and the app bundle. Values may use `KEY=value` or `KEY = value`
/// and optional surrounding quotes. `.env` is git-ignored — never commit it.
enum SecretsLoader {
    static func value(for key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return dotenv[key]
    }

    private static let dotenv: [String: String] = loadDotenv()

    private static func loadDotenv() -> [String: String] {
        for url in candidateURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return parse(text)
            }
        }
        return [:]
    }

    /// `.env` candidates: current working dir and the app bundle location, each
    /// walked up a few levels (covers `make run` from `app/` and a bundle sitting
    /// inside the repo).
    private static func candidateURLs() -> [URL] {
        var roots: [URL] = []
        let starts = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL,
        ]
        for start in starts {
            var dir = start
            for _ in 0..<6 {
                roots.append(dir)
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return roots.map { $0.appendingPathComponent(".env") }
    }

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
