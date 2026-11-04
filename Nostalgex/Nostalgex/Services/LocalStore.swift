import Foundation
import os

/// Where on-device files live. tvOS refuses writes under Library/Application Support
/// (EPERM), which is why the library snapshot, daily schedules and enrichment cache never
/// persisted on a real Apple TV even though every simulator run showed them working.
/// Library/Caches is the directory tvOS allows; the system may purge it under storage
/// pressure, which costs one rebuild, not correctness.
enum LocalStore {
    static var rootDirectory: URL? {
        #if DEBUG
        if let isolated = HarnessIsolation.localStoreRoot {
            try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
            return isolated
        }
        #endif
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Nostalgex", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            InstallDiagnostics.fail("localstore: could not create \(dir.path): \(String(describing: error))")
            return nil
        }
        return dir
    }
}
