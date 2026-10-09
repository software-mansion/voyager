// Menu bar icon and SwiftUI status popover, driven from Rust through the C functions at the bottom.
import AppKit
import Combine
import SwiftUI

public typealias ActionCallback = @convention(c) (UnsafePointer<CChar>) -> Void

struct TrayStatus: Decodable {
    let node: String?
    let nodeLost: Bool
    let connector: String?
    let connectedAt: Date?
    let mcpUrl: String?
    let lastConnected: LastConnected?
    let connecting: Bool
    let error: String?

    struct LastConnected: Decodable {
        let node: String
        let connector: String
    }
}

enum TrayAction: String {
    case open
    case quit
    case connect
    case disconnect
    case toggleMcp = "toggle_mcp"
    case refresh
    case dismissError = "dismiss_error"

    var closesPopover: Bool { self == .open || self == .quit }
}

final class TrayModel: ObservableObject {
    @Published var status: TrayStatus?
    /// The user's System Settings accent; SwiftUI's `Color.accentColor` is the app's own, which defaults to blue.
    @Published private(set) var accent = TrayModel.systemAccent()
    let version: String
    var perform: (TrayAction) -> Void = { _ in }

    init(version: String) {
        self.version = version

        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .merge(with: DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("AppleColorPreferencesChangedNotification")))
            .receive(on: DispatchQueue.main)
            .map { _ in TrayModel.systemAccent() }
            .assign(to: &$accent)
    }

    private static func systemAccent() -> Color {
        Color(NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor)
    }
}

final class TrayController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    let model: TrayModel

    init(icon: NSImage, version: String, onAction: @escaping ActionCallback) {
        model = TrayModel(version: version)
        super.init()
        model.perform = { action in
            if action.closesPopover { self.popover.performClose(nil) }
            action.rawValue.withCString(onAction)
        }

        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        if let button = statusItem.button {
            button.image = icon
            button.target = self
            button.action = #selector(toggle(_:))
        }

        let hosting = NSHostingController(rootView: TrayView(model: model, logo: icon))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = hosting
        if #available(macOS 14.0, *) {
            popover.hasFullSizeContent = true
        }
        popover.behavior = .transient
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        model.perform(.dismissError)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        if #unavailable(macOS 13.0) {
            popover.contentSize = popover.contentViewController?.view.fittingSize ?? .zero
        }
        // A transient popover only closes on outside clicks while the app is active.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // Otherwise AppKit focuses the first button, drawing its focus ring on every open.
        window?.makeFirstResponder(nil)
        model.perform(.refresh)
    }
}

struct TrayView: View {
    @ObservedObject var model: TrayModel
    let logo: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.logo)
                    .frame(width: 20, height: 20)
                Text("Voyager")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.version)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)

            nodeCard
            mcpCard

            if let error = model.status?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                Button("Open Voyager") { model.perform(.open) }
                    .buttonStyle(VoyagerButtonStyle(kind: .filled(model.accent)))
                Button("Quit") { model.perform(.quit) }
                    .buttonStyle(VoyagerButtonStyle(kind: .danger))
                    .frame(width: 84)
            }
            .padding(.top, 4)
        }
        .toggleStyle(VoyagerSwitchStyle(tint: model.accent))
        .tint(model.accent)
        .foregroundStyle(Theme.content)
        .padding(12)
        .frame(width: 300)
        .background(Theme.base200.ignoresSafeArea())
    }

    @ViewBuilder private var nodeCard: some View {
        switch (model.status, model.status?.node) {
        case (nil, _):
            idleNodeCard(title: "Starting…")
        case let (status?, nil):
            idleNodeCard(title: "Not connected")
            if let last = status.lastConnected {
                reconnectRow(last, connecting: status.connecting)
            }
        case let (status?, node?) where status.nodeLost:
            Card(symbol: "antenna.radiowaves.left.and.right.slash", tint: Theme.idle, title: node, subtitle: Text("Connection lost")) {}
        case let (status?, node?):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Card(symbol: "antenna.radiowaves.left.and.right", tint: model.accent, title: node, subtitle: connectedSubtitle(status, now: context.date)) {
                    Button { model.perform(.disconnect) } label: {
                        Image(systemName: "power").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(VoyagerButtonStyle(kind: .danger, compact: true))
                    .help("Disconnect")
                    .accessibilityLabel("Disconnect")
                }
            }
        }
    }

    private func reconnectRow(_ last: TrayStatus.LastConnected, connecting: Bool) -> some View {
        HStack(spacing: 8) {
            (Text("Last: ").foregroundColor(Theme.muted) + Text(last.node))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(last.node) via \(last.connector)")
            Spacer(minLength: 6)
            if connecting {
                Text("Connecting…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            } else {
                Button("Connect") { model.perform(.connect) }
                    .buttonStyle(SmallButtonStyle(hoverColor: model.accent))
            }
        }
        .padding(.horizontal, 2)
    }

    private func idleNodeCard(title: String) -> some View {
        Card(
            symbol: "antenna.radiowaves.left.and.right.slash",
            tint: Theme.idle,
            title: title,
            subtitle: Text("Connect to a node from Voyager")
        ) {}
    }

    private var mcpCard: some View {
        let url = model.status?.mcpUrl
        return Card(
            symbol: "sparkles",
            tint: url == nil ? Theme.idle : model.accent,
            title: "MCP server",
            subtitle: Text(url.map { $0.replacingOccurrences(of: "http://", with: "") } ?? "Stopped")
        ) {
            if let url {
                CopyButton(text: url)
            }
            Toggle("MCP server", isOn: Binding(get: { url != nil }, set: { _ in model.perform(.toggleMcp) }))
                .disabled(model.status == nil)
        }
    }

    private func connectedSubtitle(_ status: TrayStatus, now: Date) -> Text {
        let via = Text(status.connector ?? "Connected")
        guard let since = status.connectedAt else { return via }
        return via + Text(" · ") + Text(compactUptime(since: since, now: now))
    }
}

