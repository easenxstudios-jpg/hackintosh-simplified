import Foundation

/// Reads the state of the machine. Everything here is read-only and needs no password.
/// It skips SPHardwareDataType on purpose, because that holds the serial number.
public enum SystemScanner {
    static let openCoreGUID = "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"

    public static func scan() -> SystemFacts {
        var facts = SystemFacts()
        facts.osVersion = output("/usr/bin/sw_vers", ["-productVersion"])
        facts.osBuild = output("/usr/bin/sw_vers", ["-buildVersion"])
        facts.model = output("/usr/sbin/sysctl", ["-n", "hw.model"])
        facts.cpu = output("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        facts.openCoreVersion = nvram("\(openCoreGUID):opencore-version")
        facts.bootArgs = nvram("boot-args") ?? ""
        facts.sipEnabled = parseSIP(output("/usr/bin/csrutil", ["status"]))
        facts.pci = parsePCI(output("/usr/sbin/ioreg", ["-r", "-c", "IOPCIDevice", "-d", "1", "-l", "-w0"]))
        facts.kexts = parseKexts(Shell.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 30).output)
        facts.hasAWDL = Shell.run("/sbin/ifconfig", ["awdl0"]).succeeded
        facts.timeZone = TimeZone.current.identifier
        facts.clockOffsetSeconds = parseClockOffset(Shell.run("/usr/bin/sntp", ["-t", "3", "time.apple.com"], timeout: 8).output)

        let power = output("/usr/bin/pmset", ["-g"])
        facts.hibernateMode = parseHibernate(power)
        facts.hasBattery = output("/usr/bin/pmset", ["-g", "batt"]).contains("InternalBattery")

        let ports = output("/usr/sbin/networksetup", ["-listallhardwareports"])
        facts.interfaces = parsePorts(ports).map { port, device in
            parseInterface(port: port, device: device, ifconfig: Shell.run("/sbin/ifconfig", [device]).output)
        }

        let json = Shell.run("/usr/sbin/system_profiler",
                             ["-json", "SPAudioDataType", "SPBluetoothDataType", "SPDisplaysDataType", "SPUSBHostDataType"],
                             timeout: 45, includeErrors: false).output
        applyProfiler(json, to: &facts)

        locateEFI(&facts)
        return facts
    }

    static func output(_ path: String, _ arguments: [String]) -> String {
        Shell.run(path, arguments).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nvram(_ name: String) -> String? {
        let result = Shell.run("/usr/sbin/nvram", [name])
        guard result.succeeded, let tab = result.output.firstIndex(of: "\t") else { return nil }
        let value = result.output[result.output.index(after: tab)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func parseSIP(_ text: String) -> Bool? {
        if text.contains("status: enabled.") { return true }
        if text.contains("status: disabled") || text.contains("Custom Configuration") { return false }
        return nil
    }

    /// Reads the output of `ioreg -r -c IOPCIDevice -d 1 -l -w0`. IDs are little-endian hex.
    public static func parsePCI(_ text: String) -> [PCIDevice] {
        var devices: [PCIDevice] = []
        var name: String?
        var vendor: Int?
        var device: Int?
        var classCode: Int?

        func flush() {
            if let name, let vendor, let device {
                let item = PCIDevice(name: name, vendor: vendor, device: device, classCode: classCode ?? 0)
                if !devices.contains(item) { devices.append(item) }
            }
        }

        for line in text.split(separator: "\n") {
            if let marker = line.range(of: "+-o ") {
                flush()
                name = line[marker.upperBound...].components(separatedBy: "  <class").first
                vendor = nil
                device = nil
                classCode = nil
            } else if line.contains("\"vendor-id\" = <") {
                vendor = littleEndianID(line)
            } else if line.contains("\"device-id\" = <") {
                device = littleEndianID(line)
            } else if line.contains("\"class-code\" = <") {
                let bytes = hexBytes(line)
                if bytes.count >= 3 { classCode = bytes[2] << 8 | bytes[1] }
            }
        }
        flush()
        return devices
    }

    private static func hexBytes(_ line: Substring) -> [Int] {
        guard let open = line.range(of: "= <"), let close = line.range(of: ">", range: open.upperBound..<line.endIndex) else { return [] }
        let hex = Array(line[open.upperBound..<close.lowerBound])
        return stride(from: 0, to: hex.count - 1, by: 2).compactMap { Int(String(hex[$0...($0 + 1)]), radix: 16) }
    }

    private static func littleEndianID(_ line: Substring) -> Int? {
        let bytes = hexBytes(line)
        return bytes.count >= 2 ? bytes[1] << 8 | bytes[0] : nil
    }

    public static func parseKexts(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: "([A-Za-z0-9_.\\-]+\\.[A-Za-z0-9_.\\-]+) \\(([^)]+)\\)")
        for line in text.split(separator: "\n") {
            let string = String(line)
            guard let match = pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                  let id = Range(match.range(at: 1), in: string),
                  let version = Range(match.range(at: 2), in: string) else { continue }
            result[String(string[id])] = String(string[version])
        }
        return result
    }

    public static func parseClockOffset(_ text: String) -> Double? {
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.count >= 3, words[1] == "+/-", let value = Double(words[0]) { return value }
        }
        return nil
    }

    public static func parseHibernate(_ text: String) -> Int? {
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2, words[0] == "hibernatemode" { return Int(words[1]) }
        }
        return nil
    }

