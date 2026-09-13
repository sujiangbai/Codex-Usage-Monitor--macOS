import AppKit
import SwiftUI

// Mask the native backdrop itself: layer cornerRadius alone does not clip the
// WindowServer material, and can leave opaque rectangles outside rounded corners.
final class QuotaGlassContainer: NSView {
    let material = NSVisualEffectView()
    private let content: NSView
    private var accessibilityObserver: NSObjectProtocol?
    override var isOpaque: Bool { false }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        material.material = .hudWindow
        material.appearance = NSAppearance(named: .vibrantLight)
        material.blendingMode = .behindWindow
        material.state = .active
        material.isEmphasized = false
        addSubview(material)
        addSubview(content)
        updateTransparency()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateTransparency() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) } }

    private func updateTransparency() {
        // Only the background becomes more transparent. Text and controls stay opaque.
        material.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.72
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        content.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        material.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
            return true
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = CGPath(roundedRect: bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
        layer?.mask = mask
    }
}

private enum GlassPalette {
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.16)
    static let secondary = Color(red: 0.33, green: 0.35, blue: 0.33)
    static let graphite = Color(red: 0.38, green: 0.40, blue: 0.38)
}

private struct GlassSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(red: 0.95, green: 0.95, blue: 0.94)
            } else {
                Color.white.opacity(0.025)
            }
            RoundedRectangle(cornerRadius: 18).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.44), .white.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            RoundedRectangle(cornerRadius: 16.5).inset(by: 1.5)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }.clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct GlassButtonStyle: ButtonStyle {
    var primary = false
    var selected = false
    var textOnly = false
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, primary: primary, selected: selected, textOnly: textOnly)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    let selected: Bool
    let textOnly: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        configuration.label
            .foregroundStyle(primary ? Color.white : GlassPalette.ink)
            .background {
                if !textOnly || hovered || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(primary ? GlassPalette.graphite.opacity(0.90) : Color.white.opacity(selected ? 0.55 : (textOnly ? 0.15 : 0.25)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).fill(LinearGradient(
                                colors: [.white.opacity(configuration.isPressed ? 0.04 : (hovered ? 0.34 : 0.20)), .white.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(textOnly ? 0.15 : 0.42), lineWidth: 0.6)
                        }
                        .shadow(color: .black.opacity(textOnly ? 0 : 0.055), radius: 2, y: 1)
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct QuotaIdentity: View {
    var body: some View {
        ZStack {
            Circle().trim(from: 0.02, to: 0.68).stroke(GlassPalette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Circle().trim(from: 0.73, to: 0.98).stroke(GlassPalette.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }.rotationEffect(.degrees(-70)).frame(width: 15, height: 15).padding(0.5).accessibilityHidden(true)
    }
}

// Custom glass buttons retain explicit keyboard activation on macOS 13 as well
// as newer systems. The monitor is scoped to this attached panel only.
private struct GlassKeyboardActivation: NSViewRepresentable {
    let activate: () -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.activate = activate }
    final class KeyView: NSView {
        var activate: () -> Bool = { false }
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, event.window == nil || event.window === window,
                      event.keyCode == 49 || event.keyCode == 36,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                return self.activate() ? nil : event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct QuotaPanel: View {
    @ObservedObject var model: QuotaModel
    var width: CGFloat = 334
    @FocusState private var focused: String?

    var body: some View {
        let currentFocus = focused
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                QuotaIdentity()
                Text("Codex Usage Monitor").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .regular)).frame(width: 28, height: 28)
                }.buttonStyle(GlassButtonStyle()).disabled(!model.canRefresh)
                    .help("刷新（请求间隔至少 10 秒）").accessibilityLabel("刷新")
                    .accessibilityValue(model.loading ? "正在查询额度" : "")
                    .glassFocus("refresh", selection: $focused).focusOutline(focused == "refresh")
            }
            if !model.monitoringAllowed {
                Text("开始监控前").font(.system(size: 12, weight: .medium)).padding(.top, 14)
                Text("通过本机 Codex 查询当前登录账号的额度，每 5 分钟刷新。仅在本机显示，不向本项目开发者上传，也不保存额度历史。")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                Text("Codex 负责认证与联网，可能维护自身配置、认证状态和日志。请仅查看你有权使用的账号。可随时停止监控。")
                    .font(.system(size: 11)).foregroundStyle(GlassPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                Text("独立项目，非 OpenAI 官方产品。")
                    .font(.system(size: 11)).foregroundStyle(GlassPalette.secondary).padding(.top, 7)
                HStack {
                    Button(action: model.openPrivacy) { Text("隐私说明").frame(minHeight: 28) }
                        .buttonStyle(GlassButtonStyle(textOnly: true))
                        .glassFocus("privacy", selection: $focused).focusOutline(focused == "privacy")
                    Spacer()
                    Button(action: model.allowMonitoring) { Text("开始监控").frame(width: 112, height: 28) }
                        .buttonStyle(GlassButtonStyle(primary: true))
                        .glassFocus("consent", selection: $focused).focusOutline(focused == "consent")
                }.font(.system(size: 12)).padding(.top, 12)
                separator.padding(.top, 12)
                HStack { Spacer(); quitButton }.padding(.top, 6)
            } else {
                Text("菜单栏显示").font(.system(size: 11)).foregroundStyle(GlassPalette.secondary).padding(.top, 5)
                HStack(spacing: 0) {
                    ForEach(QuotaPeriod.allCases, id: \.self) { period in
                        Button { model.choose(period) } label: {
                            Text(period.title).font(.system(size: 12, weight: model.selected == period ? .medium : .regular))
                                .frame(maxWidth: .infinity).frame(height: 24)
                        }.buttonStyle(GlassButtonStyle(selected: model.selected == period, textOnly: model.selected != period))
                            .accessibilityLabel("菜单栏显示：\(period.title)")
                            .accessibilityAddTraits(model.selected == period ? .isSelected : [])
                            .glassFocus(period.rawValue, selection: $focused).focusOutline(focused == period.rawValue)
                    }
                }.padding(2).frame(height: 28)
                    .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.30), lineWidth: 0.6))
                    .padding(.top, 5)

                VStack(spacing: 14) {
                    quotaRow(model.selected, prominent: true)
                    let other: QuotaPeriod = model.selected == .weekly ? .fiveHour : .weekly
                    if model.bucket?.window(for: other) != nil { quotaRow(other, prominent: false) }
                }.padding(.top, 14)

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(GlassPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                } else if model.isStale && !model.loading && model.bucket != nil {
                    Text("数据已过期，请刷新后查看。").font(.system(size: 12))
                        .foregroundStyle(GlassPalette.secondary).padding(.top, 12)
                }

                separator.padding(.top, 14)
                if !model.startupChosen {
                    Text("登录 Mac 时自动启动？").font(.system(size: 12, weight: .medium)).padding(.top, 12)
                    Text("以后也可以随时更改。").font(.system(size: 11)).foregroundStyle(GlassPalette.secondary).padding(.top, 4)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button { model.chooseStartup(false) } label: {
                            Text("暂不开启").frame(width: 112, height: 28)
                        }.buttonStyle(GlassButtonStyle()).glassFocus("skip", selection: $focused).focusOutline(focused == "skip")
                        Button { model.chooseStartup(true) } label: {
                            Text("开启自动启动").frame(width: 140, height: 28)
                        }.buttonStyle(GlassButtonStyle(primary: true)).glassFocus("enable", selection: $focused).focusOutline(focused == "enable")
                    }.font(.system(size: 12, weight: .medium)).padding(.top, 10)
                    loginStatus
                    separator.padding(.top, 16)
                    HStack { Spacer(); quitButton }.padding(.top, 6)
                } else {
                    HStack(spacing: 8) {
                        Text("登录 Mac 时启动").font(.system(size: 12))
                        Toggle("登录 Mac 时启动", isOn: Binding(get: { model.loginEnabled || model.loginNeedsApproval }, set: { model.chooseStartup($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .glassFocus("login", selection: $focused).focusOutline(focused == "login")
                        Spacer(minLength: 16)
                        quitButton
                    }.padding(.top, 8)
                    loginStatus
                }
                HStack {
                    Button(action: model.openPrivacy) { Text("隐私说明").frame(minHeight: 28) }
                        .buttonStyle(GlassButtonStyle(textOnly: true))
                        .glassFocus("privacy", selection: $focused).focusOutline(focused == "privacy")
                    Spacer()
                    Button(action: model.withdrawMonitoring) { Text("停止监控").frame(minHeight: 28) }
                        .buttonStyle(GlassButtonStyle(textOnly: true))
                        .glassFocus("stop", selection: $focused).focusOutline(focused == "stop")
                }.font(.system(size: 11)).foregroundStyle(GlassPalette.secondary).padding(.top, 6)
            }
        }.padding(14).frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(GlassPalette.ink)
            .background(GlassSurface())
            .background(GlassKeyboardActivation(activate: { activateFocused(currentFocus) }))
            .environment(\.colorScheme, .light)
            .onChange(of: model.monitoringAllowed) { _ in focused = nil }
    }

    private func activateFocused(_ focused: String?) -> Bool {
        guard let focused else { return false }
        if let period = QuotaPeriod(rawValue: focused) { model.choose(period); return true }
        switch focused {
        case "consent": model.allowMonitoring()
        case "stop": model.withdrawMonitoring()
        case "privacy": model.openPrivacy()
        case "refresh": if !model.loading { model.refresh() }
        case "skip": model.chooseStartup(false)
        case "enable": model.chooseStartup(true)
        case "login": model.chooseStartup(!(model.loginEnabled || model.loginNeedsApproval))
        case "settings": model.openLoginSettings()
        case "quit": NSApplication.shared.terminate(nil)
        default: return false
        }
        return true
    }

    private var separator: some View {
        Rectangle().fill(GlassPalette.secondary.opacity(0.13)).frame(height: 0.5)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.24)).frame(height: 0.5).offset(y: 0.5) }
    }

    private var quitButton: some View {
        Button { NSApplication.shared.terminate(nil) } label: {
            Text("退出").font(.system(size: 12)).foregroundStyle(GlassPalette.secondary).frame(width: 30, height: 28)
        }.buttonStyle(GlassButtonStyle(textOnly: true)).keyboardShortcut("q")
            .glassFocus("quit", selection: $focused).focusOutline(focused == "quit")
    }

    @ViewBuilder private var loginStatus: some View {
        if model.loginNeedsApproval || model.loginError != nil {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.loginError ?? "请在系统设置中允许此登录项。")
                    .font(.system(size: 11)).foregroundStyle(GlassPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开登录项设置", action: model.openLoginSettings).font(.system(size: 11))
                    .glassFocus("settings", selection: $focused).focusOutline(focused == "settings")
            }.padding(.top, 10)
        }
    }

    @ViewBuilder private func quotaRow(_ period: QuotaPeriod, prominent: Bool) -> some View {
        let window = model.bucket?.window(for: period)
        let valid = !model.isStale && model.errorMessage == nil && !(window?.hasElapsed(at: model.now) ?? false)
        let remaining = valid ? window?.remaining : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(period.title)额度").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(remaining.map { "\($0)%" } ?? "—").font(.system(size: prominent ? 28 : 19, weight: .medium)).monospacedDigit()
                Text("剩余").font(.system(size: 11)).foregroundStyle(GlassPalette.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(GlassPalette.graphite.opacity(0.15))
                    if let remaining {
                        Capsule().fill(remaining <= 10 ? Color.orange : GlassPalette.graphite.opacity(0.85))
                            .frame(width: proxy.size.width * CGFloat(remaining) / 100)
                    }
                }
            }.frame(height: prominent ? 5 : 4).padding(.top, 7)
                .accessibilityLabel("\(period.title)剩余").accessibilityValue(remaining.map { "\($0)%" } ?? "暂不可用")
            Text(window.map { resetDescription($0, now: model.now) } ?? (model.loading ? "正在查询…" : "当前未返回此周期额度"))
                .font(.system(size: 11)).foregroundStyle(GlassPalette.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }
}

private extension View {
    @ViewBuilder
    func glassFocus(_ key: String, selection: FocusState<String?>.Binding) -> some View {
        if #available(macOS 14, *) {
            focusable().focused(selection, equals: key).focusEffectDisabled()
        } else {
            focusable().focused(selection, equals: key).tint(GlassPalette.graphite)
        }
    }
    func focusOutline(_ visible: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(GlassPalette.graphite.opacity(visible ? 0.65 : 0), lineWidth: 1).padding(-1).allowsHitTesting(false))
    }
}
