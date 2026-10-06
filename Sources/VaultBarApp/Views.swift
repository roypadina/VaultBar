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
                    Stepper("", value: controller.binding(\.autoLock.idleMinutes), in: 0...600).labelsHidden()
                }
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
                        if controller.config.raycastScriptsDir != nil {
                            Button("Turn Off") { controller.update { $0.raycastScriptsDir = nil } }
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
            VStack(alignment: .leading) {
                TextField("Name", text: $name).onSubmit(rename)
                Text(vault.imagePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if name != vault.name { Button("Rename", action: rename) }
            Button("Remove") { controller.remove(vault) }
                .help("Removes it from VaultBar only. The image file stays.")
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
            if !password.isEmpty && password.count < 12 {
                Text("Under 12 characters. A longer password is much stronger.").foregroundStyle(.orange)
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
