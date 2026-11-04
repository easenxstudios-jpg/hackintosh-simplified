import Foundation

/// Turns scan facts into findings. Pure, so every rule can be tested without the hardware.
public enum Checks {
    public static func run(_ facts: SystemFacts) -> [Finding] {
        var findings: [Finding] = []
        findings += boot(facts)
        findings += wifi(facts)
        findings += bluetooth(facts)
        findings += continuity(facts)
        findings += sound(facts)
        findings += usb(facts)
        findings += graphics(facts)
        findings += NullMothDoctor.check(facts)
        findings += ethernet(facts)
        findings += clock(facts)
        findings += power(facts)
        return findings
    }

    private static func unreadable(_ id: String, _ area: Area) -> Finding {
        Finding(id, area, .unknown, "Couldn't check this", "macOS's hardware report couldn't be read. Scan again in a moment.")
    }

    static func boot(_ f: SystemFacts) -> [Finding] {
        guard let version = f.openCoreVersion else {
            return [Finding("not-opencore", .boot, .warning, "OpenCore wasn't detected",
                            "Changes to boot files are turned off. This app only edits OpenCore setups, and it can't confirm one here.")]
        }
        var out = [Finding("opencore", .boot, .ok, "Started by OpenCore \(version)", "macOS \(f.osVersion) (\(f.osBuild)), set up as \(f.model).")]

        if f.efiDevice == nil {
            out.append(Finding("efi-missing", .boot, .warning, "Couldn't find the boot partition",
                               "OpenCore didn't report which partition it started from, so boot fixes are off. This app won't guess, because editing the wrong disk could stop another system starting."))
        } else if f.config == nil {
            let mounted = f.efiMountPoint != nil
            out.append(Finding("efi-closed", .boot, mounted ? .warning : .info,
                               mounted ? "Couldn't read config.plist" : "Boot partition isn't open",
                               mounted ? "The boot partition is open, but config.plist couldn't be read." : "Open it so the scan can also check your OpenCore settings.",
                               fixes: mounted ? [] : ["mount-efi"]))
        }

        if let config = f.config, let mount = f.efiMountPoint {
            out += ConfigDoctor.check(config: config, paths: EFIPaths(mountPoint: URL(fileURLWithPath: mount)), kernel: f.kernelVersion)
            if config.kernelQuirk("XhciPortLimit") == true && f.macOSMajor >= 11 {
                out.append(Finding("xhci-limit", .usb, .warning, "XhciPortLimit is on",
                                   "This OpenCore setting doesn't work properly on current macOS versions and can cause USB problems. A USB map is the replacement.",
                                   fixes: ["xhci-off"]))
            }
            if config.bootArgs.contains("-v") {
                out.append(Finding("verbose", .boot, .info, "Startup shows text instead of the Apple logo",
                                   "Verbose mode is on. It's useful for troubleshooting, and you can turn it off when things are stable.",
                                   fixes: ["verbose-off"]))
            }
        }

        if f.sipEnabled == false {
            out.append(Finding("sip", .boot, .info, "System Integrity Protection is partly off",
                               "Some hackintosh drivers need this, but it lowers your Mac's security. This app doesn't change it."))
        }
        if ["amfi=", "amfi_get_out_of_my_way"].contains(where: { f.bootArgs.contains($0) }) {
            out.append(Finding("amfi", .boot, .info, "Code signature checks are relaxed",
                               "Your boot arguments relax AMFI, usually for a graphics or Wi-Fi driver. It lowers your Mac's security. This app doesn't change it."))
        }
        return out
    }

