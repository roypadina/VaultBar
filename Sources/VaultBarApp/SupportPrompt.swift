import AppKit
import CoreAudio
import SwiftUI
import VaultBarCore

/// One dynamic colour from a light/dark pair (plus optional Increase Contrast variants), so every Color
/// below flips with the appearance automatically.
private func dyn(light: NSColor, dark: NSColor, hcLight: NSColor? = nil, hcDark: NSColor? = nil) -> Color {
    Color(nsColor: NSColor(name: nil) {
        switch $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: dark
        case .accessibilityHighContrastAqua: hcLight ?? light
        case .accessibilityHighContrastDarkAqua: hcDark ?? dark
        default: light
        }
    })
}

/// The card's colours (MeetAlert's Theme values; VaultBar has no theme file).
private enum Theme {
    /// Card base tint over .regularMaterial. Navy-ink, not neutral black.
    static let ink = dyn(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.45),
                         dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 0.55))
    static let kofi = dyn(light: NSColor(red: 0.78, green: 0.19, blue: 0.18, alpha: 1),   // #C8302D
                          dark: NSColor(red: 1.00, green: 0.37, blue: 0.36, alpha: 1),    // #FF5E5B
                          hcLight: NSColor(red: 0.64, green: 0.14, blue: 0.13, alpha: 1), // #A32320
                          hcDark: NSColor(red: 1.00, green: 0.53, blue: 0.51, alpha: 1))  // #FF8783
    /// Ink text on the bright dark-mode fill, white on the deep light-mode fill.
    static let onSignal = dyn(light: .white, dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1))
}

/// The floating receipt card, top-right under the menu bar. Borderless, so it can never become key:
/// no keystroke can reach its buttons (a stray Return must not tip or opt out). Keyboard and
/// VoiceOver users get the same three actions in the status menu instead.
@MainActor
enum SupportPanel {
    private static var panel: NSPanel?
    static var current: NSPanel? { panel }  // a card's delayed close checks it is still the one on screen
    private static var onAnswer: ((SupportPromptState.Answer) -> Void)?
    private static var onClosed: (@MainActor () -> Void)?  // @MainActor = Sendable: close()'s completion captures it
    /// Transparent room around the card: shadow on top/right, coffee burst on left/bottom.
    static let insets = EdgeInsets(top: 12, leading: 48, bottom: 48, trailing: 12)

