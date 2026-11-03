import HackintoshCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
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
                    case .category(let category): FindingList(title: category.rawValue, findings: model.findings.filter { $0.category == category }, activeFix: $activeFix)
                    case .backups: BackupsView()
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button { model.copyReport() } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                        .help("Copy a report with addresses and names removed")
                        .disabled(model.facts == nil)
                    Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
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
                    }
                }
                if model.restartNeeded {
                    Label("Restart your Mac to finish the changes you applied, then scan again.", systemImage: "arrow.triangle.2.circlepath")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                            Button(buttonTitle(fix)) { activeFix = fix }
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
