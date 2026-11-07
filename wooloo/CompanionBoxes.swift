import AppKit
import SwiftUI

// The panel at the top of the right sidebar: her room and, under it, boxes in the style of a
// Nintendo Switch Online window. Everything is read from the local companion folder.

/// The user's choices, kept in UserDefaults. The views read the same keys with `@AppStorage`.
enum CompanionPreferences {
    static let activityKey = "companionActivity"
    static let activitiesCollapsedKey = "companionActivitiesCollapsed"
    static let jineCollapsedKey = "companionJineCollapsed"
    static let defaultActivity = "idle"

    static func activityID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: activityKey) ?? defaultActivity
    }

    static func setActivityID(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: activityKey)
    }

    static func isCollapsed(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setCollapsed(_ collapsed: Bool, key: String, defaults: UserDefaults = .standard) {
        defaults.set(collapsed, forKey: key)
    }
}

enum CompanionPalette {
    static let frame = Color(red: 0.36, green: 0.84, blue: 0.90)
    static let titleBar = Color(red: 0.79, green: 0.72, blue: 0.96)
    static let indigo = Color(red: 0.29, green: 0.24, blue: 0.64)
    static let panel = Color(red: 0.97, green: 0.95, blue: 1.0)
    static let highlight = Color(red: 0.84, green: 0.76, blue: 0.98)
    static let messages = Color(red: 0.86, green: 0.93, blue: 1.0)
}

enum CompanionFont {
    /// The skin's pixel font when the manifest has one, else the system rounded font.
    static func font(_ name: String?, size: CGFloat) -> Font {
        if let name { return .custom(name, size: size) }
        return .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// The window chrome: a cyan frame, a lilac title bar with an indigo square, the title and a [x]
/// button that collapses the box to its title bar, and a white-lilac panel with an indigo border.
struct CompanionBox<Content: View>: View {
    let title: String
    let fontName: String?
    @Binding var collapsed: Bool
    let content: Content
    @Environment(\.woolooTypography) private var typography

    init(title: String, fontName: String?, collapsed: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.fontName = fontName
        _collapsed = collapsed
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Rectangle().fill(CompanionPalette.indigo).frame(width: 7, height: 7)
                Text(title)
                    .font(CompanionFont.font(fontName, size: typography.secondary))
                    .foregroundStyle(CompanionPalette.indigo)
                Spacer(minLength: 0)
                Button { collapsed.toggle() } label: {
                    Text(collapsed ? "+" : "x")
                        .font(CompanionFont.font(fontName, size: typography.caption))
                        .foregroundStyle(CompanionPalette.indigo)
                        .frame(width: 14, height: 14)
                        .background(CompanionPalette.panel)
                        .overlay(Rectangle().strokeBorder(CompanionPalette.indigo, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
            }
            .padding(.horizontal, 6)
            .frame(height: typography.metric(20))
            .background(CompanionPalette.titleBar, in: RoundedRectangle(cornerRadius: 3))
            if !collapsed {
                content
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(CompanionPalette.panel)
                    .overlay(Rectangle().strokeBorder(CompanionPalette.indigo, lineWidth: 1))
            }
        }
        .padding(3)
        .background(CompanionPalette.frame, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Icons of what she does in her free time. The commander's work comes first: the chosen
/// activity plays only while the commander is idle or done.
struct CompanionActivitiesBox: View {
    @ObservedObject var model: CompanionModel
    @AppStorage(CompanionPreferences.activitiesCollapsedKey) private var collapsed = false
    @AppStorage(CompanionPreferences.activityKey) private var selected = CompanionPreferences.defaultActivity
    @Environment(\.woolooTypography) private var typography

    var body: some View {
        if let activities = model.manifest?.activities, !activities.isEmpty {
            CompanionBox(title: "Activities", fontName: model.fontName, collapsed: $collapsed) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(activities) { activity in
                        let available = activity.mood != nil
                        Button { selected = activity.id } label: {
                            VStack(spacing: 2) {
                                Group {
                                    if let icon = model.image(forPath: activity.icon) {
                                        Image(decorative: icon, scale: 1)
                                            .interpolation(.none)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 36, height: 36)
                                Text(activity.label)
                                    .font(CompanionFont.font(model.fontName, size: typography.caption))
                                    .foregroundStyle(CompanionPalette.indigo)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(selected == activity.id && available ? CompanionPalette.highlight : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        .opacity(available ? 1 : 0.45)
                        .help(available ? activity.label : "\(activity.label) — Soon")
                    }
                }
            }
        }
    }
}

/// Her room, and the boxes under it, in a scroll view when they are taller than `maxHeight`.
/// Draws nothing when there is no manifest.
struct CompanionPanel: View {
    let agents: [HerdrAgent]
    let workspaceID: String?
    /// The sidebar's width.
    let width: CGFloat
    /// The tallest the panel may be before it scrolls.
    let maxHeight: CGFloat
    @StateObject private var model = CompanionModel()
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if model.manifest != nil {
            let commander = CompanionMood.commander(in: agents, workspaceID: workspaceID)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        CompanionView(model: model, commander: commander, width: width - 14)
                        CompanionActivitiesBox(model: model)
                    }
                    .padding(7)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                                contentHeight = height
                            }
                        }
                    }
                }
                .frame(height: min(contentHeight, max(maxHeight, 120)))
                Divider()
            }
        }
    }
}
