import AppKit
import SwiftUI
import VaultBarCore

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("Vaults") {
                ForEach(controller.config.vaults, id: \.name) { vault in
                    VaultRow(controller: controller, vault: vault)
                }
                HStack {
                    Button("Add Existing…") { controller.addExisting() }
                    Button("New Vault…") { controller.newVault() }
                }
            }
            Section("Auto-lock (all vaults)") {
                Toggle("Lock on sleep (forced)", isOn: controller.binding(\.autoLock.onSleep))
                Toggle("Lock when the screen locks", isOn: controller.binding(\.autoLock.onScreenLock))
                HStack {
                    Text("Lock after idle minutes (0 = off)")
                    Spacer()
                    TextField("", value: controller.binding(\.autoLock.idleMinutes), format: .number)
                        .frame(width: 50)
                        .accessibilityLabel("Idle minutes before locking, 0 for off")
                    Stepper("", value: controller.binding(\.autoLock.idleMinutes), in: 0...600).labelsHidden()
                        .accessibilityLabel("Idle minutes")
                }
            }
            Section("Panic lock") {
                Picker("Hotkey that locks every vault", selection: controller.binding(\.panicHotkey)) {
                    ForEach(PanicHotkey.presets, id: \.id) { Text($0.title).tag($0.id) }
                    Text("Off").tag("off")
                }
                Toggle("Force busy vaults (unsaved changes in open apps may be lost)", isOn: controller.binding(\.panicForces))
                Text("⌥-click the menu bar icon to lock all without forcing.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login (auto-lock needs VaultBar running)", isOn: controller.binding(\.launchAtLogin))
                Toggle("Open in Finder after unlocking", isOn: controller.binding(\.openAfterUnlock))
            }
            Section("Raycast Script Commands (Unlock / Lock / Open per vault)") {
                LabeledContent("Folder") {
                    HStack {
                        Text(controller.config.raycastScriptsDir ?? "Off").foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { controller.chooseRaycastFolder() }
                            .accessibilityLabel("Choose the Raycast scripts folder")
                        if controller.config.raycastScriptsDir != nil {
                            Button("Turn Off") { controller.update { $0.raycastScriptsDir = nil } }
                                .accessibilityLabel("Stop writing Raycast scripts")
                        }
                    }
                }
                Button("Regenerate Raycast scripts") { controller.syncScripts(announce: true) }
                    .disabled(controller.config.raycastScriptsDir == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VaultRow: View {
    @ObservedObject var controller: AppController
    let vault: Vault
    @State private var name: String

    init(controller: AppController, vault: Vault) {
        self.controller = controller
        self.vault = vault
        _name = State(initialValue: vault.name)
    }

    var body: some View {
        let isDefault = controller.config.defaultVault == vault.name
        HStack {
            Button {
                controller.update { $0.defaultVault = vault.name }
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(isDefault ? "Default vault (left-click on the menu bar icon)" : "Make default")
            .accessibilityLabel(isDefault ? "\(vault.name) is the default vault" : "Make \(vault.name) the default vault")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $name).onSubmit(rename)
                    if name != vault.name { Button("Rename", action: rename) }
                    Button("Remove") { controller.remove(vault) }
                        .help("Removes it from VaultBar only. The image file stays.")
                        .accessibilityLabel("Remove \(vault.name) from VaultBar (the image file stays)")
                }
                Text(vault.imagePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    Toggle("Read-only", isOn: controller.binding(vault, \.isReadOnly))
                        .help("Unlock read-only by default; ⌥ in the menu for the other mode")
                    Toggle("Hidden from Finder", isOn: controller.binding(vault, \.isHidden))
                        .help("Mount with -nobrowse: not in Finder's sidebar, Desktop or file pickers")
                    Spacer()
                    Button("Change Password…") { controller.showChangePassword(vault) }
                        .accessibilityLabel("Change the password of \(vault.name)")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                HStack {
                    Text("Mounts at \(vault.mountPoint ?? "/Volumes (default)")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Private Folder…") { controller.chooseMountFolder(vault) }
                        .help("Mount at a folder of your choice; it exists only while the vault is unlocked")
                        .accessibilityLabel("Choose a private mount folder for \(vault.name)")
                    if vault.mountPoint != nil {
                        Button("Use /Volumes") { controller.update { config in
                            if let index = config.vaults.firstIndex(where: { $0.name == vault.name }) { config.vaults[index].mountPoint = nil }
                        } }
                        .accessibilityLabel("Mount \(vault.name) under /Volumes again")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func rename() {
        if !controller.rename(vault, to: name) { name = vault.name }
    }
}

struct NewVaultView: View {
    let controller: AppController
    let close: () -> Void
    @State private var name = ""
    @State private var volumeName = ""
    @State private var folder: URL?
    @State private var sizeGB = 100
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var creating = false

    private var volume: String {
        let trimmed = volumeName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name.trimmingCharacters(in: .whitespaces) : trimmed
    }

    private var problem: String? {
        if let problem = Config.problem(withName: name) { return problem }
        if controller.config.vaults.contains(where: { Raycast.slug($0.name) == Raycast.slug(name) }) {
            return "A vault with that name already exists."
        }
        if volume.contains("/") || volume.contains(":") { return "The volume name can't contain / or :." }
        let mountedVolumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        if (controller.config.vaults.map(\.name) + mountedVolumes).contains(where: { $0.lowercased() == volume.lowercased() }) {
            return "The volume name \(volume) is already in use."
        }
        if folder == nil { return "Choose a folder." }
        if sizeGB < 1 { return "Max size must be at least 1 GB." }
        if password.isEmpty { return "Enter a password." }
        if password != confirm { return "The passwords don't match." }
        return nil
    }

    var body: some View {
        Form {
            Text("Save this password in your password manager first. There is no recovery key.")
                .font(.headline)
                .foregroundStyle(.orange)
            TextField("Name", text: $name)
            TextField("Volume name", text: $volumeName, prompt: Text(name.isEmpty ? "Same as name" : name))
            LabeledContent("Folder") {
                HStack {
                    Text(folder?.path ?? "None").lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
            if let folder, let warning = SyncFolder.warning(for: folder) {
                Text("⚠️ \(warning) You'll be asked to confirm.").foregroundStyle(.orange)
            }
            TextField("Max size in GB (sparse, grows as needed)", value: $sizeGB, format: .number)
            SecureField("Password", text: $password)
            SecureField("Confirm password", text: $confirm)
            if !password.isEmpty {
                ForEach(PasswordAdvice.warnings(for: password, names: [name, volume]), id: \.self) {
                    Text($0).foregroundStyle(.orange)
                }
            }
            if let message = error ?? problem {
                Text(message).foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || creating)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear(perform: clearPasswords)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Folder for the new vault image"
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func clearPasswords() {
        password = ""
        confirm = ""
    }

    private func cancel() {
        clearPasswords()
        close()
    }

    private func create() {
        guard let folder, problem == nil else { return }
        if let warning = SyncFolder.warning(for: folder),
           !controller.confirm("Create the vault in a synced folder?",
                               "\(warning) Syncing an encrypted image uploads it and can corrupt it.",
                               "Create Anyway") {
            return
        }
        let secret = Secret(password)
        clearPasswords()
        creating = true
        error = nil
        let name = self.name.trimmingCharacters(in: .whitespaces)
        Task {
            error = await controller.createVault(name: name, volumeName: volume, folder: folder, sizeGB: sizeGB, secret: secret)
            creating = false
            if error == nil { close() }
        }
    }
}

struct AboutView: View {
    static let koFi = URL(string: "https://ko-fi.com/roypadina")!
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("VaultBar").font(.title.bold())
                Text("Version \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text("Made by Roy Padina").font(.headline)
                Text("I'm a software engineer from Israel who builds small, focused Mac tools to fix the little annoyances in my own day — then shares them free and open source. If this app saves you time, a coffee on Ko-fi keeps the next one coming. ☕")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link(destination: Self.koFi) {
                    Text("Support on Ko-fi ☕").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Link(destination: URL(string: "https://github.com/roypadina/VaultBar")!) {
                    Text("GitHub").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Link("Report an issue", destination: URL(string: "https://github.com/roypadina/VaultBar/issues")!)
                .font(.callout)

            Text("© Roy Padina · MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct HistoryView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.history.events.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                List(Array(controller.history.events.reversed().enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        Text(event.text)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 240)
            }
            Text("The last 50 events, kept in memory only: cleared when VaultBar quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
    }
}

struct ChangePasswordView: View {
    let controller: AppController
    let vault: Vault
    let close: () -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    private var warnings: [String] {
        new.isEmpty ? [] : PasswordAdvice.warnings(
            for: new, names: [vault.name, URL(fileURLWithPath: vault.imagePath).deletingPathExtension().lastPathComponent])
    }

    private var problem: String? {
        if current.isEmpty { return "Enter the current password." }
        if new.isEmpty { return "Enter a new password." }
        if new != confirm { return "The new passwords don't match." }
        if new == current { return "The new password is the same as the current one." }
        return nil
    }

    var body: some View {
        Form {
            Text("Save the new password in your password manager first. There is no recovery key.")
                .font(.headline).foregroundStyle(.orange)
            Text("This changes the password that opens \(vault.name). It doesn't re-encrypt the data: copies of the image made earlier (backups, snapshots) still open with the old password. For a full re-key, create a new vault and copy the files over.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Current password", text: $current)
            SecureField("New password", text: $new)
            SecureField("Confirm new password", text: $confirm)
            ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            if let message = error ?? problem {
                Text(message).foregroundStyle(error == nil ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(working ? "Changing…" : "Change Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || working)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear(perform: clear)
    }

    private func clear() {
        current = ""
        new = ""
        confirm = ""
    }

    private func cancel() {
        clear()
        close()
    }

    private func submit() {
        guard problem == nil else { return }
        if !warnings.isEmpty, !controller.confirm("Use this password anyway?", warnings.joined(separator: " "), "Use It") { return }
        let old = Secret(current), replacement = Secret(new)
        clear()
        working = true
        error = nil
        Task {
            error = await controller.changePassword(vault, old: old, new: replacement)
            working = false
            if error == nil {
                close()
                controller.alert("Password changed", "\(vault.name) now opens with the new password only.")
            }
        }
    }
}
