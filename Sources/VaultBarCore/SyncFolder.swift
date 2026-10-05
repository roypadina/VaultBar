import Foundation

public enum SyncFolder {
    /// Why `folder` looks synced to a cloud or another device, or nil. An encrypted image there gets
    /// uploaded band by band, and two-way sync can corrupt it.
    public static func warning(for folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = HDIUtil.resolve(folder.path)
        let synced: [(String, String)] = [
            ("Library/Mobile Documents", "iCloud Drive"),
            ("Library/CloudStorage", "a cloud-storage provider (Dropbox, Google Drive, OneDrive, Synology Drive…)"),
            ("Desktop", "Desktop, which iCloud syncs when \"Desktop & Documents Folders\" is on"),
            ("Documents", "Documents, which iCloud syncs when \"Desktop & Documents Folders\" is on"),
        ]
        for (relative, label) in synced {
            let root = HDIUtil.resolve(home.appendingPathComponent(relative).path)
            if path == root || path.hasPrefix(root + "/") { return "This folder is inside \(label)." }
        }
        var dir = path
        while true {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir + "/.stfolder") { return "This folder is inside a Syncthing folder (\(dir))." }
            if fm.fileExists(atPath: dir + "/.SynologyWorkingDirectory") {
                return "This folder is inside a Synology Drive folder (\(dir))."
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }
}
