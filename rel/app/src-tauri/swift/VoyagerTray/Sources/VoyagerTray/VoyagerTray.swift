// Menu bar icon and SwiftUI status popover, driven from Rust through the C functions at the bottom.
import AppKit
import SwiftUI

public typealias ActionCallback = @convention(c) (UnsafePointer<CChar>) -> Void

struct TrayStatus: Decodable {
    var node: String?
    var nodeLost = false
    var connector: String?
    var connectedAt: Date?
    var mcpUrl: String?
}

final class TrayModel: ObservableObject {
    @Published var status: TrayStatus?
    /// The user's System Settings accent; SwiftUI's `Color.accentColor` is the app's own, which defaults to blue.
    @Published var accent = TrayModel.systemAccent()
    let version: String
    let send: (String) -> Void

    init(version: String, send: @escaping (String) -> Void) {
        self.version = version
        self.send = send

        let refresh: (Notification) -> Void = { [weak self] _ in self?.accent = TrayModel.systemAccent() }
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main, using: refresh)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main,
            using: refresh)
    }

    private static func systemAccent() -> Color {
        Color(NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor)
    }
}

final class TrayController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    let model: TrayModel

    init(icon: NSImage, version: String, onAction: @escaping ActionCallback) {
        var close: () -> Void = {}
        model = TrayModel(version: version) { action in
            if action == "open" || action == "quit" { close() }
            action.withCString(onAction)
        }
        super.init()
        close = { [weak self] in self?.popover.performClose(nil) }

        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle(_:))

        let hosting = NSHostingController(rootView: TrayView(model: model, logo: icon))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = hosting
        if #available(macOS 14.0, *) {
            popover.hasFullSizeContent = true
        }
        popover.behavior = .transient
        popover.animates = true
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
        popover.contentViewController?.view.window?.makeKey()
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
                    .foregroundColor(Theme.logo)
                    .frame(width: 20, height: 20)
                Text("Voyager")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.version)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)

            SectionLabel(title: "Status")
            nodeCard
            mcpCard

            HStack(spacing: 8) {
                Button("Open Voyager") { model.send("open") }
                    .buttonStyle(VoyagerButtonStyle(kind: .filled(model.accent)))
                Button("Quit") { model.send("quit") }
                    .buttonStyle(VoyagerButtonStyle(kind: .danger))
                    .frame(width: 84)
            }
            .padding(.top, 4)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .tint(model.accent)
        .foregroundColor(Theme.content)
        .padding(12)
        .frame(width: 300)
        .background(Theme.base200.ignoresSafeArea())
    }

    @ViewBuilder private var nodeCard: some View {
        let status = model.status
        if let node = status?.node, status?.nodeLost == true {
            Card(symbol: "antenna.radiowaves.left.and.right.slash", tint: Theme.idle, title: node, subtitle: Text("Connection lost")) {}
        } else if let node = status?.node {
            Card(symbol: "antenna.radiowaves.left.and.right", tint: model.accent, title: node, subtitle: connectedSubtitle(status)) {
                Button { model.send("disconnect") } label: {
                    Image(systemName: "power").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(VoyagerButtonStyle(kind: .danger, compact: true))
                .help("Disconnect")
                .accessibilityLabel("Disconnect")
            }
        } else {
            Card(
                symbol: "antenna.radiowaves.left.and.right.slash",
                tint: Theme.idle,
                title: status == nil ? "Starting…" : "Not connected",
                subtitle: Text("Connect to a node from Voyager")
            ) {}
        }
    }

    private var mcpCard: some View {
        let url = model.status?.mcpUrl
        return Card(
            symbol: "sparkles",
            tint: url == nil ? Theme.idle : model.accent,
            title: "MCP server",
            subtitle: Text(url.map { $0.replacingOccurrences(of: "http://", with: "") } ?? "Stopped")
        ) {
            Toggle("MCP server", isOn: Binding(get: { url != nil }, set: { _ in model.send("toggle_mcp") }))
                .disabled(model.status == nil)
                .pointingHandCursor()
        }
    }

    private func connectedSubtitle(_ status: TrayStatus?) -> Text {
        let via = Text(status?.connector ?? "Connected")
        guard let since = status?.connectedAt else { return via }
        return via + Text(" · ") + Text(since, style: .relative)
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
    static let error = Color(hex: 0xFD6160)

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

extension Color {
    init(hex: UInt32) {
        self.init(NSColor(hex: hex))
    }
}

extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(Theme.muted)
            .padding(.horizontal, 2)
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
                .foregroundColor(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.muted)
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
                .foregroundColor(foreground(active: active))
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
