import Foundation
import CryptoKit

enum ArchiveDriveCheck {
    struct Plan {
        let remote: String
        let folder: [String]
        let expected: [String: String]
        let signature: String

        init?(folder: String?, digests: [String: String]) {
            guard let folder, !digests.isEmpty, let first = digests.keys.first,
                  let colon = first.firstIndex(of: ":") else { return nil }
            let remote = String(first[..<colon])
            let parts = folder.components(separatedBy: "/")
            guard !remote.isEmpty, parts.allSatisfy(DriveWorkspaceService.validComponent) else { return nil }
            let prefix = remote + ":" + folder + "/"
            var expected = [String: String]()
            for (path, hash) in digests {
                guard path.hasPrefix(prefix), hash.count == 32, hash.allSatisfy(\.isHexDigit) else { return nil }
                let relative = String(path.dropFirst(prefix.count))
                guard relative.components(separatedBy: "/").allSatisfy(DriveWorkspaceService.validComponent) else { return nil }
                expected[relative] = hash.lowercased()
            }
            self.remote = remote
            self.folder = parts
            self.expected = expected
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(digests) else { return nil }
            signature = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        func relativeFolder(mountFS: String) -> String? {
            guard let colon = mountFS.firstIndex(of: ":") else { return nil }
            let name = String(mountFS[..<colon])
            guard name == remote || (name.hasPrefix(remote + "{") && name.hasSuffix("}")) else { return nil }
            let root = mountFS[mountFS.index(after: colon)...].split(separator: "/").map(String.init)
            guard folder.starts(with: root) else { return nil }
            // An empty relative path is safe here only when this mount already points
            // at the exact archive directory in the worker's report.
            return folder.dropFirst(root.count).joined(separator: "/")
        }
    }

    struct Object: Decodable {
        let Path: String
        let Hashes: [String: String]?
    }
    struct Receipt: Codable {
        let signature: String
        let checked: Date
        let total: Int
        var matched: Int
        var problems: [String]
        var passed: Bool { total > 0 && matched == total }
    }

    static func compare(_ objects: [Object], with plan: Plan, listedFolder: String = "") -> Receipt {
        let prefix = listedFolder.isEmpty ? "" : listedFolder + "/"
        let byPath = Dictionary(grouping: objects.filter { $0.Path.hasPrefix(prefix) }) {
            String($0.Path.dropFirst(prefix.count))
        }
        var receipt = Receipt(signature: plan.signature, checked: Date(), total: plan.expected.count, matched: 0, problems: [])
        for (path, hash) in plan.expected.sorted(by: { $0.key < $1.key }) {
            let matches = byPath[path] ?? []
            let problem: String
            if matches.isEmpty { problem = "Missing from Drive" }
            else if matches.count != 1 { problem = "Duplicate path on Drive" }
            else if let md5 = matches.first?.Hashes?["md5"], !md5.isEmpty {
                if md5.lowercased() == hash { receipt.matched += 1; continue }
                problem = "Checksum differs"
            } else { problem = "Drive supplied no MD5" }
            if receipt.problems.count < 12 { receipt.problems.append("\(problem) · \(path)") }
        }
        return receipt
    }

    static func verify(_ plan: Plan, profiles: [SyncProfile]) async throws -> Receipt {
        struct Listing: Decodable { let list: [Object] }
        let candidates = profiles.filter { $0.isMountMode && $0.primaryRemoteName == plan.remote }
        for profile in candidates {
            try Task.checkCancellation()
            guard SyncSetupService.shared.isMounted(profile: profile),
                  let volume = try? await DriveWorkspaceService.volume(port: profile.rcPort), !volume.isLocalCache,
                  let folder = plan.relativeFolder(mountFS: volume.fs) else { continue }
            let options: [String: Any] = ["recurse": true, "filesOnly": true, "showHash": true,
                                          "hashTypes": ["md5"], "noMimeType": true, "noModTime": true]
            let response = try await DriveWorkspaceService.read(Listing.self, endpoint: "operations/list", port: profile.rcPort,
                parameters: ["fs": volume.fs, "remote": folder, "opt": options], timeout: 150)
            try Task.checkCancellation()
            return compare(response.list, with: plan, listedFolder: folder)
        }
        struct NoMount: LocalizedError {
            var errorDescription: String? { "Mount the archive’s Drive connection in streaming mode to check its cloud copies." }
        }
        throw NoMount()
    }
}
