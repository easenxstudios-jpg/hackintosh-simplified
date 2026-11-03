import Foundation
import XCTest
@testable import HackintoshCore

/// Runs the script with /bin/sh as this user, so tests never ask for a password.
struct LocalRunner: PrivilegedRunner {
    func run(script: String) throws -> String {
        let result = Shell.run("/bin/sh", ["-c", script])
        guard result.succeeded else { throw FixError(result.output) }
        return result.output
    }
}

struct FailingRunner: PrivilegedRunner {
    func run(script: String) throws -> String { throw FixError("cancelled") }
}

final class ParserTests: XCTestCase {
    func testPCI() {
        let text = """
        +-o GFX0@0  <class IOPCIDevice, id 0x1>
              "class-code" = <00000300>
              "device-id" = <592d0000>
              "vendor-id" = <de100000>
        +-o RP05@1  <class IOPCIDevice, id 0x2>
              "vendor-id" = <ec100000>
              "class-code" = <00800200>
              "device-id" = <52c80000>
        """
        let devices = SystemScanner.parsePCI(text)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0], PCIDevice(name: "GFX0@0", vendor: 0x10de, device: 0x2d59, classCode: 0x0300))
        XCTAssertEqual(devices[1].idString, "10ec:c852")
        XCTAssertEqual(devices[1].classCode, 0x0280)
    }

    func testKexts() {
        let text = "    1    0  0xffffff7f  0x1000  0x1000  as.vit9696.Lilu (1.7.3) ABCD-1234 <8 6 5>\n"
        XCTAssertEqual(SystemScanner.parseKexts(text)["as.vit9696.Lilu"], "1.7.3")
    }

    func testClockAndLink() {
        XCTAssertEqual(SystemScanner.parseClockOffset("+0.25 +/- 0.01 time.apple.com 17.0.0.1\n"), 0.25)
        XCTAssertNil(SystemScanner.parseClockOffset("sntp: Exchange failed\n"))
        XCTAssertEqual(SystemScanner.parseLinkSpeed("5 Gb/s"), 5000)
        XCTAssertEqual(SystemScanner.parseLinkSpeed("1.5 Mb/s"), 1.5)
    }

    func testInterfaceInactiveIsNotActive() {
        let off = SystemScanner.parseInterface(port: "Wi-Fi", device: "en1", ifconfig: "en1: flags\n\tstatus: inactive\n")
        XCTAssertFalse(off.active)
        let on = SystemScanner.parseInterface(port: "Ethernet", device: "en0", ifconfig: "en0: flags\n\tinet 10.0.0.2 netmask x\n\tmedia: autoselect (100baseTX)\n\tstatus: active\n")
        XCTAssertTrue(on.active)
        XCTAssertEqual(on.ipv4, "10.0.0.2")
    }

    func testBootPathGUID() {
        let path = "PciRoot(0x0)/Pci(0x14,0x0)/USB(0x12,0x0)/HD(1,GPT,12345678-0781-4523-B692-F159169EBA0F,0x28,0x64000)/EFI\\OC\\OpenCore.efi"
        XCTAssertEqual(SystemScanner.partitionGUID(bootPath: path), "12345678-0781-4523-B692-F159169EBA0F")
        XCTAssertNil(SystemScanner.partitionGUID(bootPath: "no guid"))
    }

    func testRedactRemovesAddresses() {
        XCTAssertEqual(SystemScanner.redact("mac aa:bb:cc:dd:ee:ff and AA-BB-CC-DD-EE-FF"), "mac <address> and <address>")
    }

    func testAssetChoice() {
        XCTAssertEqual(KextFetcher.chooseAsset(names: ["Lilu-1.7.3-DEBUG.zip", "Lilu-1.7.3-RELEASE.zip"]), "Lilu-1.7.3-RELEASE.zip")
        XCTAssertEqual(KextFetcher.chooseAsset(names: ["AirPort_RTW89-0.5.0-tools.zip", "AirPort_RTW89-0.5.0.zip"]), "AirPort_RTW89-0.5.0.zip")
        XCTAssertNil(KextFetcher.chooseAsset(names: ["x-DEBUG.zip", "source.tar.gz"]))
    }

    func testTimeZoneAlias() {
        XCTAssertEqual(FixCatalog.normalizedTimeZone("Asia/Kolkata"), "Asia/Calcutta")
        XCTAssertEqual(FixCatalog.normalizedTimeZone("Europe/London"), "Europe/London")
    }
}

