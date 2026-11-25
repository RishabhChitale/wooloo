import AppKit
import CoreText
import SwiftUI

/// The pixel fonts of the Windows Herdr app's Ame (Jersey 15) and Mint Bot (Silkscreen) themes.
/// Both are SIL Open Font License fonts embedded in `PixelFontData`; they are registered for this
/// process on first use, so nothing is installed on the Mac.
enum PixelFont {
    static let jersey: String? = register(PixelFontData.jersey15)
    static let silkscreen: String? = register(PixelFontData.silkscreen)

    private static func register(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else { return nil }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterGraphicsFont(font, &error)
        return font.postScriptName as String?
    }
}

extension Notification.Name {
    /// Asks the Files and Changes sidebar to show "files" or "changes" (object: the tab id).
    static let woolooExplorerTab = Notification.Name("woolooExplorerTab")
}

// MARK: - Pixel look

extension WoolooTheme {
    var pixelFontName: String? {
        switch id {
        case "ame": return PixelFont.jersey
        case "mint": return PixelFont.silkscreen
        default: return nil
        }
    }

    /// True for the two themes that carry the Windows app's pixel look.
    var isPixel: Bool { pixelFontName != nil }

    /// Jersey 15 is small for its size; the Windows app bumps it as well.
    private var pixelBump: CGFloat { id == "ame" ? 4 : 0 }

    var ameTabRadius: CGFloat { id == "ame" ? 7 : 0 }
    var ameShortName: String { id == "mint" ? "Mint" : name }
    var ameArrowOpen: String { id == "mint" ? "-" : "v" }
    var ameArrowClosed: String { id == "mint" ? "+" : ">" }
    var ameBorderColor: Color { id == "mint" ? Self.color(0x2E8C86) : Self.color(0x4D5190) }
    var ameRaised: Color { Self.color(herdr.surface0) }
    var ameHover: Color { Self.color(herdr.surface1) }
    var ameSelected: Color { Self.color(herdr.activeRow) }

    /// The interface font: the theme's pixel font, or the system font for every other theme.
    func chromeFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = pixelFontName { return Font.custom(name, size: size + pixelBump) }
        return Font.system(size: size, weight: weight)
    }
}

// MARK: - Switching themes

enum ThemeSwitcher {
    /// Ame and Mint Bot exist only in wooloo and the Windows app: Herdr's own config rejects their
    /// names, so the choice is a wooloo preference and config.toml is left alone.
    static let pixelKey = "WoolooPixelTheme"
    static let pixelIDs: [String] = ["ame", "mint"]

    static var pixelOverride: String? {
        let value = UserDefaults.standard.string(forKey: pixelKey) ?? ""
        return value.isEmpty ? nil : value
    }

    @MainActor
    static func select(_ id: String) {
        if pixelIDs.contains(id) {
            UserDefaults.standard.set(id, forKey: pixelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pixelKey)
            writeConfigName(id)
        }
        NotificationCenter.default.post(name: .woolooLocalConfigSaved, object: nil)
    }

    /// Herdr's own themes go in `[theme] name`, as the settings screen writes them.
    private static func writeConfigName(_ id: String) {
        let url = HerdrConfigFile.url
        guard let old = try? HerdrConfigFile.read(at: url) else { return }
        var document = HerdrConfigDocument(text: old)
        document.setString(id, section: "theme", key: "name")
        document.setBool(false, section: "theme", key: "auto_switch")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? document.text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// "Theme: Ame": the Windows app's theme button. Opens the list; Ame and Mint Bot come first.
struct ThemeButton: View {
    @Environment(\.woolooTheme) private var theme
    @Environment(\.woolooTypography) private var typography
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("Theme: \(theme.ameShortName)")
                .font(theme.chromeFont(typography.caption, weight: .medium))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: theme.isPixel ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) { themeList }
        .help("Switch theme: Ame, Mint Bot and the other palettes")
        .accessibilityLabel("Theme")
        .accessibilityIdentifier("theme-button")
    }

