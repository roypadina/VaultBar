import Foundation

/// A password as raw bytes, zeroed on `wipe()` and deinit.
/// Best effort only: the `String` it was built from (e.g. NSSecureTextField.stringValue) and any
/// copies Swift/AppKit made of it are immutable and can't be wiped.
public final class Secret: @unchecked Sendable {
    private var bytes: [UInt8]

    public init(_ string: String) { bytes = Array(string.utf8) }

    deinit { wipe() }

    public var isEmpty: Bool { bytes.isEmpty }
    var containsLineBreakOrNUL: Bool { bytes.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0 } }

    /// `first`, a newline, `second`: two passwords on one stdin (diskutil chpass).
    convenience init(joining first: Secret, _ second: Secret) {
        self.init("")
        bytes = first.bytes + [0x0A] + second.bytes
    }

    public func wipe() {
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { _ = memset_s(base, buffer.count, 0, buffer.count) }
        }
        bytes.removeAll()
    }

    /// Writes the bytes (no trailing newline, like `printf '%s'`) to `fd`.
    fileprivate func write(to fd: Int32) {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

public struct ToolResult: Sendable {
    public let status: Int32
    public let stdout: String
    /// stdout + stderr, minus macOS 27's "hdiutil ... is deprecated" warning lines. For messages.
    public let output: String

    public var ok: Bool { status == 0 }
    public var isBusy: Bool { status == 16 || output.localizedCaseInsensitiveContains("busy") }
    public var isAuthError: Bool { output.contains("Authentication error") }
}

public enum Tool {
    /// Runs `path args`. A secret goes only to the child's stdin through a pipe that is closed right
    /// after writing: never argv, env, disk or logs. Without a secret stdin is /dev/null, so the child
    /// can never prompt (or fall back to the system password dialog).
    public static func run(_ path: String, _ args: [String], secret: Secret? = nil) -> ToolResult {
        // An empty stdin passphrase is the one case where a tool might fall back to prompting.
        if let secret, secret.isEmpty { return ToolResult(status: -1, stdout: "", output: "Empty password.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = secret.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, stdout: "", output: error.localizedDescription)
        }
        if let input, let secret {
            let fd = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1) // child may exit before reading; don't die of SIGPIPE
            secret.write(to: fd)
            try? input.fileHandleForWriting.close()
        }
        // Outputs here are tiny, so reading the pipes one after the other can't fill and block either.
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let text = (out + err).split(separator: "\n").filter { !$0.contains("is deprecated") }.joined(separator: "\n")
        return ToolResult(status: process.terminationStatus, stdout: out, output: text)
    }
}

public enum HDIUtil {
    static let hdiutil = "/usr/bin/hdiutil"
    // Only attach/create ever open an encrypted image, always with the stdin flag. Any other verb that opens
    // one (imageinfo, verify, convert, ...) without -stdinpass pops the system password dialog with its
    // "Remember password in my keychain" box, so don't add one.

    /// The password always comes from stdin (`-stdinpass`). Default: a normal Finder-visible mount in /Volumes.
    public static func attachArguments(_ imagePath: String, mountPoint: String? = nil, hidden: Bool = false,
                                       readOnly: Bool = false) -> [String] {
        ["attach", "-stdinpass"] + (readOnly ? ["-readonly"] : []) + (hidden ? ["-nobrowse"] : [])
            + (mountPoint.map { ["-mountpoint", $0] } ?? []) + [imagePath]
    }

    public static func attach(_ imagePath: String, mountPoint: String? = nil, hidden: Bool = false,
                              readOnly: Bool = false, secret: Secret) -> ToolResult {
        Tool.run(hdiutil, attachArguments(imagePath, mountPoint: mountPoint, hidden: hidden, readOnly: readOnly),
                 secret: secret)
    }

    /// Re-wraps the image key with a new password (stdin: old, newline, new). Not a re-encryption: old copies
    /// of the image (backups, snapshots) still open with the old password. The vault must be locked.
    public static func changePassword(_ imagePath: String, old: Secret, new: Secret) -> ToolResult {
        guard !old.containsLineBreakOrNUL, !new.containsLineBreakOrNUL else {
            return ToolResult(status: -1, stdout: "", output: "A password with a line break can't be changed here.")
        }
        return Tool.run("/usr/sbin/diskutil", ["image", "--stdinpassphrase", "chpass", imagePath],
                        secret: Secret(joining: old, new))
    }

    public static func detach(_ mountPoint: String, force: Bool) -> ToolResult {
        Tool.run(hdiutil, ["detach", mountPoint] + (force ? ["-force"] : []))
    }

    /// Encrypted (AES-256) APFS sparse bundle, not mounted afterwards. `diskutil image` takes the
    /// passphrase from stdin, so it replaces the deprecated `hdiutil create -encryption`.
    public static func create(imagePath: String, volumeName: String, sizeGB: Int, secret: Secret) -> ToolResult {
        Tool.run("/usr/sbin/diskutil", ["image", "--stdinpassphrase", "create", "blank", "--encrypt",
                                        "--format", "UDSB", "--size", "\(sizeGB)g",
                                        "--volumeName", volumeName, imagePath], secret: secret)
    }

    public static func isEncrypted(_ imagePath: String) -> Bool {
        let result = Tool.run(hdiutil, ["isencrypted", "-plist", imagePath])
        guard result.ok,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil)
                as? [String: Any] else { return false }
        return plist["encrypted"] as? Bool ?? false
    }

    /// Resolved image path -> its mount, for every attached image that is mounted.
    public static func mounted() -> [String: Mount] {
        let result = Tool.run(hdiutil, ["info", "-plist"])
        return result.ok ? parseInfo(Data(result.stdout.utf8)) : [:]
    }

    /// Like `mounted()`, but nil when `hdiutil info` fails or prints no property list, for callers that must not
    /// mistake "unknown" for "nothing mounted".
    public static func mountedIfKnown() -> [String: Mount]? {
        let result = Tool.run(hdiutil, ["info", "-plist"])
        let data = Data(result.stdout.utf8)
        guard result.ok,
              (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else { return nil }
        return parseInfo(data)
    }

    public static func parseInfo(_ data: Data) -> [String: Mount] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var result: [String: Mount] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
            else { continue }
            result[resolve(path)] = Mount(path: mountPoint, readOnly: image["writeable"] as? Bool == false)
        }
        return result
    }

    /// realpath, so "~/x", symlinks and "/Volumes/MyVault 1" drift don't matter: images match by file.
    public static func resolve(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { return NSString(string: expanded).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }
}