    static func wifi(_ f: SystemFacts) -> [Finding] {
        var out: [Finding] = []
        let cards = f.pci.filter { $0.classCode == 0x0280 }
        let interface = f.interfaces.first { $0.port == "Wi-Fi" }

        guard let card = cards.first else {
            if interface != nil {
                out.append(Finding("wifi-usb", .wifi, .info, "Wi-Fi is available", "macOS has a Wi-Fi interface, but no internal card was seen, so it's probably a USB adapter."))
            } else if f.config?.acpiEnabled(pathContains: "Disable_Network") == true {
                out.append(Finding("wifi-hidden", .wifi, .problem, "Your config hides the Wi-Fi card",
                                   "An ACPI table with Disable_Network in its name is turned on, so macOS can't see the card.",
                                   fixes: ["show-network-card"]))
            } else {
                out.append(Finding("wifi-none", .wifi, .warning, "No Wi-Fi card found",
                                   "macOS can't see a Wi-Fi card. It may be turned off by an ACPI table or a USB map, or this machine may not have one."))
            }
            return out
        }

        let label = "\(card.name), \(card.idString)"
        guard let interface else {
            let fix: String
            switch card.vendor {
            case 0x8086: fix = "wifi-intel"
            case 0x14e4: fix = "wifi-broadcom"
            case 0x10ec: fix = "wifi-realtek"
            default: fix = "wifi-unsupported"
            }
            out.append(Finding("wifi-driver", .wifi, .problem, "Wi-Fi card has no working driver", "macOS can see the card (\(label)) but no driver is running it.", fixes: [fix]))
            return out
        }

        out.append(WiFiSpeed.finding(f, label: label, interface: interface))

        if let wired = f.interfaces.first(where: { $0.port != "Wi-Fi" && $0.ipv4 != nil && $0.active }), let wifiIP = interface.ipv4,
           subnet(wifiIP) == subnet(wired.ipv4 ?? "") {
            out.append(Finding("dual-network", .wifi, .warning, "Wi-Fi and \(wired.port) are both on the same network",
                               "Other devices may reach this Mac through the slower connection. On one tested Mac, iPhone AirPlay chose weak Wi-Fi and dropped to a few frames until Wi-Fi was turned off.",
                               fixes: ["single-network"]))
        }
        return out
    }

    private static func subnet(_ ip: String) -> String {
        ip.split(separator: ".").prefix(3).joined(separator: ".")
    }

    static func bluetooth(_ f: SystemFacts) -> [Finding] {
        guard f.hardwareReportRead else { return [unreadable("bt-unknown", .bluetooth)] }
        let radio = f.usb.first { $0.name.localizedCaseInsensitiveContains("bluetooth") || $0.vendor == 0x8087 }
        let working = f.bluetoothState == "attrib_on" && f.bluetoothChipset != nil && f.bluetoothChipset != "NULL"
        let isRealtek = radio?.vendorName.localizedCaseInsensitiveContains("realtek") == true
        var out: [Finding] = []

        if working {
            out.append(Finding("bt-ok", .bluetooth, .ok, "Bluetooth is on", "Chip: \(f.bluetoothChipset ?? "unknown"), connected by \(f.bluetoothTransport ?? "unknown")."))
            if isRealtek {
                out.append(Finding("bt-realtek-le", .bluetooth, .warning, "Realtek Bluetooth has limits",
                                   "Headphones and other Classic Bluetooth devices can work. On one tested RTL8852C, the chip rejected every LE scan, which affects LE devices. Pairing from Settings also failed there, while a direct connection worked.",
                                   fixes: ["bt-connect-help"]))
            }
            if isRealtek && f.osBuild != FixCatalog.realtekPatchedBuild {
                out.append(Finding("bt-realtek-build", .bluetooth, .info, "Check Bluetooth after macOS updates",
                                   "Realtek Bluetooth patches only match one macOS build. If yours stopped working after an update, they need rebuilding for \(f.osBuild)."))
            }
            return out
        }

        var fixes: [String] = []
        if let radio {
            if isRealtek {
                fixes = radio.product == 0x3612 && radio.vendor == 0x13d3 && f.osBuild == FixCatalog.realtekPatchedBuild
                    ? ["bt-realtek-patched"] : ["bt-realtek"]
            } else if radio.vendor == 0x8087 || radio.vendorName.localizedCaseInsensitiveContains("intel") {
                fixes = ["bt-intel"]
            } else if radio.vendor == 0x0a5c || radio.vendorName.localizedCaseInsensitiveContains("broadcom") {
                fixes = ["bt-broadcom"]
            } else {
                fixes = ["bt-unsupported"]
            }
            out.append(Finding("bt-off", .bluetooth, .problem, "Bluetooth isn't working",
                               "macOS can see \(radio.name) (\(radio.vendorName)) on USB, but Bluetooth isn't running.", fixes: fixes))
        } else {
            out.append(Finding("bt-none", .bluetooth, .problem, "No Bluetooth chip found",
                               "Bluetooth usually appears as a USB device. If this machine has one, a USB map is probably hiding its port.", fixes: ["usb-map"]))
        }
        return out
    }

