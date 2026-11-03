import CryptoKit
import Foundation

public struct EFIPaths: Sendable {
    public let root: URL

    public init(mountPoint: URL) { root = mountPoint }

    public var efi: URL { root.appendingPathComponent("EFI", isDirectory: true) }
    public var config: URL { efi.appendingPathComponent("OC/config.plist") }
    public var kexts: URL { efi.appendingPathComponent("OC/Kexts", isDirectory: true) }
}

/// A kext ready to install, with where it came from.
public struct PreparedKext: Identifiable, Sendable {
    public var id: String { spec.bundle }
    public let spec: KextSpec
    public let stagedURL: URL
    public let executable: String
    public let version: String
    public let source: String
    public let sha256: String?
    public let needsLilu: Bool
}

public struct PreparedFix: Sendable {
    public let plan: FixPlan
    public let kexts: [PreparedKext]
    public let changes: [String]
    public let newConfig: Data?
    public let originalConfig: Data?
}

public struct ApplyResult: Sendable {
    public let changes: [String]
    public let backup: URL?
}

public struct BackupEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let date: Date
    public let note: String
}

public final class EFIManager: @unchecked Sendable {
    public let paths: EFIPaths?
    public let backupRoot: URL
    private let runner: PrivilegedRunner
    private let fetcher: KextFetcher

