import HackintoshCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case guide
    case category(Area)
    case backups
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .overview
    @State private var activeFix: Fix?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "checklist").tag(SidebarItem.overview)
                Label("Problem Guide", systemImage: "questionmark.circle").tag(SidebarItem.guide)
                Section("Your Mac") {
                    ForEach(Area.allCases) { category in
                        if model.worstStatus(in: category) != nil {
                            HStack {
                                Label(category.rawValue, systemImage: category.symbol)
                                Spacer()
                                StatusIcon(status: model.worstStatus(in: category))
                            }
                            .tag(SidebarItem.category(category))
                        }
                    }
                }
                Section("Safety") {
                    Label("Backups", systemImage: "clock.arrow.circlepath").tag(SidebarItem.backups)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            Group {
                if model.facts == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking your Mac…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch selection ?? .overview {
                    case .overview: OverviewView(activeFix: $activeFix)
                    case .guide: GuideView()
                    case .category(let category): FindingList(title: category.rawValue, findings: model.findings.filter { $0.category == category }, activeFix: $activeFix)
                    case .backups: BackupsView()
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button { Task { await model.testSpeed() } } label: { Label("Test Wi-Fi Speed", systemImage: "speedometer") }
                        .help("Measure Wi-Fi now. This uses some data.")
                        .disabled(model.testingSpeed || model.facts.flatMap(WiFiSpeed.testableInterface) == nil)
                    Button { model.copyReport() } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                        .help("Copy a report with addresses and names removed")
                        .disabled(model.facts == nil)
                    Button { Task { await model.scan(); await model.testSpeed() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                        .disabled(model.scanning)
                }
            }
        }
        .sheet(item: $activeFix) { fix in
            FixSheet(fix: fix).environmentObject(model)
        }
    }
}

struct StatusIcon: View {
    let status: Status?

