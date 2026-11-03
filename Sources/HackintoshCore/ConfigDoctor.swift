import Foundation

/// Checks config.plist the way OpenCore reads it at startup, and explains problems in everyday words.
/// The rules were worked out from OpenCore's documentation and source, and written fresh for this app.
/// They were checked against OpenCore 1.0.9. They never read PlatformInfo, so serial numbers stay private.
public enum ConfigDoctor {
    public struct OrderPair: Equatable, Sendable {
        public let child: String
        public let parent: String

        public init(child: String, parent: String) {
            self.child = child
            self.parent = parent
        }
    }

    /// Kexts OpenCore's validator knows must load after another one.
    static let knownOrder: [OrderPair] = {
        let lilu = ["VirtualSMC", "WhateverGreen", "AppleALC", "AppleALCU", "AirportBrcmFixup", "BrightnessKeys", "CpuTscSync",
                    "CPUFriend", "CryptexFixup", "DebugEnhancer", "HibernationFixup", "NVMeFix", "RestrictEvents", "RTCMemoryFixup",
                    "FeatureUnlock", "MacHyperVSupport", "BlueToolFixup"]
        let smc = ["SMCBatteryManager", "SMCDellSensors", "SMCLightSensor", "SMCProcessor", "SMCSuperIO"]
        let ps2 = ["Keyboard", "Mouse", "Trackpad"]
        return lilu.map { OrderPair(child: "\($0).kext", parent: "Lilu.kext") }
            + smc.map { OrderPair(child: "\($0).kext", parent: "VirtualSMC.kext") }
            + [OrderPair(child: "CPUFriendDataProvider.kext", parent: "CPUFriend.kext")]
            + ps2.map { OrderPair(child: "VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2\($0).kext", parent: "VoodooPS2Controller.kext") }
    }()

    static let validSecureBootModels: Set<String> = ["Default", "Disabled", "j137", "j680", "j132", "j174", "j140k", "j780", "j213",
                                                     "j140a", "j152f", "j160", "j230k", "j214k", "j223", "j215", "j185", "j185f", "x86legacy"]
    static let bootArgsGUID = OpenCoreConfig.bootArgsGUID
    static let maxPathLength = 192

    struct Kext {
        let bundle: String
        let executable: String
        let plist: String
        let enabled: Bool
        let arch: String
        let minKernel: String
        let maxKernel: String
    }

