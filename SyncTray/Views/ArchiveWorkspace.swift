import SwiftUI
import AppKit

struct ArchiveWorkspace: View {
    @EnvironmentObject private var manager: SyncManager
    @AppStorage("archiveDriveVerification") private var savedReceipt = Data()
    @State private var checkRequest: UUID?
    @State private var checking = false
    @State private var checkError: String?
    @State private var snapshot: ArchiveMonitor.Snapshot?
    @State private var query = ""
    @State private var attentionOnly = false
    @State private var revision = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceBanner(title: "Project backups", detail: receipt?.passed == false ? "Drive verification needs attention" : snapshot?.title ?? "Reading archive evidence…",
                                icon: "archivebox", archive: true)
                if let data = snapshot {
                    checks(data)
                    if let plan = data.drivePlan {
                        HStack(spacing: 12) {
                            Image(systemName: receipt?.passed == true ? "checkmark.shield.fill" : "checkmark.shield")
                                .font(.title2).foregroundStyle(receipt?.passed == true ? Color.green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(checking ? "Checking Drive copies…" : receipt.map { "\($0.matched) of \($0.total) Drive checksums match" } ?? "Verify Drive copies")
                                    .font(.headline)
                                if let receipt {
                                    Text("Checked \(receipt.checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Compare \(plan.expected.count) saved archive checksums with Google Drive.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if checking { ProgressView().controlSize(.small) }
                            Button("Verify on Drive") { checkRequest = UUID() }.disabled(checking)
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                        if let checkError { Text(checkError).foregroundStyle(.orange).textSelection(.enabled) }
                        ForEach(receipt?.problems ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    Divider()
                    if let run = data.run {
                        HStack {
                            Text(run.scope).font(.headline)
                            Spacer()
                            Text(run.finished).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            WorkspaceMetric(title: "Newly verified", value: "\(run.archived)", icon: "checkmark.seal", color: .teal)
                            WorkspaceMetric(title: "Unchanged", value: "\(run.unchanged)", icon: "equal.circle", color: .indigo)
                            WorkspaceMetric(title: "Failed", value: "\(run.failed)", icon: run.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                            color: run.failed == 0 ? .green : .orange)
                        }
                        ForEach(run.warnings, id: \.self) { text in Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    if let date = data.lastFull {
                        Text("Last full run \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let issue = data.issue { WorkspaceMessage(icon: "doc.text.magnifyingglass", title: "Report needs a look", detail: issue) }
                    HStack {
                        Button("Open report") { NSWorkspace.shared.open(ArchiveMonitor.base.appendingPathComponent("STATUS.txt")) }
                        Button("Show logs") { NSWorkspace.shared.open(ArchiveMonitor.base.appendingPathComponent("logs")) }
                        Spacer()
                        Button { revision += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    Divider()
                    HStack {
                        Text("Archive history").font(.title3.weight(.semibold))
                        Spacer()
                        Toggle("Needs attention", isOn: $attentionOnly).toggleStyle(.checkbox)
                        TextField("Find a project", text: $query).textFieldStyle(.roundedBorder).frame(width: 164)
                    }
                    let rows = data.projects.filter {
                        (!attentionOnly || $0.failure != nil) && (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query))
                    }
                    if rows.isEmpty {
                        Text(data.issue != nil && data.projects.isEmpty ? "Archive history unavailable" : "No matching projects")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                Image(systemName: row.failure == nil ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(row.failure == nil ? Color.green : .orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.name).fontWeight(.medium).lineLimit(1)
                                    Text(row.failure ?? row.parent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Text(row.verifiedAt.map { "Verified " + String($0.prefix(10)) } ?? "No verified archive")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8).help(row.id)
                            Divider()
                        }
                    }
                } else { ProgressView().controlSize(.small) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }

        .task(id: checkRequest) {
            guard checkRequest != nil, let plan = snapshot?.drivePlan else { return }
            checking = true; checkError = nil; savedReceipt = Data()
            defer { checking = false }
            do {
                let result = try await ArchiveDriveCheck.verify(plan, profiles: manager.profileStore.profiles)
                try Task.checkCancellation()
                savedReceipt = try JSONEncoder().encode(result)
            } catch {
                if !Task.isCancelled { checkError = error.localizedDescription }
            }
        }
        .task(id: revision) {
            while !Task.isCancelled {
                let data = await Task.detached(priority: .utility) { ArchiveMonitor.sample() }.value
                guard !Task.isCancelled else { return }
                snapshot = data
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }

    private var receipt: ArchiveDriveCheck.Receipt? {
        guard let result = try? JSONDecoder().decode(ArchiveDriveCheck.Receipt.self, from: savedReceipt),
              result.signature == snapshot?.drivePlan?.signature else { return nil }
        return result
    }

    private func checks(_ data: ArchiveMonitor.Snapshot) -> some View {
        let schedule = data.running == true ? "Checking now" :
            (data.scheduler == true ? "Scheduled" : data.scheduler == false ? "Stopped" : "Unknown")
        let verified = data.verifiedCount > 0 || data.retryCount != nil ? String(data.verifiedCount) : "Unknown"
        return HStack {
            WorkspaceMetric(title: "Archive worker", value: schedule, icon: data.scheduler == true ? "checkmark.circle.fill" : "clock",
                            color: data.scheduler == true ? .green : .secondary)
            WorkspaceMetric(title: "Projects with archives", value: verified, icon: "archivebox", color: .indigo)
            WorkspaceMetric(title: "Pending retries", value: data.retryCount.map(String.init) ?? "Unknown",
                            icon: data.retryCount == 0 ? "checkmark.circle.fill" : "clock.arrow.circlepath",
                            color: data.retryCount == 0 ? .green : (data.retryCount == nil ? .secondary : .orange))
        }
    }
}