final class CheckTests: XCTestCase {
    private func base() -> SystemFacts {
        var facts = SystemFacts()
        facts.osVersion = "26.7.2"
        facts.osBuild = "25G332"
        facts.openCoreVersion = "1.0.0"
        return facts
    }

    private func find(_ id: String, _ facts: SystemFacts) -> Finding? {
        Checks.run(facts).first { $0.id == id }
    }

    func testEveryFindingFixExistsInCatalog() {
        var scenarios: [SystemFacts] = []
        var a = base(); a.efiDevice = "disk0s1"; scenarios.append(a)
        var b = base(); b.pci = [PCIDevice(name: "w", vendor: 0x14c3, device: 1, classCode: 0x0280), PCIDevice(name: "e", vendor: 0x10ec, device: 0x8125, classCode: 0x0200)]; scenarios.append(b)
        var c = base(); c.pci = [PCIDevice(name: "w", vendor: 0x8086, device: 1, classCode: 0x0280), PCIDevice(name: "e", vendor: 0x8086, device: 0x15f3, classCode: 0x0200)]
        c.usb = [USBDevice(name: "Bluetooth", vendorName: "Intel", vendor: 0x8087, product: 1, megabits: 12)]; c.hibernateMode = 3; c.hasBattery = true; scenarios.append(c)
        var d = base(); d.gpus = [GPU(name: "NVIDIA", hasMetal: false), GPU(name: "AMD", hasMetal: false)]; d.clockOffsetSeconds = 3600; scenarios.append(d)
        for facts in scenarios {
            for finding in Checks.run(facts) {
                for id in finding.fixIDs {
                    XCTAssertNotNil(FixCatalog.fix(id: id, facts: facts), "\(finding.id) points to missing fix \(id)")
                }
            }
        }
    }

    func testTahoeWithoutSoundNeedsSimpleHDA() {
        var facts = base()
        facts.pci = [PCIDevice(name: "HDEF", vendor: 0x8086, device: 1, classCode: 0x0403)]
        XCTAssertEqual(find("sound-none", facts)?.fixIDs.first, "sound-simplehda")
        facts.osVersion = "15.0"
        XCTAssertFalse(find("sound-none", facts)?.fixIDs.contains("sound-simplehda") ?? true)
    }

    func testPatchedBluetoothOnlyOnMatchingBuildAndChip() {
        var facts = base()
        facts.usb = [USBDevice(name: "Bluetooth Radio", vendorName: "Realtek", vendor: 0x13d3, product: 0x3612, megabits: 12)]
        XCTAssertEqual(find("bt-off", facts)?.fixIDs, ["bt-realtek-patched"])
        facts.osBuild = "25H1"
        XCTAssertEqual(find("bt-off", facts)?.fixIDs, ["bt-realtek"])
    }

    func testUnknownBluetoothMakerGetsNoGuessedDriver() {
        var facts = base()
        facts.usb = [USBDevice(name: "Bluetooth", vendorName: "MediaTek", vendor: 0x0e8d, product: 1, megabits: 12)]
        XCTAssertEqual(find("bt-off", facts)?.fixIDs, ["bt-unsupported"])
        facts.usb[0] = USBDevice(name: "Bluetooth", vendorName: "Broadcom Corp.", vendor: 0x0a5c, product: 1, megabits: 12)
        XCTAssertEqual(find("bt-off", facts)?.fixIDs, ["bt-broadcom"])
    }

    func testAirDropNeverOffersFalseFixOnRealtek() {
        var facts = base()
        facts.pci = [PCIDevice(name: "w", vendor: 0x10ec, device: 0xc852, classCode: 0x0280)]
        let finding = find("airdrop", facts)
        XCTAssertEqual(finding?.status, .problem)
        XCTAssertEqual(finding?.fixIDs, ["continuity-unavailable"])
    }

    func testBothNetworksWarned() {
        var facts = base()
        facts.pci = [PCIDevice(name: "w", vendor: 0x10ec, device: 0xc852, classCode: 0x0280)]
        facts.interfaces = [
            NetworkInterface(port: "Ethernet", device: "en0", ipv4: "10.0.0.2", active: true, media: ""),
            NetworkInterface(port: "Wi-Fi", device: "en1", ipv4: "10.0.0.3", active: true, media: ""),
        ]
        XCTAssertNotNil(find("dual-network", facts))
        facts.interfaces[1].ipv4 = nil
        XCTAssertNil(find("dual-network", facts))
    }

