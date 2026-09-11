import SwiftUI

/// Short, plain answers to the questions the interface raises: what the
/// numbers mean, why some items cannot be moved, and what the Trash frees.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let sections: [(heading: String, body: String)]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [HelpTopic] = [
        HelpTopic(id: "sizes", title: "Sizes", symbol: "ruler", sections: [
            ("Logical size", "What a file would hold if it were fully downloaded and uncompressed. Finder shows this number in Get Info as the first figure."),
            ("Size on disk", "The space a file actually occupies right now. Cloud files that are not downloaded, sparse disk images and cloned copies take far less than their logical size. SpareDisk shows an on-disk hint whenever a file occupies less than half its size, and you can switch every view to on-disk sizes from the View menu."),
            ("Why totals differ", "The volume bar counts everything on the disk. A location counts only what is inside it. System files, other users, snapshots and files you have not added as locations make up the rest."),
        ]),
        HelpTopic(id: "locations", title: "Locations", symbol: "folder.badge.person.crop", sections: [
            ("What a location is", "A folder you granted SpareDisk access to. Your home folder covers Desktop, Documents, Downloads and Library in one step. Applications and external drives are separate locations."),
            ("Why macOS asks", "macOS confirms once before an app reads a protected folder such as Desktop or Downloads. SpareDisk never asks for Full Disk Access and cannot read outside the folders you add."),
            ("Forgetting a location", "Forget Location in the sidebar removes the saved permission and the saved scans for that folder. Nothing on disk changes."),
        ]),
        HelpTopic(id: "review", title: "Review and the Trash", symbol: "trash", sections: [
            ("Review first", "Add to Review stages items in a queue. Nothing moves until you confirm. Move to Trash in the inspector does the same for one item with a confirmation."),
            ("Checked again", "Before an item moves, SpareDisk checks that it is still the same file: same identity, size and date, still inside the location. Anything that changed is skipped and listed."),
            ("What the Trash frees", "Moving to the Trash frees nothing by itself. Space returns when you empty the Trash in Finder. Cloned files and files with several hard links may free less than their size."),
            ("Items SpareDisk cannot move", "Apps and files owned by the system or another user need an administrator password, which only Finder can ask for. Cloud files that are not downloaded are managed in Finder as well. SpareDisk says so and offers Finder."),
        ]),
        HelpTopic(id: "duplicates", title: "Duplicates", symbol: "doc.on.doc", sections: [
            ("How they are found", "Among the largest files of each scanned location, files of the same size are sampled, hashed, then compared byte by byte. Only identical contents are grouped."),
            ("Keeping one copy", "Each group keeps one copy. Stage the Rest for Review stages the others; the kept copy is never moved by group actions."),
            ("Identical is not the same", "Two identical files can mean different things to different apps. Check where each copy lives before removing it."),
        ]),
        HelpTopic(id: "related", title: "Related data for apps", symbol: "app.badge", sections: [
            ("What Find looks for", "Containers, caches, preferences, saved state, logs and Application Support that match the app's bundle identifier under your Library. Matches by name only are marked as weaker evidence."),
            ("What it does not do", "SpareDisk does not uninstall apps or stop background helpers. Items go through the same review and Trash flow as everything else."),
        ]),
        HelpTopic(id: "privacy", title: "Privacy", symbol: "lock", sections: [
            ("Everything stays on this Mac", "Scanning reads names, sizes and dates. Duplicate comparison reads file contents to hash them. Nothing is uploaded and there is no account."),
            ("What is stored", "The last two scans per location and your saved folder permissions live in the app's own container. Forget Location removes them."),
        ]),
    ]
}

struct HelpView: View {
    @State private var selected: HelpTopic = HelpTopic.all[0]

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.all, selection: $selected) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: SDTheme.Space.lg) {
                    ForEach(Array(selected.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.heading).font(SDTheme.Font.section)
                            Text(section.body).font(SDTheme.Font.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(SDTheme.Space.lg)
            }
            .navigationTitle(selected.title)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}