/// Only the largest unit, e.g. `14min` or `3d`.
func compactUptime(since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    switch seconds {
    case ..<60: return "\(seconds)s"
    case ..<3600: return "\(seconds / 60)min"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
}

/// Voyager's DaisyUI `light` / `dark` theme tokens from assets/css/app.css.
enum Theme {
    static let logo = adaptive(light: 0x001A72, dark: 0xECF9FF)
    static let base100 = adaptive(light: 0xFFFFFF, dark: 0x1D232A)
    static let base200 = adaptive(light: 0xF7F9FA, dark: 0x191E24)
    static let border = adaptive(light: 0xE2E8F0, dark: 0x2C3644)
    static let content = adaptive(light: 0x1A273A, dark: 0xECF9FF)
    static let muted = content.opacity(0.6)
    static let idle = content.opacity(0.35)
    static let error = Color(NSColor(hex: 0xFD6160))

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct VoyagerSwitchStyle: ToggleStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration, tint: tint)
    }

    /// Drawn by hand: the AppKit-backed `.switch` loses its tint when flipped while the popover is closed.
    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let isOn = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(isOn ? tint : Theme.content.opacity(0.18))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                            .padding(2)
                    }
                    .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.5)
            .pointingHandCursor()
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

/// Neutral at rest, filled with `hoverColor` on hover.
struct SmallButtonStyle: ButtonStyle {
    let hoverColor: Color

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, hoverColor: hoverColor)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let hoverColor: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? .white : Theme.content.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? hoverColor.opacity(configuration.isPressed ? 0.75 : 1) : Theme.content.opacity(0.08))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointingHandCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Color.green : Theme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(copied ? "Copied" : "Copy address")
        .accessibilityLabel("Copy address")
    }
}

struct Card<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: Text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.base100))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border))
    }
}

/// `.danger` rests grey and turns red on hover, for actions that end something.
struct VoyagerButtonStyle: ButtonStyle {
    enum Kind {
        case filled(Color)
        case danger
    }

    let kind: Kind
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
            let active = hovering || configuration.isPressed

            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground(active: active))
                .frame(maxWidth: compact ? nil : .infinity)
                .frame(minWidth: compact ? 26 : nil, minHeight: compact ? 26 : nil)
                .padding(.horizontal, compact ? 0 : 10)
                .padding(.vertical, compact ? 0 : 6)
                .background(shape.fill(background(active: active)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointingHandCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private func foreground(active: Bool) -> Color {
            switch kind {
            case .filled: return .white
            case .danger: return active ? Theme.error : Theme.content.opacity(0.85)
            }
        }

        private func background(active: Bool) -> Color {
            let pressed = configuration.isPressed
            switch kind {
            case .filled(let color): return color.opacity(pressed ? 0.75 : active ? 0.88 : 1)
            case .danger: return active ? Theme.error.opacity(pressed ? 0.25 : 0.16) : Theme.content.opacity(0.08)
            }
        }
    }
}

private var controller: TrayController?
private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
}()

@_cdecl("voyager_tray_setup")
public func voyagerTraySetup(
    _ iconBytes: UnsafePointer<UInt8>,
    _ iconLength: Int,
    _ version: UnsafePointer<CChar>,
    _ onAction: @escaping ActionCallback
) {
    guard let icon = NSImage(data: Data(bytes: iconBytes, count: iconLength)) else { return }
    controller = TrayController(icon: icon, version: String(cString: version), onAction: onAction)
}

@_cdecl("voyager_tray_update")
public func voyagerTrayUpdate(_ json: UnsafePointer<CChar>) {
    let data = Data(String(cString: json).utf8)
    guard let status = try? decoder.decode(TrayStatus.self, from: data) else { return }
    controller?.model.status = status
}
