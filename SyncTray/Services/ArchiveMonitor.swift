import Foundation
import Darwin

/// Project Archive Backup owns these files. The dashboard only reads its receipts.
enum ArchiveMonitor {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Project Archive Backup")
    static let installed = FileManager.default.fileExists(atPath: base.path)

    // Older installations select a separate rclone config for their Stream mount.
    // This is connection bootstrap only. The retired per-file queue never supplies status.
    static func preserveMountConnection() {
        guard ProcessInfo.processInfo.environment["RCLONE_CONFIG"] == nil else { return }
        let config = base.deletingLastPathComponent().appendingPathComponent("Project Backup/config.json")
        struct Connection: Decodable { let rclone_config: String }
        guard let data = try? Data(contentsOf: config),
              let connection = try? JSONDecoder().decode(Connection.self, from: data),
              FileManager.default.isReadableFile(atPath: connection.rclone_config) else { return }
        setenv("RCLONE_CONFIG", connection.rclone_config, 0)
        setenv("SYNCTRAY_ON_DEMAND_ONLY", "1", 0)
    }

    struct Project: Identifiable {
        let id: String
        var name: String { (id as NSString).lastPathComponent }
        var parent: String { (id as NSString).deletingLastPathComponent }
        var verifiedAt: String?
        var failure: String?
    }

    struct Run: Decodable {
        let started: String
        let finished: String
        let archived: Int
        let unchanged: Int
        let failed: Int
        let skipped: Int
        let metal_missing: Bool
        let metal_dropped: Bool?
        let locked: [String]?
        let lost: [String]?
        let vanished: [Vanished]?
        let drive_warning: String?
        let only: String?
        let retry_run: Bool?

        struct Vanished: Decodable {
            init(from decoder: Decoder) throws {
                var pair = try decoder.unkeyedContainer()
                _ = try pair.decode(String.self)
                _ = try pair.decode(Int.self)
            }
        }
        var scope: String {
            if let only, !only.isEmpty { return "Selected projects" }
            return retry_run == true ? "Retry run" : "Weekly run"
        }
        var warnings: [String] {
            var result = [String]()
            if failed > 0 { result.append("\(failed) failed") }
            if skipped > 0 { result.append("\(skipped) skipped") }
            if metal_missing || metal_dropped == true || !(lost ?? []).isEmpty { result.append("Source disk unavailable") }
            if let count = locked?.count, count > 0 { result.append("\(count) locked items omitted") }
            if let count = vanished?.count, count > 0 { result.append("Files disappeared in \(count) projects") }
            if let drive_warning, !drive_warning.isEmpty { result.append(drive_warning) }
            return result
        }
    }

    enum Health { case passed, working, warning, unknown }
    struct Snapshot {
        var projects = [Project]()
        var drivePlan: ArchiveDriveCheck.Plan?
        var run: Run?
        var lastFull: Date?
        var retryCount: Int?
        var scheduler: Bool?
        var running: Bool?
        var issue: String?
        var verifiedCount: Int { projects.filter { $0.verifiedAt != nil }.count }

        func health(now: Date = Date()) -> Health {
            if running == true { return .working }
            if scheduler == false || (retryCount ?? 0) > 0 || !(run?.warnings ?? []).isEmpty { return .warning }
            guard issue == nil, let run, let lastFull, scheduler == true, running == false,
                  retryCount == 0, verifiedCount > 0, run.archived + run.unchanged > 0 else { return .unknown }
            return now.timeIntervalSince(lastFull) <= 7 * 86400 ? .passed : .warning
        }
        var title: String {
            switch health() {
            case .working: return "Archive check running"
            case .passed: return "Backup checks passed"
            case .unknown: return "Backup evidence incomplete"
            case .warning:
                if scheduler == false { return "Scheduler stopped" }
                if (retryCount ?? 0) > 0 { return "Projects need attention" }
                if !(run?.warnings ?? []).isEmpty { return "Last run needs attention" }
                return "Weekly check overdue"
            }
        }
    }

    static func sample() -> Snapshot {
        var s = Snapshot()
        s.running = holdsLock(base.appendingPathComponent("run.lock"))
        s.scheduler = schedulerLoaded()
        do { try read(base: base, into: &s) } catch { s.issue = error.localizedDescription }
        return s
    }

    static func read(base: URL, into snapshot: inout Snapshot) throws {
        let data = try Data(contentsOf: base.appendingPathComponent("state.json"))
        guard let ledger = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = ledger["_meta"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let failures = meta["failing"] as? [String: [String: Any]]
        snapshot.retryCount = failures?.count
        if let time = meta["last_full_run"] as? Double, time > 0 { snapshot.lastFull = Date(timeIntervalSince1970: time) }
        var projects = [String: Project]()
        var digests = [String: String]()
        for (key, value) in ledger where !key.hasPrefix("_") {
            guard let record = value as? [String: Any], let verified = record["verified"] as? Bool else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if verified {
                guard let at = record["at"] as? String, !at.isEmpty,
                      let md5 = record["md5"] as? String, md5.count == 32,
                      let remote = record["remote"] as? String, !remote.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                guard digests.updateValue(md5, forKey: remote) == nil else { throw CocoaError(.fileReadCorruptFile) }
                projects[key] = Project(id: key, verifiedAt: at)
            }
        }
        for (key, failure) in failures ?? [:] {
            projects[key, default: Project(id: key)].failure = failure["error"] as? String ?? "See the archive report"
        }
        snapshot.projects = projects.values.sorted { a, b in
            if (a.failure != nil) != (b.failure != nil) { return a.failure != nil }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }

        let status = try chunk(base.appendingPathComponent("STATUS.txt"), tail: false)
        let folderLabel = "Drive folder: "
        let folder = status.components(separatedBy: .newlines).first { $0.hasPrefix(folderLabel) }.map { String($0.dropFirst(folderLabel.count)) }
        snapshot.drivePlan = ArchiveDriveCheck.Plan(folder: folder, digests: digests)
        let log = try chunk(base.appendingPathComponent("logs/weekly.out.log"), tail: true)
        guard let header = status.split(separator: "\n").first,
              let line = log.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let run = try? JSONDecoder().decode(Run.self, from: Data(line.utf8)),
              header == "PROJECT ARCHIVE BACKUP — last run \(run.started) to \(run.finished)",
              status.components(separatedBy: .newlines).contains("Projects with a verified archive: \(snapshot.verifiedCount)") else {
            snapshot.issue = "The latest report and completed run do not match yet. Open the report for details."
            return
        }
        snapshot.run = run
        if failures == nil { snapshot.issue = "This ledger does not report pending retries." }
    }

    private static func chunk(_ url: URL, tail: Bool) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 256 * 1024
        if tail {
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > limit ? size - UInt64(limit) : 0)
        }
        return String(decoding: try file.read(upToCount: limit) ?? Data(), as: UTF8.self)
    }

    static func holdsLock(_ url: URL) -> Bool? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK ? true : nil
    }

    private static func schedulerLoaded() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.local.project-archive-backup"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        switch process.terminationStatus { case 0: return true; case 113: return false; default: return nil }
    }
}