    static func show(vaultLocks: Int, unlocks: Int, statusItemWindow: NSWindow?,
                     onAnswer: @escaping (SupportPromptState.Answer) -> Void,
                     onClosed: @escaping @MainActor () -> Void) {
        guard panel == nil else { return }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main else {
            return onClosed()
        }
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false  // Swift owns it via `panel`
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = false  // the card draws its own; a window shadow would outline the transparent margin
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: SupportPromptView(vaultLocks: vaultLocks, unlocks: unlocks))
        p.contentView = host
        let size = host.fittingSize
        let visible = screen.visibleFrame  // card lands 12pt in from the top-right corner (= the insets)
        p.setFrame(NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height,
                          width: size.width, height: size.height), display: false)
        p.orderFrontRegardless()
        panel = p
        self.statusItemWindow = statusItemWindow
        self.onAnswer = onAnswer
        self.onClosed = onClosed
        AccessibilityNotification.Announcement(
            "VaultBar: \(vaultLocks.formatted()) times locked up tight. Tip a coffee on Ko-fi? Options are in the VaultBar menu: right-click its icon."
        ).post()
        Task {  // unanswered 5 min, or 2 min without input (walked off): fade away as "Ask me in 2 weeks"
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(15))
                guard panel === p else { return }
                if idleSeconds() > 120 { break }
            }
            respond(.snooze)
            close()
        }
    }

    /// Keyboard/mouse only, same measure as auto-lock's idle time.
    private static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The default input device is recording for some app (a call, dictation). Reading it needs no mic permission.
    static func micInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// One answer per card (button or menu). Records it; the caller animates and closes.
    static func respond(_ answer: SupportPromptState.Answer) {
        onAnswer?(answer)
        onAnswer = nil
    }

    static func close() {
        guard let p = panel else { return }
        panel = nil
        onAnswer = nil
        let closed = onClosed
        onClosed = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {  // AppKit calls it on the main thread; the SDK just doesn't say so
                // close + drop the view: a hidden panel keeps rendering its loops
                p.contentView = nil
                p.close()
                closed?()
            }
        })
    }

    /// Snooze: slide the window so the (SwiftUI-shrinking) card ends on the menu-bar icon.
    static func flyToStatusItem(duration: TimeInterval) {
        guard let p = panel, let target = statusItemWindow?.frame else { return }
        let card = NSRect(x: p.frame.minX + insets.leading, y: p.frame.minY + insets.bottom,
                          width: p.frame.width - insets.leading - insets.trailing,
                          height: p.frame.height - insets.top - insets.bottom)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.2)
            p.animator().setFrameOrigin(NSPoint(x: p.frame.minX + target.midX - card.midX,
                                                y: p.frame.minY + target.midY - card.midY))
        }
    }

    /// One accent-coloured flash behind the menu-bar icon, as the snoozed card lands in it.
    static func pulseStatusItem() {
        guard let view = statusItemWindow?.contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
        let red = NSColor(red: 1.00, green: 0.37, blue: 0.36, alpha: 0.9).cgColor  // Ko-fi red #FF5E5B
        pulse.values = [NSColor.clear.cgColor, red, NSColor.clear.cgColor]
        pulse.keyTimes = [0, 0.3, 1]
        pulse.duration = 0.9
        view.layer?.add(pulse, forKey: "supportPulse")
    }

    /// The status item's window (nil: hidden by a full menu bar or headless → snooze just fades).
    private static weak var statusItemWindow: NSWindow?
}

/// The receipt: prints out of a slot, itemises what VaultBar did, ends in "TIP? ☕ optional".
struct SupportPromptView: View {
    let vaultLocks: Int
    let unlocks: Int
    var settled = false  // start fully printed, no entry animation (screenshot renders)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var shown = false
    @State private var printed: CGFloat = 0  // 0 = paper inside the slot, 1 = fully out
    @State private var paperHeight: CGFloat = 0
    @State private var buttonsShown = false
    @State private var sheen: CGFloat = -1  // sheen band position across the Support button, -1…1
    @State private var answered = false
    @State private var bursting = false
    @State private var thanked = false
    @State private var leaving = false  // never / final fade: scale 0.94 + fade
    @State private var flying = false  // snooze: shrink toward the menu-bar icon

    private static let width: CGFloat = 340
    private static let radius: CGFloat = 18
    private var title: String { "\(vaultLocks.formatted()) times locked up tight. 🎯" }