public struct Mount: Equatable, Sendable {
    public var path: String
    public var readOnly: Bool
}

public extension [String: Mount] {
    func mount(of vault: Vault) -> Mount? { self[HDIUtil.resolve(vault.imagePath)] }
    func mountPoint(of vault: Vault) -> String? { mount(of: vault)?.path }
}

/// A private mount folder exists only while its vault is unlocked: created (0700) right before attach and removed
/// after detach, so a locked vault leaves no plain folder anything could write into.
public enum MountFolder {
    /// Error message, or nil once `path` is an empty folder ready to mount on.
    public static func prepare(_ path: String) -> String? {
        if let problem = Config.problem(withMountPoint: path) { return problem }
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { return "\(path) is a file, not a folder." }
            let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? ["?"]
            guard contents.isEmpty else { return "\(path) isn't empty. VaultBar only mounts on an empty folder." }
            return chmod(path, 0o700) == 0 ? nil : "Couldn't make \(path) private (chmod 700)."
        }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// `rmdir`: only ever removes an empty folder.
    public static func remove(_ path: String) { rmdir(path) }

    /// Private mount folders that shouldn't exist: every configured one whose vault isn't mounted, e.g. after an
    /// eject outside VaultBar (Finder, `hdiutil detach`, another app). `attaching`: vault names whose folder was
    /// just created for an unlock in progress.
    public static func stale(vaults: [Vault], mounted: [String: Mount], attaching: Set<String> = []) -> [String] {
        vaults.filter { mounted.mount(of: $0) == nil && !attaching.contains($0.name) }.compactMap(\.expandedMountPoint)
    }
}

/// `--unregister-login-item`: removing the login agent stops the running copy without its Quit prompt, so every
/// mounted vault is locked first, in-process (the app may not be running).
public enum UnregisterLock {
    public struct Report: Equatable, Sendable {
        public var locked: [String] = []
        /// Vault name and why it is still unlocked.
        public var stillUnlocked: [Failure] = []
        public var mayUnregister: Bool { stillUnlocked.isEmpty }
    }

    public struct Failure: Equatable, Sendable {
        public let vault: String
        public let reason: String
    }

    /// Clean detach for each mounted vault; a busy one is force-detached only with `force`. `detach` is
    /// `HDIUtil.detach` (injected for tests). Private mount folders of locked vaults are removed.
    public static func lockAll(_ vaults: [Vault], mounted: [String: Mount], force: Bool,
                               detach: (String, Bool) -> ToolResult) -> Report {
        var report = Report()
        for vault in vaults {
            guard let mountPoint = mounted.mountPoint(of: vault) else { continue }
            var result = detach(mountPoint, false)
            if !result.ok, result.isBusy, force { result = detach(mountPoint, true) }
            if result.ok {
                if !mountPoint.hasPrefix("/Volumes/") { MountFolder.remove(mountPoint) }
                if let folder = vault.expandedMountPoint { MountFolder.remove(folder) }
                report.locked.append(vault.name)
            } else if result.isBusy {
                report.stillUnlocked.append(Failure(vault: vault.name, reason: "busy (a file is open); close it, or use --force"))
            } else {
                report.stillUnlocked.append(Failure(vault: vault.name, reason: result.output.isEmpty ? "detach failed" : result.output))
            }
        }
        return report
    }
}