    /// The theme list in the active theme's own style (pixel font, square rows) instead of a system menu.
    private var themeList: some View {
        let pixel = WoolooTheme.all.filter { ThemeSwitcher.pixelIDs.contains($0.id) }
        let others = WoolooTheme.all.filter { !ThemeSwitcher.pixelIDs.contains($0.id) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pixel) { option in row(option) }
                Rectangle().fill(theme.ameBorderColor).frame(height: 1).padding(.vertical, 4)
                ForEach(others) { option in row(option) }
            }
            .padding(6)
        }
        .frame(width: 210, height: 340)
        .background(theme.contentBackground)
        .overlay(Rectangle().strokeBorder(theme.ameBorderColor, lineWidth: theme.isPixel ? 2 : 1))
        .environment(\.woolooTheme, theme)
        .environment(\.woolooTypography, typography)
    }

    private func row(_ option: WoolooTheme) -> some View {
        let selected = option.id == theme.id
        return Button {
            ThemeSwitcher.select(option.id)
            open = false
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(option.accent).frame(width: 8, height: 8)
                Text(option.name)
                    .font(theme.chromeFont(typography.body))
                    .foregroundStyle(selected ? theme.accent : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected { Text("*").foregroundStyle(theme.accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.ameSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The footer's branch name: the current branch of the selected pane's folder for local Spaces,
/// or the branch the PC's shim reported for a PC Space.
struct FooterBranchLabel: View {
    let cwd: String?
    let local: Bool
    var remoteBranch: String? = nil
    @State private var branch: String?

    var body: some View {
        Group {
            if let branch {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch).lineLimit(1)
                }
            }
        }
        .task(id: (cwd ?? "") + "|" + (remoteBranch ?? "")) {
            while !Task.isCancelled {
                var found: String? = nil
                if local {
                    found = await FooterBranchLabel.lookup(cwd)
                } else if let remoteBranch, !remoteBranch.isEmpty {
                    found = remoteBranch
                }
                if found != branch { branch = found }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private static func lookup(_ cwd: String?) async -> String? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", cwd, "symbolic-ref", "--quiet", "--short", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }.value
    }
}

struct AmeToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let status: String
}

/// In-app toasts in the pixel style: an agent now needs you, or finished.
struct AmeToastHost: View {
    let agents: [HerdrAgent]
    @Environment(\.woolooTheme) private var theme
    @Environment(\.woolooTypography) private var typography
    @State private var seen: [String: String] = [:]
    @State private var toasts: [AmeToast] = []

    private var signature: [String] { agents.map { "\($0.paneID)=\($0.agentStatus ?? "")" } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Rectangle().fill(theme.agentStatus(toast.status)).frame(width: 8, height: 8)
                    Text(toast.text).lineLimit(2)
                }
                .font(theme.chromeFont(typography.secondary))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.ameRaised)
                .overlay(Rectangle().strokeBorder(theme.ameBorderColor, lineWidth: 2))
                .onTapGesture { toasts.removeAll { $0.id == toast.id } }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onAppear { remember() }
        .onChange(of: signature) { _, _ in update() }
    }

    private func remember() {
        var next: [String: String] = [:]
        for agent in agents { next[agent.paneID] = agent.agentStatus ?? "" }
        seen = next
    }

    private func update() {
        var next: [String: String] = [:]
        for agent in agents {
            let status = agent.agentStatus ?? ""
            next[agent.paneID] = status
            guard let old = seen[agent.paneID], old != status, (status == "blocked" || status == "done") else { continue }
            let text = status == "blocked" ? "\(agent.displayName) needs you" : "\(agent.displayName) finished"
            let toast = AmeToast(text: text, status: status)
            toasts.append(toast)
            if toasts.count > 4 { toasts.removeFirst() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                toasts.removeAll { $0.id == toast.id }
            }
        }
        seen = next
    }
}
