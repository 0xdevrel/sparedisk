import SwiftUI

/// What changed in a location since its previous scan.
struct ChangesView: View {
    @Environment(\.dismiss) private var dismiss
    let locationName: String
    let diff: ScanDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes in \(locationName)").font(SDTheme.Font.section)
                Text("Since \(diff.previousFinished.formatted(date: .abbreviated, time: .shortened)): \(signed(diff.bytesDelta)), \(diff.itemsDelta >= 0 ? "+" : "")\(diff.itemsDelta.formatted()) items")
                    .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                if diff.hasUnreadable {
                    Text("Items this scan could not read are left out of the totals.")
                        .font(SDTheme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            if diff.changes.isEmpty {
                Text("No top-level folder or file changed size.").font(SDTheme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(diff.changes) { c in
                    HStack(spacing: 10) {
                        Text(c.kind).font(SDTheme.Font.secondary).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                        Text(c.name).font(SDTheme.Font.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if let b = c.before, let a = c.after {
                            Text("\(SDFormat.bytesString(b)) to \(SDFormat.bytesString(a))")
                                .font(SDTheme.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(signed(c.delta))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(c.delta > 0 ? .primary : .secondary)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .frame(height: 30)
                }
                .listStyle(.inset)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    private func signed(_ v: Int64) -> String {
        (v >= 0 ? "+" : "−") + SDFormat.bytesString(abs(v))
    }
}
