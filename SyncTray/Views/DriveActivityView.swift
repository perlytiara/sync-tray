import SwiftUI

struct DriveActivityView: View {
    let activity: DriveWorkspaceService.Activity
    let cacheOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Live transfers").font(.title3.weight(.semibold))
                Spacer()
                if let date = activity.sampled { Text("Checked \(date, style: .time)").font(.caption).foregroundStyle(.secondary) }
            }
            if activity.sampled == nil {
                ProgressView().controlSize(.small)
            } else if activity.stats == nil || activity.volume == nil {
                WorkspaceMessage(icon: "antenna.radiowaves.left.and.right.slash", title: "Activity unavailable",
                                 detail: "SyncTray could not read the mount’s current transfer counters.")
            } else if activity.active.isEmpty {
                WorkspaceMessage(icon: cacheOnly ? "internaldrive" : "waveform.path",
                                 title: cacheOnly ? "Working from the local cache" :
                                    (activity.status == "Idle" ? "No files transferring" : activity.status),
                                 detail: cacheOnly ? "Recent activity below belongs to this mount session." :
                                    "Files opened from Drive appear here while bytes are moving.")
            } else {
                ForEach(Array(activity.active.enumerated()), id: \.offset) { _, file in
                    let direction = DriveWorkspaceService.direction(source: file.srcFs, destination: file.dstFs, volume: activity.volume?.fs)
                    HStack {
                        Image(systemName: direction == "Upload" ? "arrow.up.circle.fill" : direction == "Download" ? "arrow.down.circle.fill" : "arrow.left.arrow.right.circle.fill").foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).lineLimit(2).textSelection(.enabled)
                            Text([direction ?? "Transferring", file.formattedProgress].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let size = file.size, size > 0, let bytes = file.bytes {
                                ProgressView(value: min(1, max(0, Double(bytes) / Double(size)))).tint(.teal)
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }

            if let queue = activity.queue, !queue.isEmpty {
                Divider()
                Text("Upload queue").font(.headline)
                ForEach(Array(queue.enumerated()), id: \.offset) { _, file in
                    Label("\(file.name) · \(file.uploading == true ? "Uploading" : "Waiting")", systemImage: "arrow.up.circle")
                        .lineLimit(2).textSelection(.enabled)
                }
            } else if activity.sampled != nil && activity.queue == nil {
                Text("Upload queue details unavailable").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Recent transfers").font(.title3.weight(.semibold))
            if let history = activity.history {
                if history.isEmpty {
                    WorkspaceMessage(icon: "clock", title: "No transfers recorded yet", detail: "History starts when the mount starts.")
                }
                ForEach(Array(history.prefix(50).enumerated()), id: \.offset) { _, receipt in
                    let direction = DriveWorkspaceService.direction(source: receipt.srcFs, destination: receipt.dstFs, volume: activity.volume?.fs)
                    HStack(spacing: 10) {
                        Image(systemName: receipt.error != nil ? "exclamationmark.circle.fill" : direction == "Upload" ? "arrow.up.right" : direction == "Download" ? "arrow.down.left" : "arrow.left.arrow.right")
                            .foregroundStyle(receipt.error != nil ? Color.orange : .teal).frame(width: 23)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receipt.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Text(receipt.error ?? (direction == "Upload" ? "Uploaded" : direction == "Download" ? "Downloaded" : "Transferred"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if let bytes = receipt.bytes { Text(DriveWorkspace.bytes(bytes)).font(.caption).foregroundStyle(.secondary) }
                        if let date = receipt.completed_at.flatMap(DriveWorkspaceService.timestamp) {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3)
                    Divider()
                }
            } else if activity.sampled != nil {
                WorkspaceMessage(icon: "clock.badge.questionmark", title: "History unavailable", detail: "The mount did not return its completed transfers.")
            }
        }
    }
}
