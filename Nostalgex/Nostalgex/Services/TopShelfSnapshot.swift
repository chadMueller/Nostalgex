import Foundation

/// What the Top Shelf extension reads to render "on now" without doing any work
/// of its own.
///
/// The extension is a separate process with its own container, so it cannot see
/// the app's daily manifests, library snapshot, or Keychain. Rather than give it
/// credentials and re-implement scheduling, the app writes this small
/// denormalised file into the shared App Group container every time the lineup
/// changes. The extension then does nothing but decode and display: no network,
/// no credentials, no scheduling logic that could drift from the app's.
struct TopShelfSnapshot: Codable {
    struct Entry: Codable {
        let channelID: Int
        let channelNumber: Int
        let channelName: String
        let title: String
        /// Unix seconds. The extension picks the entry whose window contains
        /// "now", so a snapshot stays correct until the schedule itself moves.
        let startUnix: Int
        let endUnix: Int
        let imageURL: String?
    }

    let generatedUnix: Int
    let entries: [Entry]
}

enum TopShelfStore {
    /// Must match the App Group added to both the app and the extension in
    /// Signing and Capabilities.
    static let appGroupID = "group.com.muellhaus.nostalgex"
    private static let filename = "topshelf.json"

    static var containerURL: URL? {
        #if DEBUG
        if let isolated = HarnessIsolation.topShelfContainer { return isolated }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// tvOS refuses writes at the App Group container root (EPERM); Library/Caches inside
    /// it is the writable spot. The extension reads from the same path.
    private static var fileURL: URL? {
        guard let dir = containerURL?.appendingPathComponent("Library/Caches", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Writing is best-effort by design. Before the App Group is enabled, or if
    /// the container is unavailable, this quietly does nothing: the Top Shelf
    /// falls back to the static image and the app is otherwise unaffected.
    static func write(_ snapshot: TopShelfSnapshot) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Plex90] TOPSHELF: could not write snapshot: \(error.localizedDescription)")
        }
    }

    static func read() -> TopShelfSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