    public static func parsePorts(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var port: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") {
                port = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let current = port {
                result.append((current, String(line.dropFirst("Device: ".count))))
                port = nil
            }
        }
        return result
    }

    public static func parseInterface(port: String, device: String, ifconfig: String) -> NetworkInterface {
        var ipv4: String?
        var active = false
        var media = ""
        for raw in ifconfig.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("inet ") {
                ipv4 = line.split(separator: " ").dropFirst().first.map(String.init)
            } else if line.hasPrefix("status: ") {
                active = line.hasSuffix("active") && !line.hasSuffix("inactive")
            } else if line.hasPrefix("media: ") {
                media = String(line.dropFirst("media: ".count))
            }
        }
        return NetworkInterface(port: port, device: device, ipv4: ipv4, active: active, media: media)
    }

    public static func applyProfiler(_ json: String, to facts: inout SystemFacts) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            facts.hardwareReportRead = false
            return
        }

        for group in root["SPAudioDataType"] as? [[String: Any]] ?? [] {
            for item in group["_items"] as? [[String: Any]] ?? [] where item["coreaudio_device_output"] != nil {
                facts.audioOutputs.append(AudioOutput(
                    name: item["_name"] as? String ?? "Output",
                    source: item["coreaudio_output_source"] as? String ?? "",
                    builtIn: (item["coreaudio_device_transport"] as? String ?? "").contains("builtin")))
            }
        }

        if let bluetooth = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
           let controller = bluetooth["controller_properties"] as? [String: Any] {
            facts.bluetoothState = controller["controller_state"] as? String
            facts.bluetoothChipset = controller["controller_chipset"] as? String
            facts.bluetoothTransport = controller["controller_transport"] as? String
        }

        for display in root["SPDisplaysDataType"] as? [[String: Any]] ?? [] {
            let name = display["_name"] as? String ?? display["sppci_model"] as? String ?? "Graphics card"
            let metal = display["spdisplays_mtlgpufamilysupport"] as? String ?? display["spdisplays_metal"] as? String
            facts.gpus.append(GPU(name: name, hasMetal: metal != nil && metal != "spdisplays_notsupported"))
        }

        func walk(_ value: Any) {
            if let list = value as? [Any] { list.forEach(walk); return }
            guard let item = value as? [String: Any] else { return }
            if let vendor = item["USBDeviceKeyVendorID"] as? String, let product = item["USBDeviceKeyProductID"] as? String {
                facts.usb.append(USBDevice(
                    name: item["_name"] as? String ?? "USB device",
                    vendorName: item["USBDeviceKeyVendorName"] as? String ?? "",
                    vendor: Int(vendor.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0,
                    product: Int(product.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0,
                    megabits: parseLinkSpeed(item["USBDeviceKeyLinkSpeed"] as? String ?? "")))
            }
            if let children = item["_items"] { walk(children) }
        }
        if let usb = root["SPUSBHostDataType"] { walk(usb) }
    }

    public static func parseLinkSpeed(_ text: String) -> Double {
        let words = text.split(separator: " ")
        guard words.count >= 2, let value = Double(words[0]) else { return 0 }
        return words[1].hasPrefix("G") ? value * 1000 : value
    }

    public static func partitionGUID(bootPath: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "GPT,([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})")
        guard let match = pattern.firstMatch(in: bootPath, range: NSRange(bootPath.startIndex..., in: bootPath)),
              let range = Range(match.range(at: 1), in: bootPath) else { return nil }
        return String(bootPath[range])
    }

    /// Finds the EFI partition OpenCore actually booted from. It never guesses from the disk list,
    /// because a machine can have several and the wrong one could belong to another system.
    static func locateEFI(_ facts: inout SystemFacts) {
        guard let path = nvram("\(openCoreGUID):boot-path"), let guid = partitionGUID(bootPath: path) else { return }
        let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", guid])
        guard info.succeeded, let data = info.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        facts.efiDevice = plist["DeviceIdentifier"] as? String
        if let mount = plist["MountPoint"] as? String, !mount.isEmpty {
            facts.efiMountPoint = mount
            facts.config = try? OpenCoreConfig(contentsOf: EFIPaths(mountPoint: URL(fileURLWithPath: mount)).config)
        }
    }

    /// Plain-text report for support questions. MAC addresses are removed, and it holds no serial number.
    public static func report(facts: SystemFacts, findings: [Finding]) -> String {
        var lines = [
            "Hackintosh Simplified report",
            "macOS \(facts.osVersion) (\(facts.osBuild)), \(facts.model), \(facts.cpu)",
            "OpenCore: \(facts.openCoreVersion ?? "not detected")",
            "",
        ]
        for category in Area.allCases {
            let items = findings.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            lines.append("== \(category.rawValue)")
            for item in items.sorted(by: { $0.status < $1.status }) {
                lines.append("[\(item.status.label)] \(item.title)")
                lines.append("    \(item.detail)")
            }
            lines.append("")
        }
        lines.append("PCI: " + facts.pci.filter { [0x0280, 0x0200, 0x0300, 0x0302, 0x0403].contains($0.classCode) }
            .map { "\($0.name) \($0.idString)" }.joined(separator: ", "))
        lines.append("USB: " + facts.usb.map { "\($0.name) \(String(format: "%04x:%04x", $0.vendor, $0.product)) \($0.megabits) Mb/s" }.joined(separator: ", "))
        return redact(lines.joined(separator: "\n"))
    }

    public static func redact(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}", with: "<address>", options: .regularExpression)
        for word in [NSUserName(), NSFullUserName(), Host.current().localizedName ?? ""] where word.count >= 3 {
            result = result.replacingOccurrences(of: word, with: "<name>", options: .caseInsensitive)
        }
        return result
    }
}
