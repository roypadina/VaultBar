import Foundation

/// A password as raw bytes, zeroed on `wipe()` and deinit.
/// Best effort only: the `String` it was built from (e.g. NSSecureTextField.stringValue) and any
/// copies Swift/AppKit made of it are immutable and can't be wiped.
public final class Secret: @unchecked Sendable {
    private var bytes: [UInt8]

    public init(_ string: String) { bytes = Array(string.utf8) }

    deinit { wipe() }

    public var isEmpty: Bool { bytes.isEmpty }

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

    /// Normal Finder-visible mount.
    public static func attach(_ imagePath: String, secret: Secret) -> ToolResult {
        Tool.run(hdiutil, ["attach", "-stdinpass", imagePath], secret: secret)
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

    /// Resolved image path -> mount point, for every attached image that is mounted.
    public static func mounted() -> [String: String] {
        let result = Tool.run(hdiutil, ["info", "-plist"])
        return result.ok ? parseInfo(Data(result.stdout.utf8)) : [:]
    }

    public static func parseInfo(_ data: Data) -> [String: String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
            else { continue }
            result[resolve(path)] = mountPoint
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

public extension [String: String] {
    func mountPoint(of vault: Vault) -> String? { self[HDIUtil.resolve(vault.imagePath)] }
}
