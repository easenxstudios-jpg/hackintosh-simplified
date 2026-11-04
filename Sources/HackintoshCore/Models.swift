import Foundation

public enum Status: Int, Comparable, Sendable {
    case problem, warning, unknown, info, ok

    public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .problem: return "Problem"
        case .warning: return "Needs attention"
        case .unknown: return "Couldn't check"
        case .info: return "Good to know"
        case .ok: return "Working"
        }
    }
}

public enum Area: String, CaseIterable, Identifiable, Sendable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth"
    case continuity = "AirDrop & Continuity"
    case sound = "Sound"
    case usb = "USB"
    case graphics = "Graphics"
    case ethernet = "Ethernet"
    case clock = "Date & Time"
    case power = "Power & Input"
    case boot = "Boot Setup"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .bluetooth: return "wave.3.right"
        case .continuity: return "iphone.and.arrow.forward"
        case .sound: return "speaker.wave.2"
        case .usb: return "cable.connector"
        case .graphics: return "display"
        case .ethernet: return "network"
        case .clock: return "clock"
        case .power: return "battery.75"
        case .boot: return "externaldrive"
        }
    }
}

public struct Finding: Identifiable, Sendable {
    public let id: String
    public let category: Area
    public let status: Status
    public let title: String
    public let detail: String
    public let fixIDs: [String]

    public init(_ id: String, _ category: Area, _ status: Status, _ title: String, _ detail: String, fixes: [String] = []) {
        self.id = id
        self.category = category
        self.status = status
        self.title = title
        self.detail = detail
        self.fixIDs = fixes
    }
}

public struct PCIDevice: Equatable, Sendable {
    public var name: String
    public var vendor: Int
    public var device: Int
    public var classCode: Int

    public init(name: String, vendor: Int, device: Int, classCode: Int) {
        self.name = name
        self.vendor = vendor
        self.device = device
        self.classCode = classCode
    }

    public var idString: String { String(format: "%04x:%04x", vendor, device) }
}

public struct USBDevice: Equatable, Sendable {
    public var name: String
    public var vendorName: String
    public var vendor: Int
    public var product: Int
    public var megabits: Double

    public init(name: String, vendorName: String, vendor: Int, product: Int, megabits: Double) {
        self.name = name
        self.vendorName = vendorName
        self.vendor = vendor
        self.product = product
        self.megabits = megabits
    }
}

public struct NetworkInterface: Equatable, Sendable {
    public var port: String
    public var device: String
    public var ipv4: String?
    public var active: Bool
    public var media: String

    public init(port: String, device: String, ipv4: String?, active: Bool, media: String) {
        self.port = port
        self.device = device
        self.ipv4 = ipv4
        self.active = active
        self.media = media
    }
}

public struct AudioOutput: Equatable, Sendable {
    public var name: String
    public var source: String
    public var builtIn: Bool

    public init(name: String, source: String, builtIn: Bool) {
        self.name = name
        self.source = source
        self.builtIn = builtIn
    }
}

public struct GPU: Equatable, Sendable {
    public var name: String
    public var hasMetal: Bool

    public init(name: String, hasMetal: Bool) {
        self.name = name
        self.hasMetal = hasMetal
    }
}

/// Everything a scan reads. Filled by `SystemScanner`, and by hand in tests.
public struct SystemFacts: @unchecked Sendable {
    public var osVersion = ""
    public var osBuild = ""
    public var model = ""
    public var cpu = ""
    public var kernelVersion = ""
    public var openCoreVersion: String?
    public var bootArgs = ""
    public var sipEnabled: Bool?
    public var pci: [PCIDevice] = []
    public var usb: [USBDevice] = []
    public var interfaces: [NetworkInterface] = []
    public var hasAWDL = false
    public var audioOutputs: [AudioOutput] = []
    public var bluetoothState: String?
    public var bluetoothChipset: String?
    public var bluetoothTransport: String?
    public var gpus: [GPU] = []
    public var kexts: [String: String] = [:]
    public var timeZone = ""
    public var clockOffsetSeconds: Double?
    public var hibernateMode: Int?
    public var hasBattery = false
    public var efiDevice: String?
    public var efiMountPoint: String?
    public var config: OpenCoreConfig?
    public var nullMoth = NullMothDoctor.Status()
    public var wifiSpeed: SpeedResult?
    /// False when macOS's hardware report couldn't be read, so missing devices prove nothing.
    public var hardwareReportRead = true

    public init() {}

    public var macOSMajor: Int { Int(osVersion.split(separator: ".").first ?? "") ?? 0 }
    public var isOpenCore: Bool { openCoreVersion != nil }

    public func kextLoaded(_ fragment: String) -> Bool {
        kexts.keys.contains { $0.localizedCaseInsensitiveContains(fragment) }
    }
}

public enum Risk: String, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

public struct KextSpec: Equatable, Sendable {
    public var bundle: String
    /// Kexts that must load first, as bundle names.
    public var after: [String]

    public init(_ bundle: String, after: [String] = []) {
        self.bundle = bundle
        self.after = after
    }
}

public enum KextOrigin: Equatable, Sendable {
    case github(repo: String, kexts: [KextSpec])
    case bundled(folder: String, kexts: [KextSpec])

    public var specs: [KextSpec] {
        switch self {
        case .github(_, let kexts), .bundled(_, let kexts): return kexts
        }
    }
}

public struct FixParameter: Sendable {
    public let label: String
    public let defaultValue: String
    public let help: String

    public init(label: String, defaultValue: String, help: String) {
        self.label = label
        self.defaultValue = defaultValue
        self.help = help
    }
}

public struct FixPlan: Sendable {
    public var edits: [ConfigEdit] = []
    public var kexts: [KextOrigin] = []
    public var commands: [String] = []

    public init(edits: [ConfigEdit] = [], kexts: [KextOrigin] = [], commands: [String] = []) {
        self.edits = edits
        self.kexts = kexts
        self.commands = commands
    }

    public var touchesEFI: Bool { !edits.isEmpty || !kexts.isEmpty }
}

public enum FixKind: Sendable {
    case automatic(@Sendable (_ parameter: String?) throws -> FixPlan)
    case guided(steps: [String], link: String?)
    case unavailable(reason: String)
}

public struct Fix: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let risk: Risk
    public let needsRestart: Bool
    public let parameter: FixParameter?
    public let kind: FixKind

    public init(id: String, title: String, summary: String, risk: Risk = .low, needsRestart: Bool = true,
                parameter: FixParameter? = nil, kind: FixKind) {
        self.id = id
        self.title = title
        self.summary = summary
        self.risk = risk
        self.needsRestart = needsRestart
        self.parameter = parameter
        self.kind = kind
    }
}

public struct FixError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
