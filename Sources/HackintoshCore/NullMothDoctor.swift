import Foundation

/// Read-only health checks for the NullMoth NVIDIA driver, written from its public documentation.
/// This app contains none of NullMoth's code or files, and it isn't affiliated with the project.
/// Installing, repairing and removing the driver stay with NullMoth's own 1401 app.
public enum NullMothDoctor {
    public static let releasesURL = "https://github.com/nullmoth/nvidia-macos-driver/releases/latest"
    public static let troubleshootingURL = "https://github.com/nullmoth/nvidia-macos-driver/blob/main/docs/TROUBLESHOOTING.md"
    public static let iconIssueURL = "https://github.com/nullmoth/nvidia-macos-driver/issues/314"
    static let firstSupportedDevice = 0x1E00
    static let conflicts = ["nv_disable=1", "-wegnoegpu", "-wegonogpu", "-nvoff"]

    public struct Status: Sendable {
        public var diskVersion: String?
        public var latestVersion: String?
        public var allowList: String?
        public var allowListMode: Int?
        public var driverFilesPresent = true
        public var startFailures: Int?
        public var removalPending = false
        public var powerState: String?

        public init() {}
    }

    /// What the driver would do for a process, following the documented order: the first matching line wins.
    public enum Access: Equatable, Sendable { case allowed, onlyWhenReady, denied }

