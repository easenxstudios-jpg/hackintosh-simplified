import AppKit
import HackintoshCore
import Network
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
            if CommandLine.arguments.contains("--speed"), let interface = WiFiSpeed.testableInterface(facts) {
                facts.wifiSpeed = WiFiSpeed.measure(interface: interface)
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
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshIfOld() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Scan Again") { Task { await model.scan(); await model.testSpeed() } }
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

    @Published var lastChecked: Date?
    @Published var testingSpeed = false
    private var speed: SpeedResult?
    private var started = false
    private var monitor: NWPathMonitor?
    private var pendingNetworkCheck: Task<Void, Never>?

    /// Scans now, then keeps results current while the app is open.
    func start() {
        guard !started else { return }
        started = true
        Task { await scan(); await testSpeed() }

        // A network change makes old results wrong, so it starts a new check after things settle.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor

        // Re-scan every 5 minutes. Speed tests use data, so those run every 30 minutes.
        Task { [weak self] in
            var ticks = 0
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self else { return }
                ticks += 1
                await self.scan()
                if ticks % 6 == 0 { await self.testSpeed() }
            }
        }
    }

    func refreshIfOld() {
        guard started, let lastChecked, Date().timeIntervalSince(lastChecked) > 60 else { return }
        Task { await scan() }
    }

    private func networkChanged() {
        guard facts != nil else { return }
        pendingNetworkCheck?.cancel()
        pendingNetworkCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.speed = nil
            await self.scan()
            await self.testSpeed()
        }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        var result = await Task.detached(priority: .userInitiated) { SystemScanner.scan() }.value
        result.wifiSpeed = speed
        apply(result)
        scanning = false
    }

    func testSpeed() async {
        guard !testingSpeed, let facts, let interface = WiFiSpeed.testableInterface(facts) else { return }
        testingSpeed = true
        let measured = await Task.detached(priority: .utility) { WiFiSpeed.measure(interface: interface) }.value
        testingSpeed = false
        guard let measured, var current = self.facts else { return }
        speed = measured
        current.wifiSpeed = measured
        apply(current)
    }

    private func apply(_ result: SystemFacts) {
        facts = result
        findings = Checks.run(result)
        lastChecked = Date()
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