    var body: some View {
        card
            .scaleEffect(flying ? 0.06 : leaving ? 0.94 : 1)
            .opacity(flying || leaving || !(shown || settled) ? 0 : 1)
            .padding(SupportPanel.insets)
            .task { await sheenLoop() }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return ZStack {
            receipt.opacity(thanked ? 0 : 1)
            if thanked { thanks }  // same card size: content crossfades, nothing jumps
        }
        .padding(14)
        .frame(width: Self.width)
        .background {
            ZStack {
                if contrast == .increased {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(Theme.ink)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        }
        .overlay(shape.strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.12)),
                                    lineWidth: contrast == .increased ? 2 : 1))
        .overlay { if bursting { CoffeeBurst() } }
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            Capsule()  // the printer slot
                .fill(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .frame(height: 9)
                .zIndex(1)  // the paper slides out from under the slot
                .accessibilityHidden(true)
            paper  // measured first, then printed: the card stays invisible until then (no full-paper flash)
                .background(GeometryReader { g in Color.clear.onAppear { paperHeight = g.size.height; enter() } })
                .offset(y: -(1 - (settled ? 1 : printed)) * (paperHeight + 9))  // + the torn edge
                .padding(.bottom, 9)  // room for the torn edge
                .clipped()
                .padding(.horizontal, 8)
                .padding(.top, -3)
            buttons.opacity(buttonsShown || settled ? 1 : 0)
        }
    }

    private var paper: some View {
        let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
        let faded = Color(red: 0.36, green: 0.33, blue: 0.29)
        return VStack(spacing: 3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("VAULTBAR ★ RECEIPT").font(.system(size: 11.5, weight: .bold, design: .monospaced)).tracking(1.4)
            Text(Date().formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(faded)
                .padding(.bottom, 6)
            row("Vault locks", vaultLocks.formatted())
            if unlocks > 0 { row("Unlocks", unlocks.formatted()) }
            row("Price paid", "$0.00")
            Divider().overlay(faded.opacity(0.5)).padding(.vertical, 3)
            HStack { Text("TIP?"); Spacer(); Text("☕ optional") }
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
            VStack(spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text("VaultBar is free, open source and made by one person. Tip the human behind the lock?")
                    .font(.system(size: 11.5)).foregroundStyle(faded)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            Barcode().fill(ink).frame(height: 22).padding(.horizontal, 20).padding(.top, 8)
                .accessibilityHidden(true)
        }
        .foregroundStyle(ink)
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
        .background(TornPaper().fill(Color(red: 0.98, green: 0.97, blue: 0.93)).padding(.bottom, -8)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(label).fixedSize()  // the leader shrinks, never the label
            Leader().stroke(Color(red: 0.71, green: 0.68, blue: 0.62), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(value).fixedSize()
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button("Tip a coffee ☕") { answer(.support) }
                .buttonStyle(SupportButtonStyle(prominent: true))
                .overlay { sheenBand }
            HStack(spacing: 6) {
                Button("Ask me in 2 weeks") { answer(.snooze) }.buttonStyle(SupportButtonStyle())
                Button("Nope, don't ask again") { answer(.never) }.buttonStyle(SupportButtonStyle())
            }
            Text("I only ask after you lock a vault — at most 3× a year.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .padding(.top, 4)
        .disabled(answered)
    }

    private var sheenBand: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.35)
                .offset(x: sheen * g.size.width * 0.9 + g.size.width * 0.325)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var thanks: some View {
        VStack(spacing: 6) {
            Text("♥").font(.system(size: 40)).foregroundStyle(Theme.kofi)
            Text("Thank you!").font(.system(size: 16, weight: .semibold))
            Text("Opening Ko-fi…").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    // MARK: motion

    private func enter() {
        guard !settled else { return }
        if reduceMotion {
            printed = 1
            buttonsShown = true
            withAnimation(.easeOut(duration: 0.15)) { shown = true }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { shown = true }
        Task {
            // Stepped jerks, ~1 s total: (target, move seconds) with a short hold after each.
            for (target, seconds) in [(0.17, 0.15), (0.43, 0.19), (0.71, 0.20), (1.0, 0.30)] as [(CGFloat, Double)] {
                withAnimation(.easeOut(duration: seconds)) { printed = target }
                try? await Task.sleep(for: .seconds(seconds + 0.06))
            }
            withAnimation(.easeOut(duration: 0.3)) { buttonsShown = true }
        }
    }

    private func sheenLoop() async {
        guard !settled, !reduceMotion else { return }
        for _ in 0..<2 {  // two passes catch the eye once; an endless shine reads as nagging
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !answered else { return }
            sheen = -1
            withAnimation(.easeInOut(duration: 1.2)) { sheen = 1 }
        }
    }

    private func answer(_ a: SupportPromptState.Answer) {
        guard !answered else { return }
        answered = true
        SupportPanel.respond(a)
        let mine = SupportPanel.current
        Task {
            switch a {
            case .support:
                bursting = !reduceMotion
                try? await Task.sleep(for: .seconds(reduceMotion ? 0 : 0.35))
                withAnimation(.easeInOut(duration: 0.3)) { thanked = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.25)) { leaving = true }
                try? await Task.sleep(for: .seconds(0.25))
            case .snooze where !reduceMotion:
                withAnimation(.timingCurve(0.55, 0, 0.8, 0.2, duration: 0.55)) { flying = true }
                SupportPanel.flyToStatusItem(duration: 0.55)
                try? await Task.sleep(for: .seconds(0.5))
                SupportPanel.pulseStatusItem()
            case .snooze, .never:
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { leaving = true }
                try? await Task.sleep(for: .seconds(0.25))
            }
            guard let mine, SupportPanel.current === mine else { return }  // closed meanwhile, maybe a new card up
            SupportPanel.close()
        }
    }
}

/// Fill-the-card buttons. Custom on purpose: the app is never active while the card shows, so
/// system bordered buttons would render in their gray inactive look.
private struct SupportButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(cfg: configuration, prominent: prominent)
    }

    private struct StyledButton: View {
        let cfg: Configuration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: prominent ? 9 : 7, style: .continuous)
            cfg.label
                .font(.system(size: prominent ? 13 : 12, weight: prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: prominent ? 34 : 28)
                .foregroundStyle(prominent ? AnyShapeStyle(Theme.onSignal) : AnyShapeStyle(.primary))
                .background(shape.fill(prominent ? AnyShapeStyle(Theme.kofi)
                                                 : AnyShapeStyle(Color.primary.opacity(hover ? 0.14 : 0.08))))
                .contentShape(shape)
                .opacity(prominent && hover ? 0.92 : enabled ? 1 : 0.6)
                .scaleEffect(cfg.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// Coffee cups and beans flying out of the card's centre, once.
private struct CoffeeBurst: View {
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<24, id: \.self) { i in
                let angle = Double(i) * 2.39996  // golden angle: an even, deterministic spread
                let distance = 90 + Double((i * 37) % 80)
                Group {
                    if i % 3 == 0 {
                        Text("☕").font(.system(size: 18))
                    } else {
                        Capsule().fill(Color(red: 0.42, green: 0.24, blue: 0.12)).frame(width: 7, height: 10)
                    }
                }
                .rotationEffect(.degrees(fired ? Double((i * 53) % 360) - 180 : 0))
                .scaleEffect(fired ? 1 : 0.5)
                .offset(x: fired ? cos(angle) * distance : 0, y: fired ? sin(angle) * distance - 20 : 0)
                .opacity(fired ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { fired = true } }
    }
}

/// Receipt paper with a zig-zag torn bottom edge (8pt teeth).
private struct TornPaper: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tooth: CGFloat = 12, depth: CGFloat = 8
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        var x = r.maxX
        while x > r.minX {
            p.addLine(to: CGPoint(x: max(r.minX, x - tooth / 2), y: r.maxY))
            x -= tooth
            p.addLine(to: CGPoint(x: max(r.minX, x), y: r.maxY - depth))
        }
        p.closeSubpath()
        return p
    }
}

/// Dotted leader between a receipt label and its value.
private struct Leader: Shape {
    func path(in r: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
    }
}

/// Decorative barcode: fixed bar widths, so it looks the same every time.
private struct Barcode: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pattern: [CGFloat] = [2, 1, 1, 3, 2, 1, 3, 1, 1, 2, 1, 1, 2, 3, 1, 2]
        var x = r.minX, i = 0
        while x < r.maxX {
            let bar = pattern[i % pattern.count]
            if i % 2 == 0 { p.addRect(CGRect(x: x, y: r.minY, width: min(bar, r.maxX - x), height: r.height)) }
            x += bar + 1
            i += 1
        }
        return p
    }
}
