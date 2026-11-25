import Foundation

/// Every request goes to the selected mount's authenticated loopback endpoint.
enum DriveWorkspaceService {
    enum ReadError: LocalizedError {
        case unavailable, access, offline, invalidName
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The mount did not return a usable response."
            case .access: return "The mount could not authenticate this request."
            case .offline: return "The folder could not be read. Check the connection and try again."
            case .invalidName: return "This item cannot be opened through the mounted folder."
            }
        }
    }

    struct Volume: Decodable {
        let fs: String
        let diskCache: DiskCache?
        struct DiskCache: Decodable {
            let path: String?
            let pathMeta: String?
            let bytesUsed: Int64?
            let uploadsQueued: Int?
            let uploadsInProgress: Int?
            let erroredFiles: Int?
            let outOfSpace: Bool?
        }
        var isLocalCache: Bool { fs.hasPrefix("synctray_cacheonly:") || fs.hasPrefix("synctray_cacheonly{") }
    }

    struct Entry: Decodable, Identifiable {
        let name: String
        let directory: Bool
        let size: Int64
        let modified: String?
        let remoteID: String?
        enum CodingKeys: String, CodingKey {
            case name = "Name", directory = "IsDir", size = "Size", modified = "ModTime", remoteID = "ID"
        }
        var id: String { (remoteID ?? "") + "/" + name }
        var date: Date? { modified.flatMap(DriveWorkspaceService.timestamp) }
    }

    struct Receipt: Decodable {
        let name: String
        let bytes: Int64?
        let checked: Bool
        let completed_at: String?
        let srcFs: String?
        let dstFs: String?
        let error: String?

        enum CodingKeys: String, CodingKey { case name, bytes, checked, completed_at, srcFs, dstFs, error }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            bytes = try fields.decodeIfPresent(Int64.self, forKey: .bytes)
            checked = try fields.decode(Bool.self, forKey: .checked)
            completed_at = try fields.decodeIfPresent(String.self, forKey: .completed_at)
            srcFs = try fields.decodeIfPresent(String.self, forKey: .srcFs)
            dstFs = try fields.decodeIfPresent(String.self, forKey: .dstFs)
            if !fields.contains(.error) || (try? fields.decodeNil(forKey: .error)) == true {
                error = nil
            } else {
                error = (try? fields.decode(String.self, forKey: .error)) ?? "Transfer failed"
            }
        }
    }

    struct QueueItem: Decodable {
        let name: String
        let uploading: Bool?
    }
    struct Activity {
        var stats: RcloneStats?
        var volume: Volume?
        var history: [Receipt]?
        var queue: [QueueItem]?
        var sampled: Date?
        var active: [TransferringFile] { stats?.transferring ?? [] }

        var status: String {
            guard stats != nil, let volume else { return "Activity unavailable" }
            if volume.isLocalCache { return "Cache only" }
            if !active.isEmpty { return active.count == 1 ? "1 file transferring" : "\(active.count) files transferring" }
            if let count = volume.diskCache?.uploadsInProgress, count > 0 { return "Uploading to Drive" }
            if let count = volume.diskCache?.uploadsQueued, count > 0 { return "Uploads waiting" }
            if let files = stats?.checking, !files.isEmpty { return "Checking files" }
            return "Idle"
        }
    }

    static func read<T: Decodable>(_ type: T.Type, endpoint: String, port: Int,
                                            parameters: [String: Any] = [:], timeout: TimeInterval = 4) async throws -> T {
        guard (1...65535).contains(port) else { throw ReadError.unavailable }
        var request = VFSCacheService.rcRequest(endpoint, port: port)
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(type, from: data)
        case 401, 403: throw ReadError.access
        default: throw ReadError.offline
        }
    }

    static func volume(port: Int) async throws -> Volume {
        let volume = try await read(Volume.self, endpoint: "vfs/stats", port: port)
        guard !volume.fs.isEmpty else { throw ReadError.unavailable }
        return volume
    }

    static func activity(port: Int) async -> Activity {
        struct History: Decodable { let transferred: [Receipt]? }
        struct Queue: Decodable { let queue: [QueueItem]? }
        // rclone encodes an empty history or queue as null in some versions.
        async let mount = try? volume(port: port)
        async let stats = VFSCacheService.shared.getCoreStats(port: port)
        async let history = try? read(History.self, endpoint: "core/transferred", port: port)
        async let queue = try? read(Queue.self, endpoint: "vfs/queue", port: port)
        let (v, s, h, q) = await (mount, stats, history, queue)
        let receipts = h.map {
            ($0.transferred ?? []).filter { receipt in
                !receipt.checked && receipt.completed_at.flatMap(timestamp) != nil
                    && !(receipt.completed_at ?? "").hasPrefix("0001-")
            }.sorted { ($0.completed_at ?? "") > ($1.completed_at ?? "") }
        }
        return Activity(stats: s?.transfers == nil && s?.transferring == nil ? nil : s,
                        volume: v, history: receipts, queue: q.map { $0.queue ?? [] }, sampled: Date())
    }

    static func list(profile: SyncProfile, components: [String]) async throws -> [Entry] {
        guard components.allSatisfy(validComponent) else { throw ReadError.invalidName }
        guard SyncSetupService.shared.isMounted(profile: profile) else { throw ReadError.offline }
        // Listing the mounted namespace respects the profile's exclusions, native-document
        // names and Cache Only rules, including its protection against partial files.
        struct Listing: Decodable { let list: [Entry] }
        let result = try await read(Listing.self, endpoint: "operations/list", port: profile.rcPort,
                                    parameters: ["fs": profile.localSyncPath, "remote": components.joined(separator: "/"),
                                                 "opt": ["recurse": false, "noMimeType": true]], timeout: 25)
        try Task.checkCancellation()
        guard SyncSetupService.shared.isMounted(profile: profile) else { throw ReadError.offline }
        return result.list.filter { validComponent($0.name) }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    enum Availability: String {
        case cached = "Cached", partial = "Partial cache", onDemand = "On demand", pending = "Local changes", unknown = "Unknown"
    }

    struct CacheRoots: Equatable {
        let data: String
        let meta: String
        init?(volume: Volume?, profile: SyncProfile) {
            guard let volume, !volume.isLocalCache,
                  let data = volume.diskCache?.path, let meta = volume.diskCache?.pathMeta,
                  VFSCacheService.isPath(data, inside: (profile.vfsCachePath as NSString).appendingPathComponent("vfs")),
                  VFSCacheService.isPath(meta, inside: (profile.vfsCachePath as NSString).appendingPathComponent("vfsMeta")) else { return nil }
            self.data = data
            self.meta = meta
        }
        init(data: String, meta: String) { self.data = data; self.meta = meta }
    }

    static func availability(components: [String], size: Int64, roots: CacheRoots) -> Availability {
        guard components.allSatisfy(validComponent), !components.isEmpty, size >= 0 else { return .unknown }
        let relative = components.joined(separator: "/")
        let data = (roots.data as NSString).appendingPathComponent(relative)
        let meta = (roots.meta as NSString).appendingPathComponent(relative)
        guard VFSCacheService.isPath(data, inside: roots.data), VFSCacheService.isPath(meta, inside: roots.meta) else { return .unknown }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: data)
        } catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError ? .onDemand :
                (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .onDemand : .unknown)
        }
        guard let bytes = FileManager.default.contents(atPath: meta),
              let record = try? JSONDecoder().decode(VFSCacheService.VFSCacheMeta.self, from: bytes) else { return .unknown }
        if record.Dirty == true { return .pending }
        return VFSCacheService.isCacheComplete(meta: record, expectedSize: size) ? .cached : .partial
    }

    static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    static func timestamp(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    static func direction(source: String?, destination: String?, volume: String?) -> String? {
        guard let volume, !volume.isEmpty else { return nil }
        if source == volume && destination != volume { return "Download" }
        if destination == volume && source != volume { return "Upload" }
        return nil
    }
}
