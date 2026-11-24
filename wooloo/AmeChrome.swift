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

    var body: some View {
        Menu {
            ForEach(WoolooTheme.all.filter { ThemeSwitcher.pixelIDs.contains($0.id) }) { option in
                item(option)
            }
            Divider()
            ForEach(WoolooTheme.all.filter { !ThemeSwitcher.pixelIDs.contains($0.id) }) { option in
                item(option)
            }
        } label: {
            Text("Theme: \(theme.ameShortName)")
                .font(theme.chromeFont(typography.caption, weight: .medium))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: theme.isPixel ? 2 : 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch theme: Ame, Mint Bot and the other palettes")
        .accessibilityLabel("Theme")
        .accessibilityIdentifier("theme-button")
    }

    @ViewBuilder
    private func item(_ option: WoolooTheme) -> some View {
        Button {
            ThemeSwitcher.select(option.id)
        } label: {
            if option.id == theme.id {
                Label(option.name, systemImage: "checkmark")
            } else {
                Text(option.name)
            }
        }
    }
}