    static func continuity(_ f: SystemFacts) -> [Finding] {
        guard f.hasAWDL else {
            let card = f.pci.first { $0.classCode == 0x0280 }
            let vendor = card?.vendor
            let fix = vendor == 0x14e4 ? "wifi-broadcom" : "continuity-unavailable"
            return [Finding("airdrop", .continuity, .problem, "AirDrop can't work right now",
                            "AirDrop needs a direct Wi-Fi link (awdl0), and it doesn't exist here. Wi-Fi being off can cause this, but community Intel and Realtek drivers don't provide it at all, so a settings fix won't help.",
                            fixes: [fix])]
        }
        return [Finding("airdrop", .continuity, .ok, "AirDrop link is available", "The direct Wi-Fi link (awdl0) exists. Test AirDrop with another device to confirm it works.")]
    }

    static func sound(_ f: SystemFacts) -> [Finding] {
        guard f.hardwareReportRead else { return [unreadable("sound-unknown", .sound)] }
        let builtIn = f.audioOutputs.filter { $0.builtIn }
        let nullMothAudio = f.kextLoaded("NMXAudio")
        let controller = f.pci.first { $0.classCode == 0x0403 && $0.vendor == 0x8086 }
        if builtIn.isEmpty {
            var fixes: [String] = []
            if f.macOSMajor >= 26 && !f.kextLoaded("SimpleHDA") && !nullMothAudio { fixes.append("sound-simplehda") }
            if !f.kextLoaded("AppleALC") { fixes.append("sound-applealc") }
            if !nullMothAudio { fixes.append("sound-layout") }
            let reason = nullMothAudio
                ? "NullMoth's audio driver is running, but macOS doesn't list a built-in output. Check Sound settings, then restart."
                : f.macOSMajor >= 26
                ? "macOS Tahoe removed Apple's built-in driver for this kind of audio chip, so AppleALC alone no longer works and SimpleHDA is needed as well."
                : "No built-in audio output is available."
            return [Finding("sound-none", .sound, .problem, "No built-in sound", reason + (controller == nil ? " No Intel audio controller was seen either." : ""), fixes: fixes)]
        }
        let names = builtIn.map(\.name).joined(separator: ", ")
        let hasSpeakers = builtIn.contains { $0.source.localizedCaseInsensitiveContains("speaker") || $0.name.localizedCaseInsensitiveContains("speaker") || $0.name.localizedCaseInsensitiveContains("internal") }
        var out: [Finding] = []
        if !hasSpeakers && f.hasBattery {
            out.append(Finding("sound-speakers", .sound, .warning, "Laptop speakers aren't listed",
                               "Only \(names) is available." + (nullMothAudio ? " Check Sound settings, and follow NullMoth's guide if they stay missing." : " A different audio layout usually fixes this."),
                               fixes: nullMothAudio ? ["nv-get-help"] : ["sound-layout"]))
        } else if nullMothAudio {
            out.append(Finding("sound-ok", .sound, .ok, "Sound is available", "Outputs: \(names). NullMoth's audio driver is running them. This app can't hear them, so play a sound to check."))
        } else {
            let layout = f.config?.layoutID.map { " Audio layout \($0)." } ?? ""
            out.append(Finding("sound-ok", .sound, .ok, "Sound is available", "Outputs: \(names).\(layout) If there's no sound, try another layout.", fixes: ["sound-layout"]))
        }
        if nullMothAudio && f.kextLoaded("SimpleHDA") {
            out.append(Finding("sound-two-drivers", .sound, .info, "Two audio drivers are running",
                               "NullMoth's audio driver and SimpleHDA are both loaded. If your sound works, you can leave this alone. If it's glitchy or missing, turning SimpleHDA off in your OpenCore config is the first thing to try."))
        }
        return out
    }

    static func usb(_ f: SystemFacts) -> [Finding] {
        guard f.hardwareReportRead else { return [unreadable("usb-unknown", .usb)] }
        guard !f.usb.isEmpty else {
            return [Finding("usb-none", .usb, .warning, "No USB devices listed", "That's unusual, and it may mean the USB ports aren't mapped.", fixes: ["usb-map"])]
        }
        let fastest = f.usb.map(\.megabits).max() ?? 0
        if fastest >= 5000 {
            return [Finding("usb-ok", .usb, .ok, "USB 3 is working", "A device is connected at \(fastest / 1000) Gb/s.")]
        }
        return [Finding("usb-slow", .usb, .warning, "Nothing is running at USB 3 speed",
                        "The fastest device is at \(fastest) Mb/s. If you have a USB 3 device connected, your ports probably need a USB map. Adapters and USB 2 cables can also cause this.",
                        fixes: ["usb-map"])]
    }

