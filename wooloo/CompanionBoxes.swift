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
    static let skinKey = "companionSkin"

    static func skinID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: skinKey) ?? CompanionManifest.defaultSkin
    }

    static func setSkinID(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: skinKey)
    }

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

/// The small gear in the room's corner that opens the webcam settings.
struct CompanionGearButton<Settings: View>: View {
    @Binding var isPresented: Bool
    let settings: Settings

    init(isPresented: Binding<Bool>, @ViewBuilder settings: () -> Settings) {
        _isPresented = isPresented
        self.settings = settings()
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 9))
                .foregroundStyle(CompanionPalette.indigo)
                .frame(width: 16, height: 16)
                .background(CompanionPalette.panel)
                .overlay(Rectangle().strokeBorder(CompanionPalette.indigo, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(3)
        .help("Webcam Settings")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { settings }
    }
}

/// "Webcam Settings": which skin she wears. The tiles show a still of each skin's idle sequence.
struct CompanionWebcamSettings: View {
    @ObservedObject var model: CompanionModel
    @Binding var isPresented: Bool
    @AppStorage(CompanionPreferences.skinKey) private var skin = CompanionManifest.defaultSkin
    @Environment(\.woolooTypography) private var typography

    var body: some View {
        // The [x] of the chrome closes the window.
        CompanionBox(title: "Webcam Settings", fontName: model.fontName,
                     collapsed: Binding(get: { false }, set: { _ in isPresented = false })) {
            if let manifest = model.manifest {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Skin")
                        .font(CompanionFont.font(model.fontName, size: typography.secondary))
                        .foregroundStyle(CompanionPalette.indigo)
                    HStack(spacing: 4) {
                        ForEach(manifest.skinChoices, id: \.id) { choice in
                            let selected = manifest.resolvedSkin(skin) == choice.id
                            Button { skin = choice.id } label: {
                                VStack(spacing: 3) {
                                    Group {
                                        if let path = manifest.previewPath(skin: choice.id),
                                           let image = model.image(forPath: path) {
                                            Image(decorative: image, scale: 1).interpolation(.none).resizable()
                                                .aspectRatio(contentMode: .fit)
                                        } else {
                                            Color.clear
                                        }
                                    }
                                    .frame(width: 64, height: 44)
                                    Text(choice.label)
                                        .font(CompanionFont.font(model.fontName, size: typography.caption))
                                        .foregroundStyle(CompanionPalette.indigo)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .padding(4)
                                .background(selected ? CompanionPalette.highlight : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(CompanionPalette.indigo.opacity(selected ? 1 : 0.3), lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(choice.label)
                        }
                    }
                }
            }
        }
        .frame(width: 250)
        .padding(4)
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

/// The commander's last messages, her face and stickers, and a field to write to the commander.
/// Sending goes to the commander agent of the selected Space through Herdr.
struct CompanionJineBox: View {
    @ObservedObject var model: CompanionModel
    let commander: HerdrAgent?
    let store: HerdrStore
    @AppStorage(CompanionPreferences.jineCollapsedKey) private var collapsed = false
    @State private var draft = ""
    @State private var sending = false
    @Environment(\.woolooTypography) private var typography

    private var canSend: Bool { commander != nil && store.isConnected && !sending }

    var body: some View {
        if let manifest = model.manifest {
            CompanionBox(title: "JINE", fontName: model.fontName, collapsed: $collapsed) {
                VStack(spacing: 6) {
                    messagePanel
                    HStack(spacing: 6) {
                        face(manifest)
                        stickerStrip(manifest.stickers)
                    }
                    composer
                    if let error = model.sendError {
                        Text(error)
                            .font(.system(size: typography.caption))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var messagePanel: some View {
        VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(model.messages.enumerated()), id: \.offset) { index, message in
                            bubble(message).id(index)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.messages) { _, messages in
                    if !messages.isEmpty { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                }
                .onAppear {
                    if !model.messages.isEmpty { proxy.scrollTo(model.messages.count - 1, anchor: .bottom) }
                }
            }
            .frame(height: 118)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CompanionMessage.lastSent(model.messages.last?.time, now: context.date) ?? " ")
                    .font(.system(size: typography.caption))
                    .foregroundStyle(CompanionPalette.indigo.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 5)
            }
        }
        .background(CompanionPalette.messages, in: RoundedRectangle(cornerRadius: 4))
    }

    private func bubble(_ message: CompanionMessage) -> some View {
        let mine = message.role == .user
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 24) }
            Text(message.displayText)
                .font(CompanionFont.font(model.fontName, size: typography.caption))
                .foregroundStyle(Color(red: 0.2, green: 0.15, blue: 0.3))
                .multilineTextAlignment(mine ? .trailing : .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(mine ? Color.white : CompanionPalette.titleBar, in: RoundedRectangle(cornerRadius: 7))
            if !mine { Spacer(minLength: 24) }
        }
    }

    private func face(_ manifest: CompanionManifest) -> some View {
        let path = manifest.activity(id: "idle")?.icon ?? "activities/idle.png"
        return Group {
            if let image = model.image(forPath: path) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: 34, height: 34)
    }

    private func stickerStrip(_ stickers: [CompanionSticker]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(stickers) { sticker in
                    Button { submit(sticker.label, clearsDraft: false) } label: {
                        Group {
                            if let image = model.image(forPath: sticker.image) {
                                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Text(sticker.label).font(.system(size: typography.caption))
                            }
                        }
                        .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.5)
                    .help("Send “\(sticker.label)”")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
    }

    private var composer: some View {
        HStack(spacing: 4) {
            TextField("Message Ame-chan…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: typography.secondary))
                .padding(.horizontal, 6)
                .frame(height: typography.metric(22))
                .background(Color.white)
                .overlay(Rectangle().strokeBorder(CompanionPalette.indigo, lineWidth: 1))
                .onSubmit { submit(draft, clearsDraft: true) }
            Button { submit(draft, clearsDraft: true) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(CompanionPalette.indigo)
                    .frame(width: 24, height: typography.metric(22))
                    .background(CompanionPalette.highlight, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(commander == nil ? "No commander in this Space" : "Send to the commander")
        }
        .opacity(canSend ? 1 : 0.6)
    }

    /// Only Enter, the send button or a sticker send; losing focus never does.
    private func submit(_ text: String, clearsDraft: Bool) {
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            let sent = await model.send(text, to: commander, via: store)
            sending = false
            if sent, clearsDraft, draft == text { draft = "" }
        }
    }
}

/// Her room, and the boxes under it, in a scroll view when they are taller than `maxHeight`.
/// Draws nothing when there is no manifest.
struct CompanionPanel: View {
    let store: HerdrStore
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
                        CompanionJineBox(model: model, commander: commander, store: store)
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