    var body: some View {
        switch status {
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Problem")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityLabel("Couldn't check")
        case .info: Image(systemName: "info.circle").foregroundStyle(.blue).accessibilityLabel("Good to know")
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Working")
        case nil: EmptyView()
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var activeFix: Fix?

    private var attention: [Finding] {
        model.findings.filter { $0.status == .problem || $0.status == .warning }.sorted { $0.status < $1.status }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(attention.isEmpty ? "Everything checked looks good" : "\(attention.count) \(attention.count == 1 ? "thing needs" : "things need") attention")
                        .font(.title2.weight(.semibold))
                    if let facts = model.facts {
                        Text("macOS \(facts.osVersion) (\(facts.osBuild)) · \(facts.model) · \(facts.cpu)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let checked = model.lastChecked {
                            Text(model.testingSpeed ? "Checked at \(checked.formatted(date: .omitted, time: .shortened)). Testing Wi-Fi speed…" : "Checked at \(checked.formatted(date: .omitted, time: .shortened)). Updates by itself while this app is open.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if model.restartNeeded {
                    Label("Restart your Mac to finish the changes you applied, then scan again.", systemImage: "arrow.triangle.2.circlepath")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let facts = model.facts {
                    let safe = FixPlanner.safeFixes(findings: model.findings, facts: facts)
                    if !safe.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(safe.count == 1 ? "1 problem can be fixed for you" : "\(safe.count) problems can be fixed for you")
                                .font(.headline)
                            Text("You'll see every change first. Your boot files are backed up before they change.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(safe.count == 1 ? "Fix 1 Problem" : "Fix \(safe.count) Problems") {
                                activeFix = FixPlanner.combined(safe)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if facts.isOpenCore, facts.config == nil, facts.efiMountPoint == nil, let open = FixCatalog.fix(id: "mount-efi", facts: facts) {
                        HStack(spacing: 12) {
                            Text("Open your boot partition to check your OpenCore settings too.")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Check OpenCore Settings") { activeFix = open }
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                ForEach(attention) { finding in
                    FindingCard(finding: finding, showCategory: true, activeFix: $activeFix)
                }
                let working = model.findings.filter { $0.status == .ok }
                if !working.isEmpty {
                    Text("Working").font(.headline).padding(.top, 8)
                    ForEach(working) { finding in
                        HStack(alignment: .firstTextBaseline) {
                            StatusIcon(status: .ok)
                            Text(finding.title)
                            Text(finding.category.rawValue).foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }
}

struct FindingList: View {
    let title: String
    let findings: [Finding]
    @Binding var activeFix: Fix?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(findings.sorted { $0.status < $1.status }) { finding in
                    FindingCard(finding: finding, showCategory: false, activeFix: $activeFix)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}

struct FindingCard: View {
    @EnvironmentObject private var model: AppModel
    let finding: Finding
    let showCategory: Bool
    @Binding var activeFix: Fix?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusIcon(status: finding.status)
                Text(finding.title).font(.headline)
                Spacer()
                if showCategory {
                    Text(finding.category.rawValue).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(finding.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let facts = model.facts {
                let fixes = finding.fixIDs.compactMap { FixCatalog.fix(id: $0, facts: facts) }
                if !fixes.isEmpty {
                    HStack {
                        ForEach(fixes) { fix in
                            if fix.id == fixes.first?.id, finding.status != .info, finding.status != .ok {
                                Button(buttonTitle(fix)) { activeFix = fix }.buttonStyle(.borderedProminent)
                            } else {
                                Button(buttonTitle(fix)) { activeFix = fix }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func buttonTitle(_ fix: Fix) -> String {
        if case .unavailable = fix.kind { return "Why There's No Fix" }
        return fix.title
    }
}

struct BackupsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var backups: [BackupEntry] = []
    @State private var message: String?
    @State private var pending: BackupEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("A full copy of your EFI is saved here before each boot change. These copies hold your serial numbers, so don't share them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If your Mac won't start, this app can't run. Keep a bootable USB with a working OpenCore so you can put a backup back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if backups.isEmpty {
                    Text("No backups yet.").padding(.top, 8)
                }
                ForEach(backups) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(entry.note).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { pending = entry }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Backups")
        .onAppear { backups = model.manager.backups() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Restore") {
                if let entry = pending { restore(entry) }
            }
        } message: {
            Text("Your current config.plist and the kexts in this backup are replaced. You'll need to restart afterward.")
        }
    }

    private func restore(_ entry: BackupEntry) {
        let manager = model.manager
        Task {
            do {
                try await Task.detached { try manager.restore(entry) }.value
                model.restartNeeded = true
                message = "Restored. Restart your Mac to use it."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct GuideView: View {
    @State private var text = ""

    var body: some View {
        let results = ProblemGuide.search(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Search for what you're seeing, or paste the last line from the startup text.")
                    .foregroundStyle(.secondary)
                TextField("For example: no sound, Waiting for Root Device, won't wake", text: $text)
                    .textFieldStyle(.roundedBorder)
                if results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing matches that yet.").font(.headline)
                        Text("Try fewer words. For anything else, Dortania's troubleshooting guide covers many more errors.").foregroundStyle(.secondary)
                        Link("Open Dortania's troubleshooting guide", destination: URL(string: "https://dortania.github.io/OpenCore-Install-Guide/troubleshooting/troubleshooting.html")!)
                    }
                }
                ForEach(ProblemGuide.topics, id: \.self) { topic in
                    let items = results.filter { $0.topic == topic }
                    if !items.isEmpty {
                        Text(topic).font(.title3.weight(.semibold)).padding(.top, 6)
                        ForEach(items) { GuideCard(entry: $0, expanded: !text.isEmpty) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Problem Guide")
    }
}

struct GuideCard: View {
    let entry: GuideEntry
    let expanded: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { open || expanded }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.cause).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1).").monospacedDigit()
                        Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                if let url = URL(string: entry.link) {
                    Link("Read more", destination: url)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text(entry.problem).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
