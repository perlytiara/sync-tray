#if DEBUG
import Foundation
import Darwin

enum DriveWorkspaceSelfTest {
    private struct Failed: Error, CustomStringConvertible { var description: String }
    static func run() -> Int32 {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw Failed(description: name) }
            count += 1
        }
        do {
            let decoder = JSONDecoder()
            func json<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
                try decoder.decode(type, from: Data(text.utf8))
            }
            let quiet = try json(RcloneStats.self, #"{"transfers":3,"bytes":12000}"#)
            let volume = try json(DriveWorkspaceService.Volume.self,
                #"{"fs":"sample:","diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#)
            var activity = DriveWorkspaceService.Activity(stats: quiet, volume: volume)
            try check(activity.status == "Idle", "cumulative bytes do not imply a live transfer")
            activity.stats = try json(RcloneStats.self, #"{"transferring":[{"name":"example.mp4","bytes":100,"size":200,"srcFs":"sample:"}]}"#)
            try check(activity.active.first?.srcFs == "sample:" && activity.status == "1 file transferring", "named live transfer")
            try check(DriveWorkspaceService.direction(source: nil, destination: "sample:", volume: "sample:") == "Upload", "upload direction")
            try check(DriveWorkspaceService.direction(source: nil, destination: nil, volume: "sample:") == nil, "unknown direction")
            activity.stats = nil
            try check(activity.status == "Activity unavailable", "missing telemetry is unknown")
            activity.stats = quiet
            activity.volume = try json(DriveWorkspaceService.Volume.self, #"{"fs":"synctray_cacheonly:"}"#)
            try check(activity.status == "Cache only", "offline cache")
            activity.volume = try json(DriveWorkspaceService.Volume.self, #"{"fs":"sample:","diskCache":{"uploadsQueued":2}}"#)
            try check(activity.status == "Uploads waiting", "pending writes are visible")
            let receipt = try json(DriveWorkspaceService.Receipt.self, #"{"name":"unfinished.txt","checked":false,"error":{"message":"offline"}}"#)
            try check(receipt.error != nil, "failed receipt stays failed")
            try check(DriveWorkspaceService.timestamp("2026-08-04T13:24:12.123456789+02:00") != nil, "rclone date")
            try check(["../file","..",".","a/b",""].allSatisfy { !DriveWorkspaceService.validComponent($0) } &&
                      DriveWorkspaceService.validComponent("Design #2 🎬"), "single-component navigation")

            let fm = FileManager.default
            try fm.createDirectory(at: base.appendingPathComponent("logs"), withIntermediateDirectories: true)
            func write(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: base.appendingPathComponent(file)) }
            let cache = base.appendingPathComponent("vfs/test")
            let metadata = base.appendingPathComponent("vfsMeta/test")
            for url in [cache, metadata] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            let roots = DriveWorkspaceService.CacheRoots(data: cache.path, meta: metadata.path)
            func presence() -> DriveWorkspaceService.Availability {
                DriveWorkspaceService.availability(components: ["clip.mp4"], size: 4, roots: roots)
            }
            try check(presence() == .onDemand, "remote-only file")
            try Data([1, 2, 3, 4]).write(to: cache.appendingPathComponent("clip.mp4"))
            try write("vfsMeta/test/clip.mp4", #"{"Size":4,"Rs":[{"Pos":0,"Size":2}]}"#)
            try check(presence() == .partial, "partial local file")
            try write("vfsMeta/test/clip.mp4", #"{"Size":4,"Rs":[{"Pos":0,"Size":4}]}"#)
            try check(presence() == .cached, "complete local ranges")
            try write("vfsMeta/test/clip.mp4", #"{"Size":4,"Dirty":true}"#)
            try check(presence() == .pending, "unpublished local changes")
            let recorded = "2026-09-06 11:00"
            let now = Date()
            let complete: [String: Any] = ["started": "2026-09-06 10:00", "finished": recorded, "archived": 1, "unchanged": 2,
                                           "failed": 0, "skipped": 0, "metal_missing": false, "locked": []]
            let archived: [String: Any] = ["verified": true, "at": "2026-09-06T10:50:00",
                "md5": String(repeating: "a", count: 32), "remote": "sample:Archives/example.tar.zst"]
            func save(_ file: String, _ object: Any) throws {
                try JSONSerialization.data(withJSONObject: object).write(to: base.appendingPathComponent(file))
            }
            let connection = base.appendingPathComponent("fixture.conf")
            try write("fixture.conf", "")
            let settings = base.appendingPathComponent("connection.json")
            try save("connection.json", ["rclone_config": connection.path])
            try check(ArchiveMonitor.mountConfig(from: settings, overriding: nil) == connection.path, "GUI and CLI discover the existing mount connection")
            try check(ArchiveMonitor.mountConfig(from: settings, overriding: "explicit.conf") == nil, "explicit rclone connection wins")
            func state(failing: [String: Any]) throws {
                try save("state.json", ["Studio/Design": archived, "_meta": ["failing": failing, "last_full_run": now.timeIntervalSince1970]])
            }
            func read() throws -> ArchiveMonitor.Snapshot {
                var s = ArchiveMonitor.Snapshot(scheduler: true, running: false)
                try ArchiveMonitor.read(base: base, into: &s)
                return s
            }
            try write("STATUS.txt", "PROJECT ARCHIVE BACKUP — last run 2026-09-06 10:00 to \(recorded)\nProjects with a verified archive: 1\n")
            try save("logs/weekly.out.log", complete)
            try state(failing: [:])
            var s = try read()
            try check(s.health(now: now) == .passed && s.verifiedCount == 1, "completed weekly evidence")
            try check(s.health(now: now.addingTimeInterval(8 * 86400)) == .warning, "overdue full run")
            s.scheduler = false
            try check(s.health(now: now) == .warning, "unloaded scheduler")
            s.scheduler = nil
            try check(s.health(now: now) == .unknown, "unavailable scheduler")
            try state(failing: ["Studio/Design": ["error": "Drive disconnected"]])
            s = try read()
            try check(s.retryCount == 1 && s.projects.first?.verifiedAt != nil && s.health(now: now) == .warning, "failed retry alongside older verified archive")
            try state(failing: [:])
            var scoped = complete
            scoped["only"] = "Design"
            scoped["locked"] = ["locked.txt"]
            try save("logs/weekly.out.log", scoped)
            s = try read()
            try check(s.run?.scope == "Selected projects" && abs(s.lastFull?.timeIntervalSince(now) ?? 1) < 0.0001 && s.health(now: now) == .warning, "scoped runs and reported omissions")
            try write("STATUS.txt", "PROJECT ARCHIVE BACKUP — last run now to STILL RUNNING\n")
            s = try read()
            try check(s.run == nil && s.health(now: now) == .unknown, "mismatched report is unknown")
            let lockURL = base.appendingPathComponent("run.lock")
            try write("run.lock", "12345")
            try check(ArchiveMonitor.holdsLock(lockURL) == false, "stale PID is idle")
            let fd = Darwin.open(lockURL.path, O_RDWR)
            guard fd >= 0 else { throw Failed(description: "open fixture lock") }
            defer { Darwin.close(fd) }
            try check(flock(fd, LOCK_EX | LOCK_NB) == 0 && ArchiveMonitor.holdsLock(lockURL) == true, "live lock")
            s.running = true
            try check(s.health(now: now) == .working, "in-progress work is visible")
            let digest = String(repeating: "a", count: 32)
            guard let plan = ArchiveDriveCheck.Plan(folder: "Backups/Archives", digests: ["sample:Backups/Archives/snapshot.tgz": digest]) else {
                throw Failed(description: "archive verification plan")
            }
            try check(plan.relativeFolder(mountFS: "sample{x}:Backups") == "Archives" &&
                      plan.relativeFolder(mountFS: "other:") == nil, "archive scope matches the active mount")
            try check(ArchiveDriveCheck.Plan(folder: "", digests: ["sample:file": digest]) == nil &&
                      ArchiveDriveCheck.Plan(folder: "Backups", digests: ["sample:../file": digest]) == nil, "verification never falls back to the account root")
            let object = ArchiveDriveCheck.Object(Path: "Archives/snapshot.tgz", Hashes: ["md5": digest])
            try check(ArchiveDriveCheck.compare([object], with: plan, listedFolder: "Archives").passed, "cloud metadata matches the ledger")
            try check(!ArchiveDriveCheck.compare([], with: plan).passed &&
                      !ArchiveDriveCheck.compare([object, object], with: plan, listedFolder: "Archives").passed, "missing or ambiguous copies fail")
            try check(!ArchiveDriveCheck.compare([.init(Path: "snapshot.tgz", Hashes: ["md5": "different"])], with: plan).passed,
                      "changed remote hash fails")
            try write("state.json", "damaged")
            do { _ = try read(); throw Failed(description: "accepted unreadable ledger") } catch is Failed { throw Failed(description: "accepted unreadable ledger") } catch { count += 1 }
            print("Drive workspace: \(count) checks passed.")
            return 0
        } catch {
            print("Drive workspace check failed: \(error)")
            return 1
        }
    }
}
#endif
