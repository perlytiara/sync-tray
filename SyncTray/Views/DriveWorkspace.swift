import SwiftUI
import AppKit

struct WorkspaceBanner: View {
    let title: String
    let detail: String
    let icon: String
    var archive = false

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: archive ? [Color(red: 0.15, green: 0.18, blue: 0.32), Color(red: 0.25, green: 0.27, blue: 0.48)] :
                            [Color(red: 0.04, green: 0.18, blue: 0.22), Color(red: 0.05, green: 0.35, blue: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let center = CGPoint(x: size.width - 56, y: size.height * 0.5)
                for index in 0..<10 {
                    let radius = CGFloat(44 + 16 * index)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius * 0.67,
                                      width: 2 * radius, height: 1.34 * radius)
                    var transform = CGAffineTransform(translationX: center.x, y: center.y)
                    transform = transform.rotated(by: -0.38).translatedBy(x: -center.x, y: -center.y)
                    let path = Path(ellipseIn: rect).applying(transform)
                    context.stroke(path, with: .color(.white.opacity(0.17 - 0.011 * Double(index))), lineWidth: 1)
                }
            }.accessibilityHidden(true)
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(.system(size: 34, weight: .semibold)).tracking(-1)
                    Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                }
                Spacer()
                Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.92))
                    .frame(width: 62).accessibilityHidden(true)
            }.foregroundStyle(.white).padding(.horizontal, 26)
        }
        .frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct WorkspaceMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 16, weight: .medium))
                .frame(width: 29, height: 29).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceMessage: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }.padding(.vertical, 15).padding(.horizontal, 12)
    }
}

