import AppKit
import HackintoshCore
import SwiftUI

struct FixSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let fix: Fix

    private enum Stage {
        case ready
        case working(String)
        case review(PreparedFix)
        case done(ApplyResult)
    }

    @State private var stage = Stage.ready
    @State private var parameter = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fix.title).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !fix.summary.isEmpty {
                        Text(fix.summary).fixedSize(horizontal: false, vertical: true)
                    }
                    content
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 540, height: 430)
        .onAppear { parameter = fix.parameter?.defaultValue ?? "" }
    }

    @ViewBuilder private var content: some View {
        switch fix.kind {
        case .unavailable(let reason):
            Text(reason).fixedSize(horizontal: false, vertical: true)
        case .guided(let steps, let link):
            Text("This one needs you to do it by hand:").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1).").monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let link, let url = URL(string: link) {
                Link(link, destination: url)
            }
        case .automatic:
            automaticContent
        }
    }

    @ViewBuilder private var automaticContent: some View {
        switch stage {
        case .ready:
            if fix.risk != .low {
                Label("Risk: \(fix.risk.rawValue). Keep a bootable USB with a working OpenCore ready.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let spec = fix.parameter {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(spec.label, text: $parameter).textFieldStyle(.roundedBorder)
                    Text(spec.help).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Next, you'll see exactly what would change. Nothing is written until you approve it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .working(let text):
            HStack { ProgressView().controlSize(.small); Text(text) }
        case .review(let prepared):
            if prepared.changes.isEmpty {
                Text("This is already set, so there's nothing to change.")
            } else {
                Text("What will change").font(.headline)
                ForEach(prepared.changes, id: \.self) { change in
                    Text("• \(change)").fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                ForEach(prepared.kexts) { kext in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(kext.spec.bundle) from \(kext.source)")
                        if let hash = kext.sha256 {
                            Text("SHA-256 \(hash)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if !prepared.kexts.isEmpty {
                    Text("Kexts run inside the macOS kernel with full control of your Mac. They come from the source above, and this app can't check that a release is safe or compatible.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if prepared.plan.touchesEFI {
                    Text("Your whole EFI is backed up first. macOS will ask for your password.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("macOS will ask for your password.").foregroundStyle(.secondary)
                }
            }
        case .done(let result):
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            ForEach(result.changes, id: \.self) { Text("• \($0)").fixedSize(horizontal: false, vertical: true) }
            if let backup = result.backup {
                Text("Backup saved as \(backup.lastPathComponent).").foregroundStyle(.secondary)
            }
            if fix.needsRestart {
                Text("Restart your Mac for this to take effect, then scan again. This app never restarts your Mac by itself.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch fix.kind {
        case .automatic(let build):
            switch stage {
            case .ready:
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review Changes…") { review(build) }.keyboardShortcut(.defaultAction)
            case .working:
                Button("Cancel", role: .cancel) { dismiss() }.disabled(true)
            case .review(let prepared):
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if prepared.changes.isEmpty {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Apply") { apply(prepared) }.keyboardShortcut(.defaultAction)
                }
            case .done:
                Button("Done") {
                    dismiss()
                    Task { await model.scan() }
                }
                .keyboardShortcut(.defaultAction)
            }
        default:
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func review(_ build: @escaping @Sendable (String?) throws -> FixPlan) {
        errorText = nil
        stage = .working("Getting everything ready…")
        let value = fix.parameter == nil ? nil : parameter
        let manager = model.manager
        Task {
            do {
                let plan = try build(value)
                let prepared = try await manager.prepare(plan)
                stage = .review(prepared)
            } catch {
                errorText = error.localizedDescription
                stage = .ready
            }
        }
    }

    private func apply(_ prepared: PreparedFix) {
        errorText = nil
        stage = .working("Applying…")
        let manager = model.manager
        let title = fix.title
        Task {
            do {
                let result = try await Task.detached { try manager.apply(prepared, fixTitle: title) }.value
                if fix.needsRestart { model.restartNeeded = true }
                stage = .done(result)
            } catch {
                errorText = error.localizedDescription
                stage = .review(prepared)
            }
        }
    }
}
