import SwiftUI

// Review queue (§F10): a proposal, never auto-executes. Revalidates before Trash.
struct ReviewQueueView: View {
    @Environment(AppState.self) private var app
    @State private var confirming = false

    private var total: Int64 { app.reviewPlanBytes }
    private var planCount: Int { app.reviewPlan.count }
    private var problems: [CleanupResult] { app.cleanupResults.filter { !$0.didMove } }
    private var movedCount: Int { app.cleanupResults.filter(\.didMove).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Cleanup").font(.system(size: 20, weight: .semibold))
                    Text(app.reviewItems.isEmpty ? "Nothing staged. Add files from Browse or Find." : "\(planCount) items · \(SDFormat.bytesString(total)) selected (overlap counted once; estimate, not guaranteed recovery)")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                Spacer()
                if app.cleanupRunning {
                    Button("Cancel") { app.cancelCleanup() }.buttonStyle(.bordered)
                } else {
                    Button("Move to Trash…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(app.reviewItems.isEmpty)
                        .help("Confirm Move to Trash — revalidates each item")
                }
            }
            .padding(SDTheme.Space.md)
            Divider()

            if app.cleanupRunning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Moving to Trash… \(app.cleanupCurrent ?? "")")
                        .font(SDTheme.Font.body)
                    Text("Revalidating each item. You can cancel between items — finished moves stay in Trash, the rest stay queued.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.reviewItems.isEmpty && app.cleanupResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No files staged for cleanup.").font(SDTheme.Font.body)
                    Text("Select → Add to Review → Inspect queue → Confirm Move to Trash").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let summary = app.lastCleanupSummary {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(summary).font(SDTheme.Font.body)
                                Text("Trash still occupies space until you empty it in Finder. SpareDisk never empties your whole Trash.")
                                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button("Show Trash") { app.showTrash() }.buttonStyle(.bordered).controlSize(.small)
                                    Button("Dismiss Report", role: .cancel) {
                                        app.cleanupResults = []
                                        app.lastCleanupSummary = nil
                                    }.buttonStyle(.link).font(SDTheme.Font.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !problems.isEmpty {
                        Section("Needs attention") {
                            ForEach(problems) { r in
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name).font(SDTheme.Font.body)
                                        if let m = r.message {
                                            Text(m).font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    MonospaceBytes(bytes: r.bytes)
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                    if !app.reviewItems.isEmpty {
                        Section("Queued") {
                            ForEach(app.reviewItems) { item in
                                HStack(spacing: 10) {
                                    CategoryDot(category: item.node.category)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.node.name).font(SDTheme.Font.body)
                                        Text(item.node.path).font(SDTheme.Font.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text("\(item.source) · \(item.risk)").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    MonospaceBytes(bytes: item.node.logicalBytes)
                                    Button("Remove") { app.toggleReview(item.node, source: item.source) }
                                        .buttonStyle(.link)
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    } else if movedCount > 0 {
                        Section {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Queue clear — recover anything from the Trash in Finder.")
                                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Move \(planCount) items to Trash?").font(.system(size: 17, weight: .semibold))
                Text("Estimated \(SDFormat.bytesString(total)). Each item is revalidated — changed, shared, or protected items are skipped and reported. Space stays occupied until you empty the Trash.")
                    .font(SDTheme.Font.body).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) {
                        confirming = false
                        app.cleanupTask = Task { await app.runCleanup() }
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 440)
        }
    }
}

struct StatusBarView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Divider()
        HStack(spacing: 12) {
            if app.isScanning, let p = app.scanProgress {
                ProgressView().controlSize(.small)
                Text("Scanning · \(p.itemsFound.formatted()) items found · \(Int(p.elapsed))s elapsed")
                    .font(SDTheme.Font.secondary)
                Button("Cancel") { app.cancelScan() }.buttonStyle(.link).font(SDTheme.Font.secondary)
            } else if app.cleanupRunning {
                ProgressView().controlSize(.small)
                Text("Moving to Trash… \(app.cleanupCurrent ?? "")").font(SDTheme.Font.secondary)
            } else if let s = app.lastCleanupSummary {
                Image(systemName: "trash.fill").foregroundStyle(.secondary)
                Text(s).font(SDTheme.Font.secondary)
            } else if let scan = app.activeScan, app.hasRealData {
                if scan.wasCancelled {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                    Text("Scan cancelled").font(SDTheme.Font.secondary)
                } else if scan.issues.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Scan complete · \(scan.itemCount.formatted()) items · \(SDFormat.bytesString(scan.totalBytes))").font(SDTheme.Font.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Scan finished · \(scan.issues.count) folders couldn't be read").font(SDTheme.Font.secondary)
                }
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(app.hasRealData ? "Ready to scan · choose a location and select Rescan" : "Sample data · choose a folder to analyze").font(SDTheme.Font.secondary)
            }
            Spacer()
            if !app.reviewPlan.isEmpty {
                Button("Review \(app.reviewPlan.count) items · \(SDFormat.bytesString(app.reviewPlanBytes))") {
                    app.selection = .review
                }.buttonStyle(.link).font(SDTheme.Font.secondary)
            } else if !app.isScanning && !app.cleanupRunning {
                Text("Idle").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SDTheme.Space.md).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension View {
    func statusBar() -> some View { self }
}