struct DriveWorkspace: View {
    let profile: SyncProfile
    @EnvironmentObject private var manager: SyncManager
    @State private var page: Page = .files
    @State private var components = [String]()
    @State private var entries = [DriveWorkspaceService.Entry]()
    @State private var query = ""
    @State private var showHidden = false
    @State private var listing = false
    @State private var listingError: String?
    @State private var openError: String?
    @State private var revision = 0
    @State private var activity = DriveWorkspaceService.Activity()
    enum Page: Hashable { case files, activity }
    private var mounted: Bool { manager.mountState(for: profile.id) == .mounted }
    private var cacheOnly: Bool { manager.mountMode(for: profile.id)?.isCacheOnly == true || activity.volume?.isLocalCache == true }
    private var modeDescription: String {
        if !mounted { return manager.mountState(for: profile.id).statusText }
        if cacheOnly { return "Cache only · working from local files" }
        if activity.sampled == nil { return "Connecting to the Drive mount…" }
        if activity.volume == nil { return "Mount present · connection unavailable" }
        return "Stream on demand · " + activity.status
    }
    private var visible: [DriveWorkspaceService.Entry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private struct Location: Equatable {
        var profile: UUID
        var path: [String]
        var mounted: Bool
        var cacheOnly: Bool
        var revision: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceBanner(title: profile.name.isEmpty ? "My Drive" : profile.name,
                                detail: modeDescription, icon: "externaldrive.badge.icloud")
                metrics
                HStack {
                    Picker("Drive view", selection: $page) {
                        Text("Files").tag(Page.files)
                        Text("Activity").tag(Page.activity)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 184)
                    Spacer()
                    Button { openInMount(components, file: false) } label: { Label("Show in Finder", systemImage: "folder") }
                        .disabled(!mounted)
                    Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh Drive").accessibilityLabel("Refresh Drive")
                }
                Divider()
                if !mounted {
                    WorkspaceMessage(icon: "externaldrive.badge.exclamationmark", title: "Drive is disconnected",
                                     detail: "Open this drive under Connections to check its mount.")
                } else if page == .files {
                    browser
                } else {
                    DriveActivityView(activity: activity, cacheOnly: cacheOnly)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: Location(profile: profile.id, path: components, mounted: mounted, cacheOnly: cacheOnly, revision: revision)) {
            await loadFolder()
        }
        .task(id: Location(profile: profile.id, path: [], mounted: mounted, cacheOnly: false, revision: revision)) {
            activity = .init()
            guard mounted else { return }
            while !Task.isCancelled {
                let sample = await DriveWorkspaceService.activity(port: profile.rcPort)
                guard !Task.isCancelled else { return }
                activity = sample
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        .alert("Couldn’t open this item", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") { openError = nil }
        } message: { Text(openError ?? "") }
    }

    private var metrics: some View {
        let disk = activity.volume?.diskCache
        let reachable = mounted && activity.volume != nil
        let clear = !cacheOnly && disk?.uploadsQueued == 0 && disk?.uploadsInProgress == 0 && disk?.erroredFiles == 0
        let pendingOffline = cacheOnly ? manager.pendingUploadCount(for: profile.id) : 0
        let upload = cacheOnly ? (pendingOffline > 0 ? "\(pendingOffline) offline edits" : "Offline") :
            (disk?.erroredFiles ?? 0) > 0 ? "Write errors" :
            (clear ? "Queue clear" : disk?.uploadsQueued.map { "\($0) queued · \(disk?.uploadsInProgress ?? 0) active" } ?? "Unavailable")
        return HStack {
            WorkspaceMetric(title: "Connection", value: !mounted ? "Disconnected" : (cacheOnly ? "Cache only" : (reachable ? "Mounted" : (activity.sampled == nil ? "Checking" : "Unavailable"))),
                            icon: reachable && !cacheOnly ? "checkmark.circle.fill" : "externaldrive", color: reachable && !cacheOnly ? .green : .secondary)
            Divider().padding(.horizontal, 6)
            WorkspaceMetric(title: "Uploads", value: upload, icon: clear ? "checkmark.circle.fill" : "arrow.up.circle",
                            color: clear ? .green : disk == nil ? .secondary : .orange)
            Divider().padding(.horizontal, 6)
            WorkspaceMetric(title: "Local cache", value: disk?.outOfSpace == true ? "Out of space" : disk?.bytesUsed.map(Self.bytes) ?? "Unavailable",
                            icon: "internaldrive", color: disk?.outOfSpace == true ? .orange : .teal)
        }.padding(.horizontal, 4).frame(height: 41)
    }

    @ViewBuilder private var browser: some View {
        let roots = DriveWorkspaceService.CacheRoots(volume: activity.volume, profile: profile)
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { navigate([]) } label: { Label("My Drive", systemImage: "externaldrive") }
                    ForEach(components.indices, id: \.self) { index in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(components[index]) { navigate(Array(components.prefix(index + 1))) }
                    }
                }.buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in this folder", text: $query).textFieldStyle(.plain)
            }.padding(7).frame(width: 172).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Toggle("Show hidden files", isOn: $showHidden)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Browser options")
        }
        if listing {
            HStack { ProgressView().controlSize(.small); Text("Loading folder…").foregroundStyle(.secondary) }.padding(.vertical, 16)
        } else if let listingError {
            WorkspaceMessage(icon: "wifi.exclamationmark", title: "Folder unavailable", detail: listingError)
            Button("Try again") { revision += 1 }
        } else if visible.isEmpty {
            WorkspaceMessage(icon: query.isEmpty ? "folder" : "magnifyingglass",
                             title: query.isEmpty ? "Empty folder" : "No matching files",
                             detail: query.isEmpty ? "This folder has no visible items." : "Try another name in this folder.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Name"); Spacer(); Text("Availability").frame(width: 94, alignment: .leading); Text("Modified").frame(width: 100, alignment: .trailing)
                    Text("Size").frame(width: 78, alignment: .trailing)
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        Button {
                            let path = components + [entry.name]
                            if entry.directory { navigate(path) } else { openInMount(path, file: true) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: entry.directory ? "folder.fill" : fileIcon(entry.name)).foregroundStyle(entry.directory ? Color.teal : .secondary)
                                    .font(.system(size: 18)).frame(width: 25)
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Group {
                                    if entry.directory { Text("—").foregroundStyle(.tertiary) }
                                    else if cacheOnly { Text("Local view").foregroundStyle(.secondary) }
                                    else { FileAvailabilityView(components: components + [entry.name], size: entry.size,
                                                roots: roots,
                                                lastTransfer: activity.history?.first?.completed_at, revision: revision) }
                                }.font(.caption).frame(width: 94, alignment: .leading)
                                Text(entry.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").frame(width: 100, alignment: .trailing)
                                    .foregroundStyle(.secondary).font(.caption)
                                Text(entry.directory || entry.size < 0 ? "—" : Self.bytes(entry.size)).frame(width: 78, alignment: .trailing)
                                    .foregroundStyle(.secondary).font(.caption).monospacedDigit()
                            }.padding(.horizontal, 9).frame(height: 35).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(entry.directory ? "Browse \(entry.name)" : "Open \(entry.name) from the mount")
                        Divider()
                    }
                }
            }
        }
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "m4v": return "film"
        case "jpg", "jpeg", "png", "heic", "webp": return "photo"
        case "wav", "mp3", "m4a", "flac": return "waveform"
        case "zip", "gz", "zst", "7z": return "archivebox"
        default: return "doc"
        }
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func navigate(_ path: [String]) {
        guard components != path else { return }
        entries = []; listing = true; listingError = nil; query = ""; components = path
    }

    @MainActor private func loadFolder() async {
        entries = []; listingError = nil; listing = mounted
        guard mounted else { return }
        do {
            let loaded = try await DriveWorkspaceService.list(profile: profile, components: components)
            try Task.checkCancellation()
            entries = loaded
        } catch {
            guard !Task.isCancelled else { return }
            listingError = error.localizedDescription
        }
        listing = false
    }

    private func openInMount(_ path: [String], file: Bool) {
        guard path.allSatisfy(DriveWorkspaceService.validComponent), mounted,
              SyncSetupService.shared.isMounted(profile: profile) else {
            openError = "The mount is unavailable."; return
        }
        let root = URL(fileURLWithPath: profile.localSyncPath, isDirectory: true)
        let url = path.reduce(root) { $0.appendingPathComponent($1) }
        if !file { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
        else if !NSWorkspace.shared.open(url) { openError = "macOS could not open \(url.lastPathComponent) from this mount." }
    }
}

private struct FileAvailabilityView: View {
    let components: [String]
    let size: Int64
    let roots: DriveWorkspaceService.CacheRoots?
    let lastTransfer: String?
    let revision: Int
    @State private var value: DriveWorkspaceService.Availability?
    private struct Sample: Equatable {
        let path: [String]
        let size: Int64
        let roots: DriveWorkspaceService.CacheRoots?
        let lastTransfer: String?
        let revision: Int
    }
    var body: some View {
        Text(value?.rawValue ?? "—")
            .foregroundStyle(value == .cached ? Color.green : value == .pending ? .orange : .secondary)
            .task(id: Sample(path: components, size: size, roots: roots, lastTransfer: lastTransfer, revision: revision)) {
                guard let roots else { value = nil; return }
                let status = await Task.detached(priority: .utility) {
                    DriveWorkspaceService.availability(components: components, size: size, roots: roots)
                }.value
                if !Task.isCancelled { value = status }
            }
    }
}
