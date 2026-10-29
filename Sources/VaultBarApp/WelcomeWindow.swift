import SwiftUI

/// First-launch welcome (MBX-18): why the app exists, how to use it, how to get back in without the icon (MBX-8)
/// and the login item (MBX-17). Shown once from `AppController.showWelcomeOnce`, again from Settings.
struct WelcomeView: View {
    @ObservedObject var controller: AppController
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to VaultBar").font(.title2.bold())
                    Text("Your private files sit in an encrypted disk image, and it is easy to leave it unlocked. VaultBar unlocks it from the menu bar and locks it again when you step away.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("menubar.rectangle", "VaultBar lives in the menu bar.",
                "Click the notebook icon to unlock or lock your default vault. Right-click or Control-click for every vault and Settings.")
            row("moon.zzz", "It locks itself.",
                "On sleep, on screen lock and after 15 idle minutes. ⌃⌥⌘L locks every vault at once.")
            row("key", "Your password is never stored.",
                "You type it every time. Save it in your password manager first: there is no recovery key.")
            row("questionmark.circle", "Icon missing?",
                "Open VaultBar again from Applications or Raycast to get Settings. A full menu bar can hide the icon.")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch at login", isOn: controller.binding(\.launchAtLogin))
                Text("Auto-lock only works while VaultBar is running.").font(.callout).foregroundStyle(.secondary)
            }
            SupportBox()
            HStack {
                Button("Open Settings", action: onOpenSettings)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Quiet Ko-fi box (house style H1): the app's own next step stays the primary button, so this one is `.bordered`.
struct SupportBox: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free and open source").font(.headline)
                    Text("If VaultBar saves you time, a coffee on Ko-fi keeps the next one coming.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Support on Ko-fi ☕", destination: AboutView.koFi).buttonStyle(.bordered)
            }
            .padding(4)
        }
    }
}