    public static var defaultBackupRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hackintosh Simplified/Backups", isDirectory: true)
    }

    public init(paths: EFIPaths?, backupRoot: URL = EFIManager.defaultBackupRoot,
                runner: PrivilegedRunner = AdminPromptRunner(), fetcher: KextFetcher = KextFetcher()) {
        self.paths = paths
        self.backupRoot = backupRoot
        self.runner = runner
        self.fetcher = fetcher
    }

    /// Downloads what a fix needs and works out its changes. It writes nothing to the EFI.
    public func prepare(_ plan: FixPlan) async throws -> PreparedFix {
        guard plan.touchesEFI else {
            return PreparedFix(plan: plan, kexts: [], changes: plan.commands.map { "Run: \($0)" }, newConfig: nil, originalConfig: nil)
        }
        guard let paths else { throw FixError("The boot partition isn't open. Open it from Boot Setup first.") }
        // OpenCore checks every file against vault.plist, so editing any of them would stop the Mac starting.
        if FileManager.default.fileExists(atPath: paths.efi.appendingPathComponent("OC/vault.plist").path) {
            throw FixError("OpenCore Vault is protecting your boot files, and changing them would stop your Mac starting, so nothing was changed. Follow OpenCore's Vault steps to allow changes.")
        }

        let original = try Data(contentsOf: paths.config)
        let config = try OpenCoreConfig(data: original)
        var changes: [String] = []
        var prepared: [PreparedKext] = []

        for origin in plan.kexts {
            // A kext already on disk is kept, because GitHub's newest release can be older than it.
            // Bundled kexts are the exception: they replace it on purpose.
            var needed: [KextSpec] = []
            for spec in origin.specs {
                if exists(spec.bundle, in: paths) && !forcesReplace(origin) {
                    let current = try KextFetcher.describe(paths.kexts.appendingPathComponent(spec.bundle), spec: spec, source: "already installed", sha256: nil)
                    changes += try config.apply(.addKext(KextEntry(bundle: spec.bundle, executable: current.executable, after: spec.after)))
                } else {
                    needed.append(spec)
                }
            }
            guard !needed.isEmpty else { continue }
            prepared += try await fetcher.fetch(origin, only: needed)
        }

        for kext in prepared {
            changes.append("Install \(kext.spec.bundle) \(kext.version)")
            changes += try config.apply(.addKext(KextEntry(bundle: kext.spec.bundle, executable: kext.executable, after: kext.spec.after)))
        }
        for edit in plan.edits {
            changes += try config.apply(edit)
        }
        changes += plan.commands.map { "Run: \($0)" }

        if prepared.contains(where: \.needsLilu) && !config.enabledKexts.contains("Lilu.kext") {
            throw FixError("A kext in this fix needs Lilu, but Lilu wouldn't be loaded.")
        }
        // Every enabled kext has to exist afterward, or OpenCore can fail to start.
        let staged = Set(prepared.map(\.spec.bundle))
        for bundle in config.enabledKexts where !staged.contains(bundle) && !exists(bundle, in: paths) {
            throw FixError("config.plist lists \(bundle), but that file isn't on the boot partition. Fix that first, because this change wouldn't be safe until it's resolved.")
        }

        let data = try config.serialized()
        _ = try OpenCoreConfig(data: data)
        return PreparedFix(plan: plan, kexts: prepared, changes: changes, newConfig: data, originalConfig: original)
    }

    private func forcesReplace(_ origin: KextOrigin) -> Bool {
        if case .bundled = origin { return true }
        return false
    }

    private func exists(_ bundle: String, in paths: EFIPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.kexts.appendingPathComponent(bundle).path)
    }

    /// Backs up the whole EFI, installs the kexts, then swaps config.plist last, all under one password prompt.
    /// Any failure stops the script before config.plist changes, so OpenCore keeps its working setup.
    public func apply(_ prepared: PreparedFix, fixTitle: String) throws -> ApplyResult {
        var script = ["set -e"]
        var backup: URL?

        if prepared.plan.touchesEFI {
            guard let paths, let newConfig = prepared.newConfig else { throw FixError("The boot partition isn't open.") }
            guard try Data(contentsOf: paths.config) == prepared.originalConfig else {
                throw FixError("config.plist changed after this fix was prepared. Scan again and retry.")
            }

            let stamp = Self.stampFormatter.string(from: Date())
            let target = backupRoot.appendingPathComponent(stamp, isDirectory: true)
            backup = target
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let staged = work.appendingPathComponent("config.plist")
            try newConfig.write(to: staged)
            guard Shell.run("/usr/bin/plutil", ["-lint", staged.path]).succeeded else {
                throw FixError("The new config.plist failed validation, so nothing changed.")
            }
            let note = target.appendingPathComponent("note.txt")

            let q = Shell.quote
            script += [
                "mkdir -p \(q(target.path))",
                "/usr/bin/ditto \(q(paths.efi.path)) \(q(target.appendingPathComponent("EFI").path))",
                "cmp -s \(q(paths.config.path)) \(q(target.appendingPathComponent("EFI/OC/config.plist").path))",
                "printf '%s\\n' \(q("Before: " + fixTitle)) > \(q(note.path))",
                "chown -R \(getuid()) \(q(target.path))",
                "chmod -R go-rwx \(q(target.path))",
            ]
            for kext in prepared.kexts {
                // Copy first and swap after, so a full disk can't leave a listed kext deleted.
                let destination = paths.kexts.appendingPathComponent(kext.spec.bundle).path
                let copy = destination + ".hs-new"
                script += [
                    "rm -rf \(q(copy))",
                    "cp -R \(q(kext.stagedURL.path)) \(q(copy))",
                    "rm -rf \(q(destination))",
                    "mv \(q(copy)) \(q(destination))",
                ]
            }
            let incoming = paths.config.path + ".hs-new"
            script += [
                "cp \(q(staged.path)) \(q(incoming))",
                "cmp -s \(q(staged.path)) \(q(incoming))",
                "mv -f \(q(incoming)) \(q(paths.config.path))",
            ]
            script += prepared.plan.commands
            _ = try runner.run(script: script.joined(separator: "\n") + "\n")
            guard try Data(contentsOf: paths.config) == newConfig else {
                throw FixError("config.plist doesn't match after writing. Restore the newest backup from Boot Setup before restarting.")
            }
        } else {
            script += prepared.plan.commands
            _ = try runner.run(script: script.joined(separator: "\n") + "\n")
        }
        return ApplyResult(changes: prepared.changes, backup: backup)
    }

    public func backups() -> [BackupEntry] {
        let items = (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            guard let date = Self.stampFormatter.date(from: url.lastPathComponent) else { return nil }
            let note = (try? String(contentsOf: url.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
            return BackupEntry(url: url, date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.date > $1.date }
    }

    /// Puts a backup's kexts and config.plist back, config last. A fix can replace a kext in place,
    /// so restoring the config alone would keep loading the replacement.
    public func restore(_ entry: BackupEntry) throws {
        guard let paths else { throw FixError("The boot partition isn't open. Open it from Boot Setup first.") }
        let source = entry.url.appendingPathComponent("EFI/OC/config.plist")
        let kexts = entry.url.appendingPathComponent("EFI/OC/Kexts", isDirectory: true)
        let config = try OpenCoreConfig(data: Data(contentsOf: source))
        for bundle in config.enabledKexts where !FileManager.default.fileExists(atPath: kexts.appendingPathComponent(bundle).path) {
            throw FixError("That backup is missing \(bundle), so it wasn't restored.")
        }
        let q = Shell.quote
        let incoming = paths.config.path + ".hs-new"
        var script = ["set -e"]
        for bundle in try FileManager.default.contentsOfDirectory(atPath: kexts.path) where bundle.hasSuffix(".kext") {
            let destination = paths.kexts.appendingPathComponent(bundle).path
            let copy = destination + ".hs-new"
            script += [
                "rm -rf \(q(copy))",
                "cp -R \(q(kexts.appendingPathComponent(bundle).path)) \(q(copy))",
                "rm -rf \(q(destination))",
                "mv \(q(copy)) \(q(destination))",
            ]
        }
        script += [
            "cp \(q(source.path)) \(q(incoming))",
            "cmp -s \(q(source.path)) \(q(incoming))",
            "mv -f \(q(incoming)) \(q(paths.config.path))",
        ]
        _ = try runner.run(script: script.joined(separator: "\n") + "\n")
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Gets kexts from their official GitHub releases or from inside the app.
public struct KextFetcher: Sendable {
    public var bundledRoot: URL?

    public init(bundledRoot: URL? = Bundle.main.resourceURL) {
        self.bundledRoot = bundledRoot
    }

    public func fetch(_ origin: KextOrigin, only specs: [KextSpec]) async throws -> [PreparedKext] {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("hs-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        switch origin {
        case .bundled(let folder, _):
            guard let root = bundledRoot?.appendingPathComponent(folder, isDirectory: true) else {
                throw FixError("This copy of the app doesn't include its bundled kexts. See patches/README.md in the project to build them.")
            }
            return try specs.map { spec in
                let source = root.appendingPathComponent(spec.bundle, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw FixError("This copy of the app doesn't include \(spec.bundle). Public downloads leave out the patched Bluetooth kexts. See patches/README.md in the project to build them.")
                }
                let copy = stage.appendingPathComponent(spec.bundle, isDirectory: true)
                try FileManager.default.copyItem(at: source, to: copy)
                return try Self.describe(copy, spec: spec, source: "Included with this app", sha256: nil)
            }

        case .github(let repo, _):
            let release = try await Self.latestRelease(repo: repo)
            guard let asset = Self.chooseAsset(names: release.assets.map(\.name)),
                  let chosen = release.assets.first(where: { $0.name == asset }) else {
                throw FixError("\(repo)'s newest release has no release zip to install.")
            }
            let (file, response) = try await URLSession.shared.download(from: chosen.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FixError("Couldn't download \(asset).") }
            let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            let unpack = stage.appendingPathComponent("unpacked", isDirectory: true)
            let result = Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, unpack.path], timeout: 120)
            guard result.succeeded else { throw FixError("Couldn't unpack \(asset).") }
            return try specs.map { spec in
                guard let found = Self.findKext(named: spec.bundle, in: unpack) else {
                    throw FixError("\(asset) doesn't contain \(spec.bundle).")
                }
                return try Self.describe(found, spec: spec, source: "github.com/\(repo), \(release.tag)", sha256: hash)
            }
        }
    }

    struct Release {
        struct Asset { let name: String; let url: URL }
        let tag: String
        let assets: [Asset]
    }

    static func latestRelease(repo: String) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw FixError("Bad project name: \(repo)") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HackintoshSimplified", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixError("Couldn't read \(repo)'s releases from GitHub.")
        }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { item -> Release.Asset? in
            guard let name = item["name"] as? String, let link = item["browser_download_url"] as? String,
                  let url = URL(string: link), url.host == "github.com" else { return nil }
            return Release.Asset(name: name, url: url)
        }
        return Release(tag: json["tag_name"] as? String ?? "newest", assets: assets)
    }

    /// Prefers RELEASE zips and never picks DEBUG builds, source archives or extra tool bundles.
    public static func chooseAsset(names: [String]) -> String? {
        let zips = names.filter { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".zip") && !lower.contains("debug") && !lower.contains("dsym") && !lower.contains("source") && !lower.contains("tools")
        }
        return zips.first { $0.uppercased().contains("RELEASE") } ?? zips.first
    }

    /// Finds a kext at any depth, without looking inside other kexts' PlugIns.
    static func findKext(named bundle: String, in folder: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "kext" {
            if url.lastPathComponent == bundle { return url }
            walker.skipDescendants()
        }
        return nil
    }

    /// Checks the bundle is a real kext, and reads the fields config.plist needs.
    static func describe(_ url: URL, spec: KextSpec, source: String, sha256: String?) throws -> PreparedKext {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FixError("\(spec.bundle) has no readable Info.plist.")
        }
        var executable = ""
        if let name = plist["CFBundleExecutable"] as? String, !name.isEmpty {
            executable = "Contents/MacOS/\(name)"
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(executable).path) else {
                throw FixError("\(spec.bundle) is missing its program file.")
            }
        }
        let libraries = plist["OSBundleLibraries"] as? [String: Any] ?? [:]
        return PreparedKext(spec: spec, stagedURL: url, executable: executable,
                            version: plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String ?? "unknown",
                            source: source, sha256: sha256, needsLilu: libraries["as.vit9696.Lilu"] != nil)
    }
}