    func testUnreadableReportNeverClaimsMissingHardware() {
        var facts = base()
        SystemScanner.applyProfiler("warning: not json", to: &facts)
        XCTAssertFalse(facts.hardwareReportRead)
        let findings = Checks.run(facts)
        for area in [Area.sound, .bluetooth, .usb, .graphics] {
            XCTAssertEqual(findings.first { $0.category == area }?.status, .unknown, area.rawValue)
        }
    }

    func testRealMacGetsNoBootFixes() {
        var facts = base()
        facts.openCoreVersion = nil
        XCTAssertEqual(find("not-opencore", facts)?.status, .warning)
    }
}

final class EFITests: XCTestCase {
    private var folder: URL!
    private var paths: EFIPaths!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hs-test-\(UUID().uuidString)", isDirectory: true)
        paths = EFIPaths(mountPoint: folder.appendingPathComponent("mount", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.kexts, withIntermediateDirectories: true)
        for name in ["Lilu.kext", "AppleALC.kext"] {
            try makeKext(at: paths.kexts.appendingPathComponent(name), executable: String(name.dropLast(5)))
        }
        try Self.sampleConfig().write(to: paths.config)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeKext(at url: URL, executable: String?) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleShortVersionString": "1.0", "OSBundleLibraries": ["as.vit9696.Lilu": "1"]]
        if let executable {
            plist["CFBundleExecutable"] = executable
            try Data("binary".utf8).write(to: url.appendingPathComponent("Contents/MacOS/\(executable)"))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    static func sampleConfig() throws -> Data {
        let entry: (String) -> [String: Any] = { name in
            ["Arch": "Any", "BundlePath": name, "Comment": "", "Enabled": true,
             "ExecutablePath": "Contents/MacOS/\(name.dropLast(5))", "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"]
        }
        let plist: [String: Any] = [
            "ACPI": ["Add": [["Path": "SSDT-Disable_Network_RP05.aml", "Enabled": true], ["Path": "SSDT-EC.aml", "Enabled": true]]],
            "DeviceProperties": ["Add": ["PciRoot(0x0)/Pci(0x1F,0x3)": ["layout-id": Data([97, 0, 0, 0])]]],
            "Kernel": ["Add": [entry("Lilu.kext"), entry("AppleALC.kext")], "Quirks": ["XhciPortLimit": true]],
            "NVRAM": ["Add": [OpenCoreConfig.bootArgsGUID: ["boot-args": "keepsyms=1 alcid=11 -v"]]],
            "PlatformInfo": ["Generic": ["SystemSerialNumber": "SAMPLE"]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func manager(_ runner: PrivilegedRunner = LocalRunner(), bundled: URL? = nil) -> EFIManager {
        EFIManager(paths: paths, backupRoot: folder.appendingPathComponent("backups"), runner: runner, fetcher: KextFetcher(bundledRoot: bundled))
    }

    func testEditsAndUntouchedValues() throws {
        let config = try OpenCoreConfig(data: Self.sampleConfig())
        XCTAssertEqual(try config.apply(.addBootArg("-btlfxboardid")), ["Add boot argument -btlfxboardid"])
        XCTAssertEqual(try config.apply(.addBootArg("-btlfxboardid")), [])
        XCTAssertEqual(try config.apply(.removeBootArg("-v")), ["Remove boot argument -v"])
        try config.apply(.setLayoutID(41))
        XCTAssertEqual(config.layoutID, 41)
        try config.apply(.setLayoutID(11))
        XCTAssertEqual(config.layoutID, 11, "a number stays a number")
        XCTAssertFalse(config.bootArgs.contains { $0.hasPrefix("alcid=") }, "alcid would override the layout")
        XCTAssertThrowsError(try config.apply(.setLayoutID(0)))
        try config.apply(.setACPIEnabled(pathContains: "Disable_Network", enabled: false))
        XCTAssertFalse(config.acpiEnabled(pathContains: "Disable_Network"))
        XCTAssertTrue(config.acpiEnabled(pathContains: "SSDT-EC"))
        let again = try OpenCoreConfig(data: config.serialized())
        let serial = ((again.root["PlatformInfo"] as? NSDictionary)?["Generic"] as? NSDictionary)?["SystemSerialNumber"] as? String
        XCTAssertEqual(serial, "SAMPLE")
    }

    func testKextOrder() throws {
        let config = try OpenCoreConfig(data: Self.sampleConfig())
        try config.apply(.addKext(KextEntry(bundle: "Plugin.kext", executable: "Contents/MacOS/Plugin", after: ["Lilu.kext"])))
        XCTAssertEqual(config.enabledKexts, ["Lilu.kext", "Plugin.kext", "AppleALC.kext"])
        try config.apply(.addKext(KextEntry(bundle: "Last.kext", executable: "")))
        XCTAssertEqual(config.enabledKexts.last, "Last.kext")
    }

    func testRealConfigRoundTrips() throws {
        // Set HS_SAMPLE_CONFIG to a real config. It prints none of the contents.
        guard let path = ProcessInfo.processInfo.environment["HS_SAMPLE_CONFIG"] else { throw XCTSkip("no sample") }
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try OpenCoreConfig(data: original)
        let before = try PropertyListSerialization.propertyList(from: original, format: nil) as? NSDictionary
        let after = try PropertyListSerialization.propertyList(from: config.serialized(), format: nil) as? NSDictionary
        XCTAssertTrue(before?.isEqual(to: after as? [AnyHashable: Any] ?? [:]) == true)
        XCTAssertEqual(config.layoutID, 41)
        XCTAssertTrue(config.bootArgs.contains("-btlfxboardid"))
    }

    func testApplyBacksUpInstallsAndRestores() async throws {
        let bundled = folder.appendingPathComponent("res/BundledKexts", isDirectory: true)
        try makeKext(at: bundled.appendingPathComponent("New.kext"), executable: "New")
        let original = try Data(contentsOf: paths.config)
        let efi = manager(bundled: folder.appendingPathComponent("res"))

        let plan = FixPlan(edits: [.addBootArg("-test")],
                           kexts: [.bundled(folder: "BundledKexts", kexts: [KextSpec("New.kext", after: ["Lilu.kext"])])])
        let prepared = try await efi.prepare(plan)
        XCTAssertEqual(try Data(contentsOf: paths.config), original, "prepare must not write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.kexts.appendingPathComponent("New.kext").path))

        let result = try efi.apply(prepared, fixTitle: "Test's fix")
        let config = try OpenCoreConfig(contentsOf: paths.config)
        XCTAssertEqual(config.enabledKexts, ["Lilu.kext", "New.kext", "AppleALC.kext"])
        XCTAssertTrue(config.bootArgs.contains("-test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.kexts.appendingPathComponent("New.kext/Contents/MacOS/New").path))

        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("EFI/OC/config.plist")), original)

        let entries = efi.backups()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].note, "Before: Test's fix")
        try efi.restore(entries[0])
        XCTAssertEqual(try Data(contentsOf: paths.config), original)
    }

    func testFailedAuthorizationChangesNothing() async throws {
        let original = try Data(contentsOf: paths.config)
        let efi = manager(FailingRunner())
        let prepared = try await efi.prepare(FixPlan(edits: [.addBootArg("-test")]))
        XCTAssertThrowsError(try efi.apply(prepared, fixTitle: "x"))
        XCTAssertEqual(try Data(contentsOf: paths.config), original)
    }

    func testFailureMidwayLeavesConfigAlone() async throws {
        let original = try Data(contentsOf: paths.config)
        let bundled = folder.appendingPathComponent("res/BundledKexts", isDirectory: true)
        try makeKext(at: bundled.appendingPathComponent("New.kext"), executable: "New")
        let efi = manager(bundled: folder.appendingPathComponent("res"))
        let prepared = try await efi.prepare(FixPlan(kexts: [.bundled(folder: "BundledKexts", kexts: [KextSpec("New.kext")])]))
        // The staged kext disappears, so the copy step fails before config.plist is swapped.
        try FileManager.default.removeItem(at: prepared.kexts[0].stagedURL)
        XCTAssertThrowsError(try efi.apply(prepared, fixTitle: "x"))
        XCTAssertEqual(try Data(contentsOf: paths.config), original)
    }

    func testRestoreBringsBackReplacedKexts() async throws {
        let target = paths.kexts.appendingPathComponent("Lilu.kext/Contents/MacOS/Lilu")
        let original = try Data(contentsOf: target)
        let bundled = folder.appendingPathComponent("res/BundledKexts", isDirectory: true)
        try makeKext(at: bundled.appendingPathComponent("Lilu.kext"), executable: "Lilu")
        try Data("replacement".utf8).write(to: bundled.appendingPathComponent("Lilu.kext/Contents/MacOS/Lilu"))
        let efi = manager(bundled: folder.appendingPathComponent("res"))
        let prepared = try await efi.prepare(FixPlan(kexts: [.bundled(folder: "BundledKexts", kexts: [KextSpec("Lilu.kext")])]))
        _ = try efi.apply(prepared, fixTitle: "x")
        XCTAssertEqual(try Data(contentsOf: target), Data("replacement".utf8))
        try efi.restore(efi.backups()[0])
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testFailedKextCopyKeepsTheOldKext() async throws {
        let target = paths.kexts.appendingPathComponent("Lilu.kext/Contents/MacOS/Lilu")
        let bundled = folder.appendingPathComponent("res/BundledKexts", isDirectory: true)
        try makeKext(at: bundled.appendingPathComponent("Lilu.kext"), executable: "Lilu")
        let efi = manager(bundled: folder.appendingPathComponent("res"))
        let prepared = try await efi.prepare(FixPlan(kexts: [.bundled(folder: "BundledKexts", kexts: [KextSpec("Lilu.kext")])]))
        try FileManager.default.removeItem(at: prepared.kexts[0].stagedURL)
        XCTAssertThrowsError(try efi.apply(prepared, fixTitle: "x"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "the old kext must survive")
    }

    func testInstalledKextIsKeptNotDownloaded() async throws {
        // No network and no bundled files here, so this only passes if it uses the copy on disk.
        let config = try OpenCoreConfig(contentsOf: paths.config)
        XCTAssertTrue(config.enabledKexts.contains("Lilu.kext"))
        let extra = paths.kexts.appendingPathComponent("Extra.kext")
        try makeKext(at: extra, executable: "Extra")
        let prepared = try await manager().prepare(FixPlan(kexts: [.github(repo: "invalid/invalid", kexts: [KextSpec("Extra.kext", after: ["Lilu.kext"])])]))
        XCTAssertTrue(prepared.kexts.isEmpty)
        XCTAssertEqual(try OpenCoreConfig(data: XCTUnwrap(prepared.newConfig)).enabledKexts, ["Lilu.kext", "Extra.kext", "AppleALC.kext"])
    }

    func testChangedConfigIsRefused() async throws {
        let efi = manager()
        let prepared = try await efi.prepare(FixPlan(edits: [.addBootArg("-test")]))
        try Data((try String(contentsOf: paths.config, encoding: .utf8) + "\n").utf8).write(to: paths.config)
        XCTAssertThrowsError(try efi.apply(prepared, fixTitle: "x"))
    }

    func testMissingListedKextBlocksChange() async throws {
        try FileManager.default.removeItem(at: paths.kexts.appendingPathComponent("AppleALC.kext"))
        do {
            _ = try await manager().prepare(FixPlan(edits: [.addBootArg("-test")]))
            XCTFail("should refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AppleALC.kext"))
        }
    }

    func testRealDownloadInstallsSimpleHDA() async throws {
        guard ProcessInfo.processInfo.environment["HS_NETWORK_TESTS"] == "1" else { throw XCTSkip("needs network") }
        let efi = manager()
        let fix = try XCTUnwrap(FixCatalog.fix(id: "sound-simplehda", facts: SystemFacts()))
        guard case .automatic(let build) = fix.kind else { return XCTFail("not automatic") }
        let prepared = try await efi.prepare(try build(nil))
        XCTAssertEqual(prepared.kexts.map(\.spec.bundle), ["SimpleHDA.kext"], "Lilu and AppleALC are already there")
        XCTAssertNotNil(prepared.kexts[0].sha256)
        XCTAssertTrue(prepared.kexts[0].executable.hasPrefix("Contents/MacOS/"))
        _ = try efi.apply(prepared, fixTitle: fix.title)
        XCTAssertEqual(try OpenCoreConfig(contentsOf: paths.config).enabledKexts, ["Lilu.kext", "AppleALC.kext", "SimpleHDA.kext"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.kexts.appendingPathComponent("SimpleHDA.kext/Contents/Info.plist").path))
    }

    func testCommandsNeedNoEFI() async throws {
        let efi = EFIManager(paths: nil, runner: LocalRunner())
        let prepared = try await efi.prepare(FixPlan(commands: ["true"]))
        XCTAssertNil(try efi.apply(prepared, fixTitle: "x").backup)
    }
}

final class ConfigDoctorTests: XCTestCase {
    private var folder: URL!
    private var paths: EFIPaths!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hs-doctor-\(UUID().uuidString)", isDirectory: true)
        paths = EFIPaths(mountPoint: folder)
        try FileManager.default.createDirectory(at: paths.kexts, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func kext(_ name: String, id: String? = nil, needs: [String] = [], program: String? = nil) throws {
        let url = paths.kexts.appendingPathComponent("\(name).kext/Contents/MacOS")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let executable = program ?? name
        try Data("x".utf8).write(to: url.appendingPathComponent(executable))
        let info: [String: Any] = ["CFBundleIdentifier": id ?? "test.\(name)", "CFBundleExecutable": executable,
                                   "OSBundleLibraries": Dictionary(uniqueKeysWithValues: needs.map { ($0, "1") })]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: paths.kexts.appendingPathComponent("\(name).kext/Contents/Info.plist"))
    }

    private func entry(_ name: String, enabled: Bool = true, executable: String? = nil, arch: String = "Any", max: String = "") -> [String: Any] {
        ["Arch": arch, "BundlePath": "\(name).kext", "Enabled": enabled, "ExecutablePath": executable ?? "Contents/MacOS/\(name)",
         "MinKernel": "", "MaxKernel": max, "PlistPath": "Contents/Info.plist", "Comment": ""]
    }

    private func config(_ kexts: [[String: Any]], delete: [String] = ["boot-args"], extra: (inout [String: Any]) -> Void = { _ in }) throws -> OpenCoreConfig {
        var plist: [String: Any] = [
            "Kernel": ["Add": kexts, "Quirks": [:]],
            "ACPI": ["Add": []],
            "UEFI": ["Drivers": [], "Quirks": [:], "ConnectDrivers": true],
            "Booter": ["Quirks": [:]],
            "Misc": ["Security": ["Vault": "Optional", "SecureBootModel": "Default", "DmgLoading": "Signed"], "Boot": ["PickerMode": "Builtin"]],
            "NVRAM": ["Add": [OpenCoreConfig.bootArgsGUID: ["boot-args": "-v"]], "Delete": [OpenCoreConfig.bootArgsGUID: delete]],
            "PlatformInfo": ["Generic": ["SystemSerialNumber": "SECRET-SERIAL"]],
        ]
        extra(&plist)
        return try OpenCoreConfig(data: PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }

    private func ids(_ config: OpenCoreConfig, kernel: String = "25.7.0") -> [String] {
        ConfigDoctor.check(config: config, paths: paths, kernel: kernel).map(\.id)
    }

    func testHealthyConfigHasNoFindings() throws {
        try kext("Lilu"); try kext("AppleALC", needs: ["test.Lilu"])
        XCTAssertEqual(ids(try config([entry("Lilu"), entry("AppleALC")])), [])
    }

    func testKnownOrderIsFoundAndFixed() throws {
        try kext("Lilu"); try kext("WhateverGreen"); try kext("VirtualSMC"); try kext("SMCProcessor")
        let c = try config([entry("SMCProcessor"), entry("VirtualSMC"), entry("WhateverGreen"), entry("Lilu")])
        XCTAssertTrue(ids(c).contains("cfg-order"))
        try c.apply(.reorderKexts(ConfigDoctor.orderProblems(c, paths: paths)))
        XCTAssertEqual(ConfigDoctor.orderProblems(c, paths: paths), [])
        let order = c.enabledKexts
        XCTAssertLessThan(order.firstIndex(of: "Lilu.kext")!, order.firstIndex(of: "VirtualSMC.kext")!)
        XCTAssertLessThan(order.firstIndex(of: "VirtualSMC.kext")!, order.firstIndex(of: "SMCProcessor.kext")!)
    }

    func testOrderFromAKextsOwnDependencies() throws {
        try kext("Base", id: "x.base"); try kext("Plugin", needs: ["x.base"])
        XCTAssertEqual(ConfigDoctor.orderProblems(try config([entry("Plugin"), entry("Base")]), paths: paths),
                       [ConfigDoctor.OrderPair(child: "Plugin.kext", parent: "Base.kext")])
    }

    func testDependencyLoopIsRefused() throws {
        let c = try config([entry("A"), entry("B")])
        XCTAssertThrowsError(try c.apply(.reorderKexts([.init(child: "A.kext", parent: "B.kext"), .init(child: "B.kext", parent: "A.kext")])))
    }

    func testMissingFilesAndCodelessEntries() throws {
        try kext("Real")
        let c = try config([entry("Gone"), entry("Real", executable: "")])
        let found = ids(c)
        XCTAssertTrue(found.contains("cfg-kext-missing"))
        XCTAssertTrue(found.contains("cfg-kext-nocode"))
        let fixes = ConfigDoctor.missingExecutables(c, paths: paths)
        XCTAssertEqual(fixes, [KextPathFix(bundle: "Real.kext", executable: "Contents/MacOS/Real")])
    }

    func testBootArgsWithoutDeleteIsFlaggedAndFixed() throws {
        let c = try config([], delete: ["#boot-args"])
        XCTAssertTrue(ids(c).contains("cfg-bootargs"))
        XCTAssertEqual(try c.apply(.addNVRAMDelete(guid: OpenCoreConfig.bootArgsGUID.lowercased(), name: "boot-args")).count, 1)
        XCTAssertFalse(ids(c).contains("cfg-bootargs"))
    }

    func testSecurityConflict() throws {
        let c = try config([]) { p in p["Misc"] = ["Security": ["Vault": "Optional", "SecureBootModel": "j137", "DmgLoading": "Any"]] }
        XCTAssertTrue(ids(c).contains("cfg-dmg"))
        let off = try config([]) { p in p["Misc"] = ["Security": ["Vault": "Optional", "SecureBootModel": "Disabled", "DmgLoading": "Any"]] }
        XCTAssertFalse(ids(off).contains("cfg-dmg"))
    }

    func testMissingVaultKeyBehavesLikeSecure() throws {
        let c = try config([]) { p in p["Misc"] = ["Security": ["SecureBootModel": "Default"]] }
        XCTAssertTrue(ids(c).contains("cfg-vault-missing"))
    }

    func testVaultedEFIIsNeverEdited() async throws {
        try Data("x".utf8).write(to: paths.efi.appendingPathComponent("OC/vault.plist"))
        try config([]).serialized().write(to: paths.config)
        let efi = EFIManager(paths: paths, backupRoot: folder.appendingPathComponent("backups"), runner: LocalRunner())
        do {
            _ = try await efi.prepare(FixPlan(edits: [.addBootArg("-x")]))
            XCTFail("must refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Vault"))
        }
    }

    func testDarwinVersionLimits() {
        XCTAssertEqual(ConfigDoctor.darwinVersion("25.7.0"), 250700)
        XCTAssertEqual(ConfigDoctor.darwinVersion("24"), 240000)
        XCTAssertEqual(ConfigDoctor.darwinVersion("x"), 0)
        XCTAssertEqual(ConfigDoctor.darwinVersion(""), 0)
        XCTAssertFalse(ConfigDoctor.loads(on: 240600, min: "", max: "24"), "24 means 24.0.0 or older")
        XCTAssertTrue(ConfigDoctor.loads(on: 250700, min: "bad", max: ""), "unreadable limits are no limit")
    }

    func testDuplicatesTurnedOff() throws {
        try kext("A")
        let c = try config([entry("A"), entry("A")])
        XCTAssertTrue(ids(c).contains("cfg-dup"))
        XCTAssertEqual(try c.apply(.turnOffDuplicateKexts).count, 1)
        XCTAssertEqual(c.enabledKexts, ["A.kext"])
    }

    func testFindingsNeverContainSerial() throws {
        let c = try config([entry("Gone")])
        let text = ConfigDoctor.check(config: c, paths: paths, kernel: "25.7.0").map { $0.title + $0.detail }.joined()
        XCTAssertFalse(text.contains("SECRET-SERIAL"))
    }
}

final class NullMothDoctorTests: XCTestCase {
    private func facts(args: String = "nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0", loaded: Bool = true) -> SystemFacts {
        var f = SystemFacts()
        f.osVersion = "26.7.2"
        f.pci = [PCIDevice(name: "GFX0", vendor: 0x10de, device: 0x2d59, classCode: 0x0300)]
        f.bootArgs = args
        if loaded { f.kexts = ["com.nullmoth.NVRM": "2.6.6"] }
        return f
    }

    private func ids(_ f: SystemFacts) -> [String] { NullMothDoctor.check(f).map(\.id) }

    func testAllowListFollowsFirstMatch() {
        let stock = "# note\n*\n!WindowServer\n"
        XCTAssertEqual(NullMothDoctor.access(for: "WindowServer", allowList: stock), .allowed, "* comes first, so !WindowServer is never reached")
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "-A\n*\n"), .denied)
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "*\n-A\n"), .allowed, "a deny after * never fires")
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "!A\n"), .onlyWhenReady)
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "B\n"), .denied, "no match means no access")
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "  A\r\n"), .allowed)
        XCTAssertEqual(NullMothDoctor.access(for: "A", allowList: "-*\nA\n"), .allowed, "-* is not a wildcard")
    }

    func testHealthyDriverOnlyShowsOkAndHelp() {
        var f = facts()
        f.nullMoth.allowList = "*\n"
        f.nullMoth.allowListMode = 0o644
        XCTAssertEqual(Set(ids(f)), ["nv-ok", "nv-flicker", "nv-icons"])
    }

    func testNotInstalledPointsToOfficialInstaller() {
        let finding = NullMothDoctor.check(facts(args: "", loaded: false)).first { $0.id == "nv-none" }
        XCTAssertEqual(finding?.fixIDs, ["nv-get-driver"])
    }

    func testOldCardAndNonNvidia() {
        var f = facts()
        f.pci[0].device = 0x1b80
        XCTAssertEqual(ids(f), ["nv-old"])
        f.pci = [PCIDevice(name: "GFX0", vendor: 0x1002, device: 1, classCode: 0x0300)]
        XCTAssertEqual(ids(f), [])
    }

    func testWhateverGreenNeedsGfxrst() {
        var f = facts()
        f.kexts["as.vit9696.WhateverGreen"] = "1.7"
        XCTAssertTrue(ids(f).contains("nv-args"))
        f.bootArgs += " gfxrst=4"
        XCTAssertFalse(ids(f).contains("nv-args"))
    }

    func testConflictsAndSleep() {
        XCTAssertTrue(ids(facts(args: "-wegnoegpu", loaded: false)).contains("nv-conflict"))
        XCTAssertFalse(ids(facts(args: "-wegnoegpu", loaded: false)).contains("nv-none"))
        XCTAssertTrue(ids(facts(args: "-nvrmnopm nvfb=1", loaded: true)).contains("nv-nopm"))
    }

    func testBlockedWindowServerIsAProblemButFileIsNeverEdited() {
        var f = facts()
        f.nullMoth.allowList = "-WindowServer\n*\n"
        XCTAssertTrue(ids(f).contains("nv-allow-denied"))
        for fix in NullMothDoctor.fixes(facts: f) {
            guard case .automatic(let build) = fix.kind else { continue }
            let commands = (try? build(nil))?.commands ?? []
            XCTAssertFalse(commands.joined().contains("nvmtl"), fix.id)
        }
    }

    func testVersionHelpers() {
        XCTAssertTrue(NullMothDoctor.isNewer("2.7", than: "2.6.6"))
        XCTAssertFalse(NullMothDoctor.isNewer("2.6.6", than: "2.6.6"))
        XCTAssertFalse(NullMothDoctor.isNewer("2.6", than: "2.6.6"))
        XCTAssertEqual(NullMothDoctor.parseLatest("{\"tag_name\":\"v2.6.6\"}"), "2.6.6")
        XCTAssertNil(NullMothDoctor.parseLatest("offline"))
        XCTAssertEqual(NullMothDoctor.parseCount("%02"), 2)
        XCTAssertEqual(NullMothDoctor.parseCount("1"), 1)
        XCTAssertEqual(NullMothDoctor.parsePowerState("x\n  \"nvrm-pm\" = \"running\"\n"), "running")
    }

    func testFixAllOnlyTakesSafeAutomaticFixes() throws {
        var f = facts()
        f.hibernateMode = 3
        f.hasBattery = true
        f.bootArgs += " -nvrmnopm"
        f.efiDevice = "disk0s1"
        let findings = Checks.run(f)
        let safe = FixPlanner.safeFixes(findings: findings, facts: f)
        let chosen = Set(safe.map(\.id))
        XCTAssertTrue(chosen.contains("hibernate-off"))
        XCTAssertFalse(chosen.contains("nv-allow-sleep"), "medium risk stays a separate choice")
        XCTAssertFalse(chosen.contains("mount-efi"))
        XCTAssertTrue(safe.allSatisfy { $0.risk == .low && $0.parameter == nil })
        guard case .automatic(let build) = FixPlanner.combined(safe).kind else { return XCTFail("not automatic") }
        XCTAssertTrue(try build(nil).commands.contains { $0.contains("hibernatemode") })
    }
}

final class ProblemGuideTests: XCTestCase {
    func testSearchFindsRealWordsFromScreens() {
        XCTAssertFalse(ProblemGuide.search("Waiting for Root Device").isEmpty)
        XCTAssertFalse(ProblemGuide.search("EXITBS").isEmpty)
        XCTAssertFalse(ProblemGuide.search("no sound tahoe").isEmpty)
        XCTAssertTrue(ProblemGuide.search("zzzz-not-a-problem").isEmpty)
        XCTAssertEqual(ProblemGuide.search("").count, ProblemGuide.entries.count)
    }

    func testEntriesAreComplete() {
        XCTAssertEqual(Set(ProblemGuide.entries.map(\.id)).count, ProblemGuide.entries.count, "ids must be unique")
        for entry in ProblemGuide.entries {
            XCTAssertFalse(entry.steps.isEmpty, entry.problem)
            XCTAssertFalse(entry.cause.isEmpty, entry.problem)
            XCTAssertTrue(entry.link.hasPrefix("https://"), entry.problem)
        }
    }
}
