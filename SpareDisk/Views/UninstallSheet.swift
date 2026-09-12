import SwiftUI

/// What an Uninstall will stage: the app, its identifier-matched data
/// checked, weaker matches unchecked, and a plain note about what a
/// sandboxed app cannot reach. Nothing moves until Review confirms.
struct UninstallSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let plan: UninstallPlan
    @State private var chosen: Set<String> = []

    private var total: Int64 {
        ([plan.app] + plan.strong + plan.weak).filter { chosen.contains($0.id) }.reduce(0) { $0 + app.bytes($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FileTypeIcon(node: plan.app, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \(plan.app.name.replacingOccurrences(of: ".app", with: ""))").font(.system(size: 17, weight: .semibold))
                    Text("The app and the items checked below go to Review. Nothing moves until you confirm there.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            List {
                Section("Application") { row(plan.app, detail: app.displayPath(plan.app)) }
                if !plan.strong.isEmpty {
                    Section("Data matched by identifier") {
                        ForEach(plan.strong) { n in row(n, detail: app.relatedEvidence["related#\(plan.app.id)"]?[n.path] ?? app.displayPath(n)) }
                    }
                }
                if !plan.weak.isEmpty {
                    Section("Possible matches by name") {
                        ForEach(plan.weak) { n in row(n, detail: app.relatedEvidence["related#\(plan.app.id)"]?[n.path] ?? app.displayPath(n)) }
                    }
                }
                if plan.strong.isEmpty && plan.weak.isEmpty {
                    Text("Nothing found under your Library for this app.").font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            Text("Login items, launch agents in /Library and system extensions cannot be read by a sandboxed app. Check System Settings › General › Login Items after the app is gone.")
                .font(SDTheme.Font.secondary).foregroundStyle(.tertiary)
            HStack {
                Text("\(chosen.count) \(chosen.count == 1 ? "item" : "items"), \(SDFormat.bytesString(total))")
                    .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Review") { app.stageUninstall(plan, chosen: chosen) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { chosen = Set(([plan.app] + plan.strong).map(\.id)) }
    }

    private func row(_ n: ScanNode, detail: String) -> some View {
        Toggle(isOn: Binding(get: { chosen.contains(n.id) }, set: { on in if on { chosen.insert(n.id) } else { chosen.remove(n.id) } })) {
            HStack(spacing: 8) {
                FileTypeIcon(node: n, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.name).font(SDTheme.Font.body).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                MonospaceBytes(bytes: app.bytes(n))
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!app.canReview(n))
    }
}