    static func graphics(_ f: SystemFacts) -> [Finding] {
        guard f.hardwareReportRead else { return [unreadable("gpu-unknown", .graphics)] }
        guard !f.gpus.isEmpty else {
            return [Finding("gpu-none", .graphics, .unknown, "Graphics information wasn't available", "macOS didn't report a graphics card.")]
        }
        var out: [Finding] = []
        for gpu in f.gpus {
            if gpu.hasMetal {
                out.append(Finding("gpu-\(gpu.name)", .graphics, .ok, "Graphics acceleration is on", "\(gpu.name) supports Metal."))
            } else {
                out.append(Finding("gpu-\(gpu.name)", .graphics, .problem, "No graphics acceleration", "\(gpu.name) has no Metal support, so the Mac will feel slow.",
                                   fixes: [gpu.name.localizedCaseInsensitiveContains("nvidia") ? "nv-get-driver" : "gpu-whatevergreen"]))
            }
        }
        return out
    }

    static func ethernet(_ f: SystemFacts) -> [Finding] {
        let cards = f.pci.filter { $0.classCode == 0x0200 }
        let interface = f.interfaces.first { $0.port.localizedCaseInsensitiveContains("ethernet") && $0.port != "Wi-Fi" }

        if let interface {
            if interface.active && interface.media.contains("100baseTX") {
                return [Finding("eth-slow", .ethernet, .warning, "Ethernet is limited to 100 Mb/s",
                                "It's connected, but not at gigabit speed. A worn cable, an older router port, or an old switch usually causes this.")]
            }
            return [Finding("eth-ok", .ethernet, interface.active ? .ok : .info,
                            interface.active ? "Ethernet is connected" : "Ethernet is ready", interface.active ? interface.media : "No cable is connected.")]
        }
        guard let card = cards.first else { return [] }

        let fix: String
        switch (card.vendor, card.device) {
        case (0x10ec, 0x8125): fix = "eth-lucy"
        case (0x10ec, _): fix = "eth-rtl8111"
        case (0x8086, 0x15f2), (0x8086, 0x15f3), (0x8086, 0x125b), (0x8086, 0x125c): fix = "eth-i225"
        case (0x8086, _): fix = "eth-intelmausi"
        default: fix = "eth-unknown"
        }
        return [Finding("eth-driver", .ethernet, .problem, "Ethernet has no driver", "macOS can see \(card.name) (\(card.idString)) but no driver is running it.", fixes: [fix])]
    }

    static func clock(_ f: SystemFacts) -> [Finding] {
        guard let offset = f.clockOffsetSeconds else {
            return [Finding("clock-unknown", .clock, .unknown, "Couldn't compare the clock", "The time server didn't answer. Time zone: \(f.timeZone).", fixes: ["time-zone"])]
        }
        if abs(offset) > 60 {
            return [Finding("clock-wrong", .clock, .problem, "The clock is wrong",
                            "It's \(Int(abs(offset))) seconds off. Dual-booting Windows often causes this. Time zone: \(f.timeZone).", fixes: ["time-network", "time-zone"])]
        }
        return [Finding("clock-ok", .clock, .ok, "The clock is correct", "Time zone: \(f.timeZone). If that's wrong, you can change it.", fixes: ["time-zone"])]
    }

    static func power(_ f: SystemFacts) -> [Finding] {
        var out: [Finding] = []
        if let mode = f.hibernateMode, mode != 0 {
            out.append(Finding("hibernate", .power, .warning, "Hibernation is on",
                               "Hackintoshes often fail to wake from hibernation (mode \(mode)). Plain sleep is usually more reliable.", fixes: ["hibernate-off"]))
        }
        if f.hasBattery {
            if f.kextLoaded("VoodooPS2") || f.kextLoaded("VoodooI2C") || f.kextLoaded("VoodooRMI") {
                out.append(Finding("input-ok", .power, .ok, "Keyboard and trackpad drivers are loaded", "A Voodoo input driver is running."))
            } else {
                out.append(Finding("input-none", .power, .warning, "No laptop input driver is loaded",
                                   "This looks like a laptop, but no Voodoo keyboard or trackpad driver is running. If yours work, you can ignore this.", fixes: ["input-voodoops2"]))
            }
            if !f.kextLoaded("SMCBatteryManager") && !f.kextLoaded("ACPIBatteryManager") {
                out.append(Finding("battery-driver", .power, .info, "Battery driver isn't loaded", "Battery percentage may be missing or wrong without SMCBatteryManager.", fixes: ["battery-driver"]))
            }
        }
        return out
    }
}
