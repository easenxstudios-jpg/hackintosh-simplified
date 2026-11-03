import Foundation

public enum ConfigEdit: Equatable, Sendable {
    case addBootArg(String)
    case removeBootArg(String)
    case setLayoutID(Int)
    case addKext(KextEntry)
    case setACPIEnabled(pathContains: String, enabled: Bool)
    case setKernelQuirk(String, Bool)
}

public struct KextEntry: Equatable, Sendable {
    public var bundle: String
    public var executable: String
    public var after: [String]

    public init(bundle: String, executable: String, after: [String] = []) {
        self.bundle = bundle
        self.executable = executable
        self.after = after
    }
}

/// An OpenCore config.plist. Edits keep every value they don't touch, including arrays' order.
public final class OpenCoreConfig: @unchecked Sendable {
    public static let bootArgsGUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    static let defaultAudioPath = "PciRoot(0x0)/Pci(0x1F,0x3)"

    public private(set) var root: NSMutableDictionary

    public init(data: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let value = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: &format)
        guard let root = value as? NSMutableDictionary else { throw FixError("config.plist isn't a dictionary.") }
        self.root = root
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    // MARK: Reading

    private func dict(_ path: String...) -> NSMutableDictionary? {
        var current: NSMutableDictionary? = root
        for key in path { current = current?[key] as? NSMutableDictionary }
        return current
    }

    public var bootArgs: [String] {
        let value = dict("NVRAM", "Add", Self.bootArgsGUID)?["boot-args"] as? String ?? ""
        return value.split(separator: " ").map(String.init)
    }

    private var kernelAdd: NSMutableArray? { dict("Kernel")?["Add"] as? NSMutableArray }
    private var acpiAdd: NSMutableArray? { dict("ACPI")?["Add"] as? NSMutableArray }

    public var enabledKexts: [String] {
        (kernelAdd ?? []).compactMap { item in
            guard let entry = item as? NSDictionary, entry["Enabled"] as? Bool == true else { return nil }
            return entry["BundlePath"] as? String
        }
    }

    public func acpiEnabled(pathContains fragment: String) -> Bool {
        (acpiAdd ?? []).contains { item in
            guard let entry = item as? NSDictionary, let path = entry["Path"] as? String else { return false }
            return path.localizedCaseInsensitiveContains(fragment) && entry["Enabled"] as? Bool == true
        }
    }

    public func kernelQuirk(_ name: String) -> Bool? {
        dict("Kernel", "Quirks")?[name] as? Bool
    }

    public var layoutID: Int? {
        guard let properties = dict("DeviceProperties", "Add") else { return nil }
        for case let device as NSDictionary in properties.allValues {
            // Configs can store this as 4 bytes of data or as a plain number.
            if let data = device["layout-id"] as? Data, data.count == 4 {
                return data.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            }
            if let number = device["layout-id"] as? NSNumber { return number.intValue }
        }
        return nil
    }

    // MARK: Editing

    /// Applies one edit and returns plain descriptions of what changed. Empty means it was already set.
    @discardableResult
    public func apply(_ edit: ConfigEdit) throws -> [String] {
        switch edit {
        case .addBootArg(let argument):
            let key = argument.split(separator: "=").first.map(String.init) ?? argument
            var arguments = bootArgs
            if arguments.contains(argument) { return [] }
            arguments.removeAll { ($0.split(separator: "=").first.map(String.init) ?? $0) == key }
            arguments.append(argument)
            try setBootArgs(arguments)
            return ["Add boot argument \(argument)"]

        case .removeBootArg(let key):
            var arguments = bootArgs
            let count = arguments.count
            arguments.removeAll { ($0.split(separator: "=").first.map(String.init) ?? $0) == key }
            if arguments.count == count { return [] }
            try setBootArgs(arguments)
            return ["Remove boot argument \(key)"]

        case .setLayoutID(let layout):
            guard (1...255).contains(layout) else { throw FixError("Layout has to be a number from 1 to 255.") }
            var changes: [String] = []
            if bootArgs.contains(where: { $0.hasPrefix("alcid=") }) {
                changes += try apply(.removeBootArg("alcid"))
            }
            guard let properties = dict("DeviceProperties", "Add") else {
                throw FixError("This config has no DeviceProperties section.")
            }
            let value = withUnsafeBytes(of: UInt32(layout).littleEndian) { Data($0) }
            var target: NSMutableDictionary?
            var audioDevice: NSMutableDictionary?
            for key in properties.allKeys {
                guard let device = properties[key] as? NSMutableDictionary else { continue }
                if device["layout-id"] != nil { target = device }
                if (key as? String)?.caseInsensitiveCompare(Self.defaultAudioPath) == .orderedSame { audioDevice = device }
            }
            if let target {
                if layoutID == layout { return changes }
                // Keep the stored type, because this config already works with it.
                target["layout-id"] = target["layout-id"] is NSNumber ? NSNumber(value: layout) : value
            } else if let audioDevice {
                audioDevice["layout-id"] = value
            } else {
                properties[Self.defaultAudioPath] = NSMutableDictionary(dictionary: ["layout-id": value])
            }
            return changes + ["Set audio layout to \(layout)"]

        case .addKext(let kext):
            guard let list = kernelAdd else { throw FixError("This config has no Kernel > Add section.") }
            let existing = list.compactMap { $0 as? NSMutableDictionary }
            if let entry = existing.first(where: { $0["BundlePath"] as? String == kext.bundle }) {
                if entry["Enabled"] as? Bool == true { return [] }
                entry["Enabled"] = true
                return ["Turn on \(kext.bundle)"]
            }
            let entry = NSMutableDictionary(dictionary: [
                "Arch": "Any",
                "BundlePath": kext.bundle,
                "Comment": "Added by Hackintosh Simplified",
                "Enabled": true,
                "ExecutablePath": kext.executable,
                "MaxKernel": "",
                "MinKernel": "",
                "PlistPath": "Contents/Info.plist",
            ])
            let positions = kext.after.compactMap { name in
                existing.firstIndex { $0["BundlePath"] as? String == name }
            }
            list.insert(entry, at: (positions.max() ?? (list.count - 1)) + 1)
            return ["Load \(kext.bundle) at startup"]

        case .setACPIEnabled(let fragment, let enabled):
            guard let list = acpiAdd else { throw FixError("This config has no ACPI > Add section.") }
            var changes: [String] = []
            for case let entry as NSMutableDictionary in list {
                guard let path = entry["Path"] as? String, path.localizedCaseInsensitiveContains(fragment),
                      entry["Enabled"] as? Bool != enabled else { continue }
                entry["Enabled"] = enabled
                changes.append("\(enabled ? "Turn on" : "Turn off") \(path)")
            }
            return changes

        case .setKernelQuirk(let name, let enabled):
            guard let quirks = dict("Kernel", "Quirks") else { throw FixError("This config has no Kernel > Quirks section.") }
            if quirks[name] as? Bool == enabled { return [] }
            quirks[name] = enabled
            return ["Set \(name) to \(enabled ? "on" : "off")"]
        }
    }

    private func setBootArgs(_ arguments: [String]) throws {
        guard let section = dict("NVRAM", "Add", Self.bootArgsGUID) else {
            throw FixError("This config has no boot-args section.")
        }
        section["boot-args"] = arguments.joined(separator: " ")
    }
}