    static func kexts(_ config: OpenCoreConfig) -> [Kext] {
        let list = (config.root["Kernel"] as? NSDictionary)?["Add"] as? NSArray ?? []
        return list.compactMap { item in
            guard let entry = item as? NSDictionary else { return nil }
            return Kext(bundle: entry["BundlePath"] as? String ?? "",
                        executable: entry["ExecutablePath"] as? String ?? "",
                        plist: entry["PlistPath"] as? String ?? "",
                        enabled: entry["Enabled"] as? Bool ?? false,
                        arch: entry["Arch"] as? String ?? "Any",
                        minKernel: entry["MinKernel"] as? String ?? "",
                        maxKernel: entry["MaxKernel"] as? String ?? "")
        }
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func name(_ bundle: String) -> String {
        let last = bundle.split(separator: "/").last.map(String.init) ?? bundle
        return last.hasSuffix(".kext") ? String(last.dropLast(5)) : last
    }

    private static func list(_ names: [String], limit: Int = 4) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) and \(names.count - limit) more" : shown
    }

    // MARK: Version limits

    /// Darwin version as major*10000 + minor*100 + patch, or 0 if it can't be read.
    public static func darwinVersion(_ text: String) -> Int {
        var numbers: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part), (0...99).contains(value) else { return 0 }
            numbers.append(value)
        }
        guard (1...3).contains(numbers.count) else { return 0 }
        numbers += Array(repeating: 0, count: 3 - numbers.count)
        return numbers[0] * 10000 + numbers[1] * 100 + numbers[2]
    }

    static func loads(on kernel: Int, min: String, max: String) -> Bool {
        let low = darwinVersion(min), high = darwinVersion(max)
        if low != 0 && kernel < low { return false }
        if high != 0 && kernel > high { return false }
        return true
    }

    // MARK: Order

    /// Pairs currently in the wrong order, from OpenCore's known list and from each kext's own Info.plist.
    public static func orderProblems(_ config: OpenCoreConfig, paths: EFIPaths?) -> [OrderPair] {
        let entries = kexts(config)
        var result: [OrderPair] = []
        func index(_ bundle: String) -> Int? { entries.firstIndex { $0.bundle == bundle && $0.enabled } }

        for pair in knownOrder {
            if let child = index(pair.child), let parent = index(pair.parent), child < parent { result.append(pair) }
        }
        guard let paths else { return result }

        var owners: [String: String] = [:]
        var needs: [String: [String]] = [:]
        for entry in entries where entry.enabled && !entry.bundle.isEmpty {
            let plist = paths.kexts.appendingPathComponent(entry.bundle).appendingPathComponent(entry.plist)
            guard let info = read(plist) else { continue }
            if let id = info["CFBundleIdentifier"] as? String { owners[id] = entry.bundle }
            let libraries = Array((info["OSBundleLibraries"] as? [String: Any] ?? [:]).keys)
                + Array((info["OSBundleLibraries_x86_64"] as? [String: Any] ?? [:]).keys)
            needs[entry.bundle] = libraries
        }
        for (bundle, libraries) in needs {
            for library in libraries {
                guard let parent = owners[library], parent != bundle,
                      let c = index(bundle), let p = index(parent), c < p else { continue }
                let pair = OrderPair(child: bundle, parent: parent)
                if !result.contains(pair) { result.append(pair) }
            }
        }
        return result.sorted { $0.child < $1.child }
    }

    // MARK: Checks

    public static func check(config: OpenCoreConfig, paths: EFIPaths?, kernel: String) -> [Finding] {
        var out: [Finding] = []
        let security = (config.root["Misc"] as? NSDictionary)?["Security"] as? NSDictionary
        let entries = kexts(config)
        let enabled = entries.filter(\.enabled)

        // Things that can stop the Mac starting.
        if let paths {
            let vault = security?["Vault"] as? String ?? "Secure"
            let hasVaultFile = FileManager.default.fileExists(atPath: paths.efi.appendingPathComponent("OC/vault.plist").path)
            if !["Optional", "Basic", "Secure"].contains(vault) {
                out.append(Finding("cfg-vault-bad", .boot, .problem, "A security setting will stop your Mac starting",
                                   "OpenCore doesn't recognize the Vault setting, so it would stop before the boot menu.", fixes: ["cfg-vault-optional"]))
            } else if vault != "Optional" && !hasVaultFile {
                out.append(Finding("cfg-vault-missing", .boot, .problem, "A security setting will stop your Mac starting",
                                   "OpenCore is set to check a vault file, but that file doesn't exist.", fixes: ["cfg-vault-optional"]))
            } else if hasVaultFile {
                out.append(Finding("cfg-vault-on", .boot, .warning, "Your boot files are locked",
                                   "OpenCore Vault is protecting these files, so any change would stop your Mac starting. This app won't edit them. To allow changes, follow OpenCore's Vault steps first."))
            }
        }

        let model = security?["SecureBootModel"] as? String ?? "Default"
        let dmg = security?["DmgLoading"] as? String ?? "Signed"
        if model != "Disabled" && !["Signed", "Disabled", ""].contains(dmg) {
            out.append(Finding("cfg-dmg", .boot, .problem, "Two security settings conflict",
                               "Apple Secure Boot is on, but disk image loading is set to “\(dmg)”. OpenCore stops at startup when they're combined.", fixes: ["cfg-dmg-signed"]))
        }
        if !model.isEmpty && !validSecureBootModels.contains(model) {
            out.append(Finding("cfg-model", .boot, .warning, "Secure Boot has an unknown setting",
                               "OpenCore doesn't recognize “\(model)”, so Secure Boot won't be set up as intended.", fixes: ["cfg-model-default"]))
        }

        // Files the config lists but that aren't there.
        if let paths {
            var missing: [String] = []
            var noCode: [(bundle: String, executable: String)] = []
            for entry in enabled {
                if entry.bundle.isEmpty || entry.plist.isEmpty { missing.append(entry.bundle.isEmpty ? "A kext with no name" : name(entry.bundle)); continue }
                let folder = paths.kexts.appendingPathComponent(entry.bundle)
                let plist = folder.appendingPathComponent(entry.plist)
                guard FileManager.default.fileExists(atPath: plist.path) else { missing.append(name(entry.bundle)); continue }
                if !entry.executable.isEmpty, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.executable).path) {
                    missing.append(name(entry.bundle))
                }
                if entry.executable.isEmpty, let program = read(plist)?["CFBundleExecutable"] as? String, !program.isEmpty {
                    noCode.append((entry.bundle, "Contents/MacOS/\(program)"))
                }
            }
            if !missing.isEmpty {
                out.append(Finding("cfg-kext-missing", .boot, .problem, "Some drivers are missing",
                                   "Your setup expects \(list(missing)), but the files aren't there, so they won't load. Your Mac may lose that feature or fail to start.", fixes: ["cfg-reinstall-help"]))
            }
            if !noCode.isEmpty {
                out.append(Finding("cfg-kext-nocode", .boot, .problem, "A driver is set up in a way that can crash your Mac",
                                   "\(list(noCode.map { name($0.bundle) })) \(noCode.count == 1 ? "has" : "have") a program file that the config doesn't point to. OpenCore's source says this makes macOS crash.", fixes: ["cfg-kext-paths"]))
            }
            let missingACPI = enabledPaths(config, section: "ACPI").filter { !FileManager.default.fileExists(atPath: paths.efi.appendingPathComponent("OC/ACPI/\($0)").path) }
            if !missingACPI.isEmpty {
                out.append(Finding("cfg-acpi-missing", .boot, .warning, "Some hardware patches are missing",
                                   "\(list(missingACPI)) \(missingACPI.count == 1 ? "is" : "are") listed but not on the boot partition, so OpenCore skips \(missingACPI.count == 1 ? "it" : "them").", fixes: ["cfg-reinstall-help"]))
            }
            let missingDrivers = enabledDrivers(config).filter { !FileManager.default.fileExists(atPath: paths.efi.appendingPathComponent("OC/Drivers/\($0)").path) }
            if !missingDrivers.isEmpty {
                out.append(Finding("cfg-driver-missing", .boot, .problem, "Some startup drivers are missing",
                                   "\(list(missingDrivers)) \(missingDrivers.count == 1 ? "is" : "are") listed but not on the boot partition, so OpenCore skips \(missingDrivers.count == 1 ? "it" : "them").", fixes: ["cfg-reinstall-help"]))
            }
            let tooLong = enabled.filter { 6 + $0.bundle.count + 1 + $0.plist.count + 1 > maxPathLength || 6 + $0.bundle.count + 1 + $0.executable.count + 1 > maxPathLength }
            if !tooLong.isEmpty {
                out.append(Finding("cfg-path-long", .boot, .warning, "A driver's file path is too long",
                                   "OpenCore skips paths this long: \(list(tooLong.map { name($0.bundle) })). Use a shorter name or folder."))
            }
        }

        // Load order.
        let order = orderProblems(config, paths: paths)
        if !order.isEmpty {
            let first = order[0]
            out.append(Finding("cfg-order", .boot, .problem, "Some drivers load in the wrong order",
                               "\(name(first.child)) needs \(name(first.parent)), but it's set to load first\(order.count > 1 ? ", and \(order.count - 1) more like this" : ""). Drivers loaded too early can fail to start.", fixes: ["cfg-order"]))
        }

        // Drivers turned off that others depend on.
        let enabledSet = Set(enabled.map(\.bundle))
        let orphans = knownOrder.filter { enabledSet.contains($0.child) && !enabledSet.contains($0.parent) }
        if !orphans.isEmpty {
            let needed = Array(Set(orphans.map { name($0.parent) })).sorted()
            out.append(Finding("cfg-parent-off", .boot, .problem, "A required driver is turned off",
                               "\(list(orphans.map { name($0.child) })) can't work without \(list(needed)), which isn't turned on.", fixes: ["cfg-reinstall-help"]))
        }

        // Listed twice.
        var seen = Set<String>()
        var duplicates = Set<String>()
        for entry in enabled where !entry.bundle.isEmpty {
            if !seen.insert(entry.bundle).inserted { duplicates.insert(entry.bundle) }
        }
        if !duplicates.isEmpty {
            out.append(Finding("cfg-dup", .boot, .warning, "A driver is listed twice",
                               "\(list(duplicates.sorted().map(name))) \(duplicates.count == 1 ? "appears" : "appear") more than once. OpenCore's validator treats this as an error.", fixes: ["cfg-dedupe"]))
        }

        // Limits that stop a kext loading.
        let current = darwinVersion(kernel)
        if current != 0 {
            let skipped = enabled.filter { !loads(on: current, min: $0.minKernel, max: $0.maxKernel) }.map { name($0.bundle) }
            if !skipped.isEmpty {
                out.append(Finding("cfg-kernel", .boot, .info, "Some drivers skip this macOS version",
                                   "\(list(skipped)) \(skipped.count == 1 ? "has a" : "have a") version limit that excludes this macOS, so \(skipped.count == 1 ? "it won't" : "they won't") load. That's fine if it's on purpose."))
            }
        }
        let wrongArch = enabled.filter { $0.arch == "i386" }.map { name($0.bundle) }
        if !wrongArch.isEmpty {
            out.append(Finding("cfg-arch", .boot, .warning, "A driver is set for 32-bit Macs only",
                               "\(list(wrongArch)) won't load on a 64-bit Mac.", fixes: ["cfg-arch-any"]))
        }

        // Settings that quietly do nothing.
        let drivers = enabledDrivers(config)
        let booter = (config.root["Booter"] as? NSDictionary)?["Quirks"] as? NSDictionary
        let uefi = config.root["UEFI"] as? NSDictionary
        let needsRuntime = ["ProvideCustomSlide", "DisableVariableWrite", "EnableWriteUnprotector", "ClearTaskSwitchBit"].filter { booter?[$0] as? Bool == true }
            + ((uefi?["Quirks"] as? NSDictionary)?["RequestBootVarRouting"] as? Bool == true ? ["RequestBootVarRouting"] : [])
        if !needsRuntime.isEmpty && !drivers.contains("OpenRuntime.efi") {
            out.append(Finding("cfg-openruntime", .boot, .problem, "A key startup driver is missing",
                               "Your settings rely on OpenRuntime.efi, but it isn't turned on.", fixes: ["cfg-reinstall-help"]))
        }
        if uefi?["ConnectDrivers"] as? Bool == false, drivers.contains(where: { $0.localizedCaseInsensitiveContains("hfs") || $0 == "AudioDxe.efi" }) {
            out.append(Finding("cfg-connect", .boot, .warning, "Some startup drivers aren't connected",
                               "They load, but they can't reach your hardware, so disks may not appear in the boot menu.", fixes: ["cfg-connect"]))
        }
        let picker = (((config.root["Misc"] as? NSDictionary)?["Boot"] as? NSDictionary)?["PickerMode"] as? String) ?? "Builtin"
        if drivers.contains("OpenCanopy.efi") && picker != "External" {
            out.append(Finding("cfg-canopy", .boot, .info, "The graphical boot menu is turned off",
                               "OpenCanopy is installed, but it only appears when the picker mode is External. You'll get the text menu until then.", fixes: ["cfg-canopy"]))
        }

        // boot-args can silently never apply.
        if (((config.root["NVRAM"] as? NSDictionary)?["Add"] as? NSDictionary)?[bootArgsGUID] as? NSDictionary)?["boot-args"] != nil, !deleteListContainsBootArgs(config) {
            out.append(Finding("cfg-bootargs", .boot, .warning, "Boot setting changes may be ignored",
                               "OpenCore only adds boot arguments if none exist yet. Without a matching delete entry, changes to them may never apply. Fixes you make here might not take effect until this is fixed.", fixes: ["cfg-bootargs"]))
        }
        return out
    }

    static func enabledPaths(_ config: OpenCoreConfig, section: String) -> [String] {
        let list = (config.root[section] as? NSDictionary)?["Add"] as? NSArray ?? []
        return list.compactMap { item in
            guard let entry = item as? NSDictionary, entry["Enabled"] as? Bool == true, let path = entry["Path"] as? String, !path.isEmpty else { return nil }
            return path
        }
    }

    static func enabledDrivers(_ config: OpenCoreConfig) -> [String] {
        let list = (config.root["UEFI"] as? NSDictionary)?["Drivers"] as? NSArray ?? []
        return list.compactMap { item in
            if let path = item as? String { return path.hasPrefix("#") || path.isEmpty ? nil : path }
            guard let entry = item as? NSDictionary, entry["Enabled"] as? Bool == true, let path = entry["Path"] as? String, !path.isEmpty else { return nil }
            return path
        }
    }

    static func deleteListContainsBootArgs(_ config: OpenCoreConfig) -> Bool {
        guard let delete = (config.root["NVRAM"] as? NSDictionary)?["Delete"] as? NSDictionary else { return false }
        for case let key as String in delete.allKeys where key.caseInsensitiveCompare(bootArgsGUID) == .orderedSame {
            if (delete[key] as? NSArray)?.contains("boot-args") == true { return true }
        }
        return false
    }

    /// Paths config.plist should have for a codeless entry, read from each kext's own Info.plist.
    public static func missingExecutables(_ config: OpenCoreConfig, paths: EFIPaths?) -> [KextPathFix] {
        guard let paths else { return [] }
        return kexts(config).compactMap { entry in
            guard entry.enabled, entry.executable.isEmpty, !entry.bundle.isEmpty, !entry.plist.isEmpty,
                  let program = read(paths.kexts.appendingPathComponent(entry.bundle).appendingPathComponent(entry.plist))?["CFBundleExecutable"] as? String,
                  !program.isEmpty else { return nil }
            return KextPathFix(bundle: entry.bundle, executable: "Contents/MacOS/\(program)")
        }
    }

    // MARK: Fixes

    public static func fixes(facts: SystemFacts) -> [Fix] {
        let paths = facts.efiMountPoint.map { EFIPaths(mountPoint: URL(fileURLWithPath: $0)) }
        let order = facts.config.map { orderProblems($0, paths: paths) } ?? []
        let executables = facts.config.map { missingExecutables($0, paths: paths) } ?? []
        return [
            Fix(id: "cfg-order", title: "Fix Driver Order", summary: "Moves drivers so each one loads after what it depends on. Nothing is added or removed.",
                kind: .automatic { _ in FixPlan(edits: [.reorderKexts(order)]) }),
            Fix(id: "cfg-bootargs", title: "Make Boot Settings Apply", summary: "Tells OpenCore to replace old boot arguments at startup, so the ones in your config take effect.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.addNVRAMDelete(guid: bootArgsGUID, name: "boot-args")]) }),
            Fix(id: "cfg-dmg-signed", title: "Fix Security Conflict", summary: "Sets disk image loading to Signed, which works with Apple Secure Boot.",
                kind: .automatic { _ in FixPlan(edits: [.setString(section: ["Misc", "Security"], key: "DmgLoading", value: "Signed")]) }),
            Fix(id: "cfg-model-default", title: "Use the Default Secure Boot Setting", summary: "Sets Secure Boot to Default, which lets OpenCore choose the right model for your Mac setup.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.setString(section: ["Misc", "Security"], key: "SecureBootModel", value: "Default")]) }),
            Fix(id: "cfg-vault-optional", title: "Turn Off the Vault Check", summary: "Sets Vault to Optional, because the current setting would stop your Mac starting. This lowers boot protection.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.setString(section: ["Misc", "Security"], key: "Vault", value: "Optional")]) }),
            Fix(id: "cfg-kext-paths", title: "Fix Driver Paths", summary: "Points the config at each driver's program file, using the driver's own information.",
                kind: .automatic { _ in FixPlan(edits: executables.map { .setKextExecutable(bundle: $0.bundle, executable: $0.executable) }) }),
            Fix(id: "cfg-dedupe", title: "Remove Duplicate Entries", summary: "Turns off the extra copies and keeps the first one. No files are deleted.",
                kind: .automatic { _ in FixPlan(edits: [.turnOffDuplicateKexts]) }),
            Fix(id: "cfg-arch-any", title: "Fix Driver Architecture", summary: "Lets these drivers load on 64-bit Macs. Only do this if you know the driver supports 64-bit.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.setI386KextsToAny]) }),
            Fix(id: "cfg-connect", title: "Connect Startup Drivers", summary: "Turns on ConnectDrivers, so startup drivers can reach your disks and hardware.",
                kind: .automatic { _ in FixPlan(edits: [.setBool(section: ["UEFI"], key: "ConnectDrivers", value: true)]) }),
            Fix(id: "cfg-canopy", title: "Turn On the Graphical Boot Menu", summary: "Sets the picker mode to External. It also needs OpenCanopy's resource files, and without them you may see a blank or text menu.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.setString(section: ["Misc", "Boot"], key: "PickerMode", value: "External")]) }),
            Fix(id: "cfg-reinstall-help", title: "How to Put Them Back", summary: "The files need to come from the same place you got your EFI, or from each project's releases.", needsRestart: true,
                kind: .guided(steps: [
                    "Check Backups in this app. An earlier copy may still have the files.",
                    "Otherwise, download the missing file from its project's releases page.",
                    "Copy kexts to EFI/OC/Kexts, startup drivers to EFI/OC/Drivers, and patches to EFI/OC/ACPI, then scan again.",
                ], link: nil)),
        ]
    }
}

public struct KextPathFix: Equatable, Sendable {
    public let bundle: String
    public let executable: String

    public init(bundle: String, executable: String) {
        self.bundle = bundle
        self.executable = executable
    }
}
