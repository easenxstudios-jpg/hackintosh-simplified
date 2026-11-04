import Foundation

/// A real measurement of this connection, so the app reports results instead of old examples.
public struct SpeedResult: Equatable, Sendable {
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let latencyMs: Double
    public let date: Date

    public init(downloadMbps: Double, uploadMbps: Double, latencyMs: Double, date: Date) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.latencyMs = latencyMs
        self.date = date
    }

    public var isSlow: Bool { downloadMbps < WiFiSpeed.slowBelowMbps }

    public var summary: String {
        String(format: "%.0f Mb/s down, %.0f Mb/s up, %.0f ms latency", downloadMbps, uploadMbps, latencyMs)
    }
}

public enum WiFiSpeed {
    public static let slowBelowMbps = 5.0

    /// The Wi-Fi interface, when it's joined to a network and can be measured.
    public static func testableInterface(_ facts: SystemFacts) -> String? {
        guard let wifi = facts.interfaces.first(where: { $0.port == "Wi-Fi" }), wifi.active, wifi.ipv4 != nil else { return nil }
        return wifi.device
    }

    /// Runs Apple's networkQuality over that interface for a few seconds. It can use tens of MB of data.
    public static func measure(interface: String, seconds: Int = 8) -> SpeedResult? {
        let result = Shell.run("/usr/bin/networkQuality", ["-s", "-c", "-M", String(seconds), "-I", interface],
                               timeout: TimeInterval(seconds * 3 + 15), includeErrors: false)
        return parse(result.output)
    }

    public static func parse(_ json: String, date: Date = Date()) -> SpeedResult? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (root["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (root["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let latency = (root["base_rtt"] as? NSNumber)?.doubleValue ?? 0
        return SpeedResult(downloadMbps: down / 1_000_000, uploadMbps: up / 1_000_000, latencyMs: latency, date: date)
    }

    static func finding(_ f: SystemFacts, label: String, interface: NetworkInterface) -> Finding {
        let preview = f.kextLoaded("rtw89")
        let note = preview ? " AirPort_RTW89 is a preview driver, so speed can change, and AirDrop won't work." : ""
        guard interface.ipv4 != nil else {
            return Finding("wifi-idle", .wifi, .info, preview ? "Wi-Fi is on, using a preview driver" : "Wi-Fi driver is running",
                           "\(label) on \(interface.device). It's not joined to a network, so its speed can't be measured.\(note)")
        }
        guard let speed = f.wifiSpeed else {
            return Finding("wifi-unmeasured", .wifi, .info, "Wi-Fi is connected", "\(label) on \(interface.device). Its speed hasn't been measured yet.\(note)")
        }
        let time = speed.date.formatted(date: .omitted, time: .shortened)
        if speed.isSlow {
            return Finding("wifi-slow", .wifi, .warning, "Wi-Fi is slow right now",
                           "Measured at \(time): \(speed.summary). Try another device at the same moment. If only this Mac is slow, the driver is the likely cause.\(note)",
                           fixes: preview ? ["wifi-realtek-slow"] : [])
        }
        return Finding("wifi-ok", .wifi, .ok, "Wi-Fi is working", "Measured at \(time): \(speed.summary).\(note)")
    }
}
