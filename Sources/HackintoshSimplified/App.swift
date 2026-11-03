import AppKit
import HackintoshCore
import SwiftUI

@main
struct HackintoshSimplifiedApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Started from Terminal with --scan, it prints the read-only report and quits.
        if CommandLine.arguments.contains("--scan") {
            var facts = SystemScanner.scan()
            if let flag = CommandLine.arguments.firstIndex(of: "--efi"), CommandLine.arguments.count > flag + 1 {
                let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                facts.efiMountPoint = folder.path
                facts.config = try? OpenCoreConfig(contentsOf: EFIPaths(mountPoint: folder).config)
            }
            print(SystemScanner.report(facts: facts, findings: Checks.run(facts)))
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Hackintosh Simplified") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .task { if model.facts == nil { await model.scan() } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Scan Again") { Task { await model.scan() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var facts: SystemFacts?
    @Published var findings: [Finding] = []
    @Published var scanning = false
    @Published var restartNeeded = false

    func scan() async {
        scanning = true
        let result = await Task.detached(priority: .userInitiated) { () -> (SystemFacts, [Finding]) in
            let facts = SystemScanner.scan()
            return (facts, Checks.run(facts))
        }.value
        facts = result.0
        findings = result.1
        scanning = false
    }

    var manager: EFIManager {
        EFIManager(paths: facts?.efiMountPoint.map { EFIPaths(mountPoint: URL(fileURLWithPath: $0)) })
    }

    func worstStatus(in category: Area) -> Status? {
        findings.filter { $0.category == category }.map(\.status).min()
    }

    func copyReport() {
        guard let facts else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SystemScanner.report(facts: facts, findings: findings), forType: .string)
    }
}