    public static func access(for process: String, allowList: String) -> Access {
        for raw in allowList.split(whereSeparator: \.isNewline) {
            let line = String(raw.drop { $0 == " " || $0 == "\t" })
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("-") {
                if line.dropFirst() == process { return .denied }
            } else if line.hasPrefix("!") {
                let name = line.dropFirst()
                if name == "*" || name == process { return .onlyWhenReady }
            } else if line == "*" || line == process {
                return .allowed
            }
        }
        return .denied
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let numbers: (String) -> [Int] = { $0.split(separator: ".").map { Int($0) ?? 0 } }
        let a = numbers(candidate), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func hasCard(_ facts: SystemFacts) -> Bool { card(facts) != nil }

    static func card(_ facts: SystemFacts) -> PCIDevice? {
        facts.pci.first { $0.vendor == 0x10de && ($0.classCode == 0x0300 || $0.classCode == 0x0302) }
    }

    static func tokens(_ facts: SystemFacts) -> [String] {
        facts.bootArgs.split(separator: " ").map(String.init)
    }

    /// Boot arguments the driver needs that are safe to add. The AMFI ones are left to 1401, because they lower security.
    static func missingArguments(_ facts: SystemFacts) -> [String] {
        let args = tokens(facts)
        var needed = ["nvfb=1", "nvaccel=1", "nvfbheads=4", "-nvkmsnosmooth"].filter { !args.contains($0) }
        if facts.kextLoaded("WhateverGreen") && !args.contains("gfxrst=4") { needed.append("gfxrst=4") }
        return needed
    }

    public static func check(_ facts: SystemFacts) -> [Finding] {
        guard let card = card(facts) else { return [] }
        let status = facts.nullMoth
        let args = tokens(facts)
        let version = facts.kexts["com.nullmoth.NVRM"]
        let conflict = conflicts.filter(args.contains)
        var out: [Finding] = []

        guard card.device >= firstSupportedDevice else {
            return [Finding("nv-old", .graphics, .warning, "This NVIDIA card is too old for the NullMoth driver",
                            "The driver supports GTX 16 and newer, and yours is an older model (\(card.idString)). Older cards use a different route.")]
        }
        if !["15", "26"].contains(String(facts.macOSMajor)) {
            out.append(Finding("nv-os", .graphics, .warning, "This macOS version isn't supported by the NVIDIA driver",
                               "NullMoth's driver supports macOS 15 and 26 only."))
        }

        if status.removalPending {
            out.append(Finding("nv-removal", .graphics, .warning, "The NVIDIA driver is set to be removed",
                               "A removal request is waiting, so the driver stays off. If that wasn't on purpose, use the 1401 app.", fixes: ["nv-get-help"]))
        }
        if !conflict.isEmpty {
            out.append(Finding("nv-conflict", .graphics, .problem, "A setting is turning off your NVIDIA card",
                               "Your boot arguments include \(conflict.joined(separator: ", ")), which keeps the driver from using the card.",
                               fixes: [facts.config == nil ? "mount-efi" : "nv-remove-conflicts"]))
        }

        guard let version else {
            if conflict.isEmpty && !status.removalPending {
                out.append(Finding("nv-none", .graphics, .warning, "Your NVIDIA card isn't using a driver",
                                   "macOS doesn't include a driver for this card (\(card.idString)). NullMoth's free driver may add acceleration, and laptops can still have problems. Its own 1401 app installs it and can remove it again.",
                                   fixes: ["nv-get-driver"]))
            }
            return out
        }

        out.append(Finding("nv-ok", .graphics, .ok, "NVIDIA driver is running", "NullMoth driver \(version)."))
        if let disk = status.diskVersion, disk != version {
            out.append(Finding("nv-restart", .graphics, .warning, "Restart to finish the driver update",
                               "Version \(disk) is installed, but \(version) is still running."))
        }
        if let latest = status.latestVersion, isNewer(latest, than: version) {
            out.append(Finding("nv-update", .graphics, .info, "A newer NVIDIA driver is available",
                               "You have \(version), and \(latest) is out. Update it with the 1401 app.", fixes: ["nv-get-driver"]))
        }
        if !status.driverFilesPresent {
            out.append(Finding("nv-files", .graphics, .problem, "Parts of the NVIDIA driver are missing",
                               "Some of its graphics files aren't where they should be. Reinstall it with the 1401 app.", fixes: ["nv-get-driver"]))
        }

        let missing = missingArguments(facts)
        if !missing.isEmpty {
            out.append(Finding("nv-args", .graphics, .warning, "The NVIDIA driver is missing some settings",
                               "It needs \(missing.joined(separator: ", ")) in your boot arguments.\(missing.contains("gfxrst=4") ? " Without gfxrst=4, your Mac can crash when WhateverGreen is loaded." : "")",
                               fixes: [facts.config == nil ? "mount-efi" : "nv-add-args"]))
        }
        if !["amfi_get_out_of_my_way=0x1", "amfi=0x80", "ipc_control_port_options=0"].allSatisfy(args.contains) {
            out.append(Finding("nv-security-args", .graphics, .warning, "The NVIDIA driver may not get graphics acceleration",
                               "Some security-related boot arguments it needs are missing. They lower your Mac's security, so this app doesn't add them. The 1401 app can set them up.", fixes: ["nv-get-driver"]))
        }
        if let config = facts.config, ((config.root["Misc"] as? NSDictionary)?["Security"] as? NSDictionary)?["SecureBootModel"] as? String != "Disabled" {
            out.append(Finding("nv-secureboot", .graphics, .warning, "Secure Boot should be off for the NVIDIA driver",
                               "The driver's guide asks for SecureBootModel to be Disabled.", fixes: ["nv-secureboot"]))
        }
        if args.contains("-nvrmnopm") {
            out.append(Finding("nv-nopm", .graphics, .warning, "Sleep support is turned off for your graphics card",
                               "If this Mac sleeps with this setting on, the graphics card won't come back.",
                               fixes: [facts.config == nil ? "mount-efi" : "nv-allow-sleep"]))
        }
        if let power = status.powerState, power.lowercased().contains("lost") {
            out.append(Finding("nv-lost", .graphics, .problem, "The graphics card didn't come back from sleep",
                               "Restart your Mac. If it keeps happening, send logs from the 1401 app so the developer can look into it.", fixes: ["nv-get-help"]))
        }
        if let starts = status.startFailures, starts >= 2 {
            out.append(Finding("nv-guard", .graphics, .warning, "The NVIDIA driver failed to start more than once",
                               "It has a safety limit, and repeated failed starts can make it stay off.", fixes: ["nv-get-help"]))
        }
        if let list = status.allowList {
            if let mode = status.allowListMode, mode & 0o004 == 0 {
                out.append(Finding("nv-allow-mode", .graphics, .problem, "A driver file has the wrong permissions",
                                   "The display system can't read the NVIDIA driver's allow-list, which can cause repeated display crashes. Reinstall the driver with the 1401 app.", fixes: ["nv-get-driver"]))
            }
            if access(for: "WindowServer", allowList: list) == .denied {
                out.append(Finding("nv-allow-denied", .graphics, .problem, "The display system is blocked from using your graphics card",
                                   "The NVIDIA driver's allow-list doesn't let WindowServer use the card. Reinstall the driver with the 1401 app. This app won't edit that file, because a mistake can crash the display.", fixes: ["nv-get-driver"]))
            }
        }

        out.append(Finding("nv-flicker", .graphics, .info, "Does your screen flicker when the cursor moves?",
                           "This setting is the first thing the driver's guide says to try. Skip it if your screen looks fine.",
                           fixes: [args.contains("-nvrmnoflip") ? "nv-get-help" : (facts.config == nil ? "mount-efi" : "nv-flicker")]))
        out.append(Finding("nv-icons", .graphics, .info, "Slow or blurry icons are a known driver issue",
                           "Other people report this too, and the developer hasn't confirmed a fix. This app won't change driver files to try one.", fixes: ["nv-icon-help"]))
        return out
    }

    public static func fixes(facts: SystemFacts) -> [Fix] {
        let missing = missingArguments(facts)
        let conflict = conflicts.filter(tokens(facts).contains)
        return [
            Fix(id: "nv-get-driver", title: "Get the 1401 App", summary: "1401 is NullMoth's own installer. It installs, updates and removes the driver, and backs up your config first.", needsRestart: false,
                kind: .guided(steps: [
                    "Open the official releases page, and download the 1401 .dmg for Mac.",
                    "Read what it will change, then follow its steps.",
                    "Scan again here when you're done.",
                ], link: releasesURL)),
            Fix(id: "nv-get-help", title: "Get Help", summary: "The driver's guide covers this, and the 1401 app can send logs to the developer if you choose to.", needsRestart: false,
                kind: .guided(steps: [
                    "Open the driver's troubleshooting guide.",
                    "If that doesn't solve it, use Send logs in the 1401 app.",
                ], link: troubleshootingURL)),
            Fix(id: "nv-icon-help", title: "Read About This Issue", summary: "The developer hasn't confirmed a fix yet.", needsRestart: false,
                kind: .guided(steps: ["Check the issue for updates.", "Keep your driver up to date. Later versions have improved some icon drawing."], link: iconIssueURL)),
            Fix(id: "nv-add-args", title: "Add Missing Settings", summary: "Adds the boot arguments the NVIDIA driver needs: \(missing.joined(separator: ", ")).",
                kind: .automatic { _ in FixPlan(edits: missing.map { .addBootArg($0) } + [.addNVRAMDelete(guid: OpenCoreConfig.bootArgsGUID, name: "boot-args")]) }),
            Fix(id: "nv-remove-conflicts", title: "Remove Blocking Settings", summary: "Removes the boot arguments keeping the driver off: \(conflict.joined(separator: ", ")).", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: conflict.map { .removeBootArg($0.split(separator: "=").first.map(String.init) ?? $0) } + [.addNVRAMDelete(guid: OpenCoreConfig.bootArgsGUID, name: "boot-args")]) }),
            Fix(id: "nv-secureboot", title: "Turn Off Secure Boot", summary: "Sets SecureBootModel to Disabled, as the driver's guide asks. This lowers startup security.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.setString(section: ["Misc", "Security"], key: "SecureBootModel", value: "Disabled")]) }),
            Fix(id: "nv-allow-sleep", title: "Turn Sleep Support Back On", summary: "Removes -nvrmnopm, so the graphics card can handle sleep. Sleep has only been tested on some cards.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.removeBootArg("-nvrmnopm"), .addNVRAMDelete(guid: OpenCoreConfig.bootArgsGUID, name: "boot-args")]) }),
            Fix(id: "nv-flicker", title: "Try the Flicker Fix", summary: "Adds -nvrmnoflip, which draws the screen a slower, steadier way. You can undo it from Backups.", risk: .medium,
                kind: .automatic { _ in FixPlan(edits: [.addBootArg("-nvrmnoflip"), .addNVRAMDelete(guid: OpenCoreConfig.bootArgsGUID, name: "boot-args")]) }),
        ]
    }

    // MARK: Reading this Mac

    static let bootGUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"

    static func scan() -> Status {
        var status = Status()
        let fm = FileManager.default
        let kextPlist = "/Library/Extensions/NVRM.kext/Contents/Info.plist"
        if let data = fm.contents(atPath: kextPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            status.diskVersion = plist["CFBundleShortVersionString"] as? String
        }
        let listPath = "/Library/GPUBundles/nvmtl-allow.txt"
        if fm.fileExists(atPath: listPath) {
            status.allowList = try? String(contentsOfFile: listPath, encoding: .utf8)
            status.allowListMode = (try? fm.attributesOfItem(atPath: listPath))?[.posixPermissions] as? Int
        }
        status.driverFilesPresent = ["NVMTLDriver.bundle", "NVIDIAShared.bundle", "nvmtl"].allSatisfy { fm.fileExists(atPath: "/Library/GPUBundles/\($0)") }
        status.startFailures = SystemScanner.nvram("\(bootGUID):nullmoth-nv-starts").flatMap(parseCount)
        status.removalPending = SystemScanner.nvram("\(bootGUID):nullmoth-remove") != nil
        status.powerState = parsePowerState(Shell.run("/usr/sbin/ioreg", ["-l", "-w0"], timeout: 15, includeErrors: false).output)
        status.latestVersion = parseLatest(Shell.run("/usr/bin/curl", ["-sS", "-m", "5", "-H", "User-Agent: HackintoshSimplified",
                                                                       "https://api.github.com/repos/nullmoth/nvidia-macos-driver/releases/latest"], timeout: 8, includeErrors: false).output)
        return status
    }

    /// NVRAM prints a count either as text or as percent-escaped bytes.
    public static func parseCount(_ text: String) -> Int? {
        if let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
        if text.hasPrefix("%"), let value = Int(text.dropFirst().prefix(2), radix: 16) { return value }
        return nil
    }

    public static func parsePowerState(_ ioreg: String) -> String? {
        guard let key = ioreg.range(of: "\"nvrm-pm\" = ") else { return nil }
        let rest = ioreg[key.upperBound...]
        return rest.prefix { $0 != "\n" }.trimmingCharacters(in: CharacterSet(charactersIn: "\"<> "))
    }

    public static func parseLatest(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

/// Picks the fixes that are safe to run together, for a person who just wants things sorted out.
public enum FixPlanner {
    /// One fix per problem: automatic, low risk, and needing no choices.
    public static func safeFixes(findings: [Finding], facts: SystemFacts) -> [Fix] {
        var chosen: [Fix] = []
        for finding in findings where finding.status == .problem || finding.status == .warning {
            for id in finding.fixIDs {
                guard id != "mount-efi", let fix = FixCatalog.fix(id: id, facts: facts), case .automatic = fix.kind,
                      fix.risk == .low, fix.parameter == nil else { continue }
                if !chosen.contains(where: { $0.id == fix.id }) { chosen.append(fix) }
                break
            }
        }
        return chosen
    }

    public static func combined(_ fixes: [Fix]) -> Fix {
        let restart = fixes.contains(where: \.needsRestart)
        return Fix(id: "fix-all", title: fixes.count == 1 ? "Fix 1 Problem" : "Fix \(fixes.count) Problems",
                   summary: "These are the safe fixes for what the scan found. Riskier fixes stay separate, so you can decide on those yourself.",
                   needsRestart: restart,
                   kind: .automatic { _ in
                       var plan = FixPlan()
                       for fix in fixes {
                           guard case .automatic(let build) = fix.kind else { continue }
                           let part = try build(nil)
                           plan.kexts += part.kexts.filter { !plan.kexts.contains($0) }
                           plan.edits += part.edits.filter { !plan.edits.contains($0) }
                           plan.commands += part.commands.filter { !plan.commands.contains($0) }
                       }
                       return plan
                   })
    }
}
