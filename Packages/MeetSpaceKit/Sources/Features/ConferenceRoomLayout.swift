import SwiftUI
import MeetSpaceDesignSystem

enum ConferenceRoomColors {
    static let background = Color(red: 25 / 255, green: 21 / 255, blue: 31 / 255)
    static let surface = Color(red: 40 / 255, green: 34 / 255, blue: 48 / 255)
    static let line = Color(red: 73 / 255, green: 64 / 255, blue: 82 / 255)
    static let text = Color(red: 244 / 255, green: 239 / 255, blue: 247 / 255)
    static let muted = Color(red: 188 / 255, green: 176 / 255, blue: 199 / 255)
    static let selected = Color(red: 76 / 255, green: 55 / 255, blue: 91 / 255)
    static let activeBorder = Color(red: 169 / 255, green: 139 / 255, blue: 189 / 255)
    static let speaking = Color(red: 136 / 255, green: 219 / 255, blue: 180 / 255)
    static let leave = Color(red: 188 / 255, green: 33 / 255, blue: 58 / 255)
}

struct ConferenceRoomAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    var active = false
    var disabled = false
    var destructive = false
    let action: () -> Void
}

struct ConferenceRoomLayout<Header: View, Notice: View, Video: View, Panel: View>: View {
    let title: String
    let status: String
    var startedAt: Date?
    let panelVisible: Bool
    let back: () -> Void
    let actions: [ConferenceRoomAction]
    @ViewBuilder let headerActions: (Bool) -> Header
    @ViewBuilder let notice: () -> Notice
    @ViewBuilder let video: (Bool) -> Video
    @ViewBuilder let panel: () -> Panel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            let inset: CGFloat = wide ? 22 : 12
            let layout = wide ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 10))
            VStack(spacing: 0) {
                heading(wide: wide).padding(.horizontal, inset)
                notice().padding(.horizontal, inset)
                layout {
                    let showStage = wide || !panelVisible || (geometry.size.height >= 575 && !typeSize.isAccessibilitySize)
                    video(wide).frame(maxWidth: .infinity, maxHeight: showStage ? .infinity : 0)
                        .clipped().accessibilityHidden(!showStage)
                        .layoutPriority(wide ? 1 : 0)
                    if panelVisible {
                        panel().frame(maxWidth: wide ? min(350, max(260, geometry.size.width * 0.25)) : .infinity,
                                      maxHeight: .infinity)
                    }
                }.padding(.horizontal, inset).padding(.vertical, wide ? 16 : 10)
                toolbar(wide: wide).padding(.horizontal, inset)
            }.foregroundStyle(ConferenceRoomColors.text)
        }.background(ConferenceRoomColors.background.ignoresSafeArea())
    }

    private func heading(wide: Bool) -> some View {
        HStack(spacing: wide ? 12 : 7) {
            Button(action: back) {
                WorkspaceIcon("arrow.left", size: 21).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(ConferenceRoomColors.muted)
                .accessibilityLabel(tr("К списку встреч"))
                .accessibilityIdentifier("conferenceBack")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MSTheme.font(wide ? 18 : 15, weight: .semibold))
                    .lineLimit(2).accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.conference")
                Text(tr(status)).font(MSTheme.font(wide ? 12 : 10))
                    .foregroundStyle(ConferenceRoomColors.muted).accessibilityIdentifier("conferenceStatus")
            }.frame(maxWidth: .infinity, alignment: .leading)
            if wide, let startedAt {
                Text(startedAt, style: .timer).font(MSTheme.font(12)).monospacedDigit()
                    .foregroundStyle(ConferenceRoomColors.muted)
            }
            HStack(spacing: wide ? 8 : 5) { headerActions(wide && !typeSize.isAccessibilitySize) }
        }.padding(.top, wide ? 10 : 8).padding(.bottom, wide ? 15 : 12)
            .overlay(alignment: .bottom) { Rectangle().fill(ConferenceRoomColors.line).frame(height: 1) }
    }

    private func toolbar(wide: Bool) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView(.horizontal) { controls(wide: true).fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden)
            } else {
                controls(wide: wide).frame(maxWidth: wide ? nil : 540)
                    .fixedSize(horizontal: wide, vertical: false)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, wide ? 11 : 9)
            .overlay(alignment: .top) { Rectangle().fill(ConferenceRoomColors.line).frame(height: 1) }
    }

    private func controls(wide: Bool) -> some View {
        HStack(spacing: wide ? 6 : 7) {
            ForEach(actions) { control in
                Button(action: control.action) {
                    VStack(spacing: 5) {
                        WorkspaceIcon(control.icon, size: 19)
                        Text(tr(control.title))
                            .font(MSTheme.font(wide ? 11 : 10, relativeTo: .caption2))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .allowsTightening(true)
                    }.padding(.horizontal, wide ? 7 : 2)
                        .frame(minWidth: wide ? 76 : nil, maxWidth: wide ? nil : .infinity, minHeight: wide ? 55 : 53)
                        .background(control.destructive ? ConferenceRoomColors.leave :
                                        control.active ? ConferenceRoomColors.selected : ConferenceRoomColors.surface,
                                    in: RoundedRectangle(cornerRadius: wide ? 9 : 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: wide ? 9 : 16)
                                .strokeBorder(control.destructive ? .clear : control.active ? ConferenceRoomColors.activeBorder :
                                                ConferenceRoomColors.line)
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(control.disabled)
                    .opacity(control.disabled ? 0.6 : 1)
                    .accessibilityLabel(tr(control.title))
                    .accessibilityValue(tr(control.active ? "Включён" : "Выключен"))
                    .accessibilityIdentifier(control.id)
                    .accessibilityAddTraits(control.active ? .isSelected : [])
            }
        }.padding(wide ? 5 : 4)
            .background {
                if wide {
                    RoundedRectangle(cornerRadius: 13).fill(ConferenceRoomColors.surface)
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ConferenceRoomColors.line))
                }
            }
    }
}

struct ConferenceRoomHeaderLabel: View {
    let title: String
    let icon: String
    var expanded = false
    var iconColor: Color = ConferenceRoomColors.text

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceIcon(icon, size: 19).foregroundStyle(iconColor)
            if expanded {
                Text(tr(title)).font(MSTheme.font(12)).fixedSize(horizontal: true, vertical: false)
            }
        }.padding(.horizontal, expanded ? 12 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(ConferenceRoomColors.text)
            .background(ConferenceRoomColors.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConferenceRoomColors.line))
            .contentShape(Rectangle())
    }
}

struct ConferenceRoomRecordingButton: View {
    let title: String
    let status: String?
    let wide: Bool
    let open: () -> Void

    var body: some View {
        let recording = status == "recording" || status == "degraded"
        let color = recording ? Color(red: 1, green: 0.53, blue: 0.61) :
            (status == nil ? ConferenceRoomColors.text : Color(red: 0.93, green: 0.77, blue: 0.53))
        Button(action: open) {
            ConferenceRoomHeaderLabel(title: title, icon: recording ? "record.circle" : "circle", expanded: wide, iconColor: color)
        }.buttonStyle(.plain).accessibilityLabel(tr("Запись встречи")).accessibilityValue(tr(title))
            .accessibilityIdentifier("conferenceRecordings")
    }
}

struct ConferenceRoomAttendee: Identifiable, Equatable {
    let id: String
    let name: String
    let initials: String
    let tone: Tone
    var own = false
    var microphone = false
    var speaking = false

    enum Tone {
        case blue, amber, mint, violet
        var backdrop: Color {
            switch self {
            case .blue: Color(red: 0.19, green: 0.24, blue: 0.33)
            case .amber: Color(red: 0.274, green: 0.219, blue: 0.196)
            case .mint: Color(red: 0.16, green: 0.26, blue: 0.23)
            case .violet: Color(red: 0.23, green: 0.19, blue: 0.27)
            }
        }
        var avatarBackground: Color {
            switch self {
            case .blue: Color(red: 0.86, green: 0.90, blue: 1)
            case .amber: Color(red: 0.99, green: 0.90, blue: 0.81)
            case .mint: Color(red: 0.86, green: 0.95, blue: 0.91)
            case .violet: Color(red: 0.92, green: 0.87, blue: 0.98)
            }
        }
        var avatarText: Color {
            switch self {
            case .blue: Color(red: 0.20, green: 0.31, blue: 0.56)
            case .amber: Color(red: 0.47, green: 0.28, blue: 0.15)
            case .mint: Color(red: 0.15, green: 0.37, blue: 0.31)
            case .violet: Color(red: 0.36, green: 0.27, blue: 0.49)
            }
        }
    }
}

struct ConferenceRoomStage<Visual: View, ScreenShare: View>: View {
    let roster: [ConferenceRoomAttendee]
    let showSelf: Bool
    var ownCamera = false
    let wide: Bool
    let remoteScreen: Bool
    @ViewBuilder let visual: (ConferenceRoomAttendee, Bool) -> Visual
    @ViewBuilder let screenShare: () -> ScreenShare
    @State private var selectedLayout: Layout?
    @State private var pinnedID: String?
    @State private var railPage: Int? = 0

    private enum Layout { case gallery, speaker }
    private var attendees: [ConferenceRoomAttendee] { showSelf ? roster : roster.filter { !$0.own } }
    private var mode: Layout { selectedLayout ?? (wide ? .gallery : .speaker) }
    private var pinned: ConferenceRoomAttendee? { attendees.first { $0.id == pinnedID } }
    private var featured: ConferenceRoomAttendee? {
        pinned ?? attendees.first(where: \.speaking) ?? attendees.first { !$0.own } ?? attendees.first
    }
    private var ordered: [ConferenceRoomAttendee] {
        attendees.filter(\.speaking) + attendees.filter { !$0.speaking && !$0.own } + attendees.filter { !$0.speaking && $0.own }
    }
    private var countLabel: String {
        let count = roster.count, tens = count % 100, ones = count % 10
        let noun = if (11...14).contains(tens) { "участников" }
            else if ones == 1 { "участник" }
            else if (2...4).contains(ones) { "участника" }
            else { "участников" }
        return "\(count) \(tr(noun))"
    }

    var body: some View {
        VStack(spacing: wide ? 12 : 10) {
            viewBar.frame(maxWidth: wide ? nil : 540)
            GeometryReader { geometry in
                let width = min(geometry.size.width, wide ? geometry.size.width : 540)
                ScrollView {
                    VStack(spacing: wide ? 10 : 8) {
                        if remoteScreen { screenShare() }
                        if mode == .speaker, let featured {
                            let stageWidth = featuredWidth(width, height: geometry.size.height)
                            speakerTile(featured, width: stageWidth)
                            speakerRail(ordered.filter { $0.id != featured.id }, width: stageWidth)
                        } else {
                            gallery(width: width, height: geometry.size.height)
                        }
                    }.frame(maxWidth: width)
                        .frame(minHeight: geometry.size.height)
                        .frame(maxWidth: .infinity)
                }.scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            }
        }
    }

    private var viewBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: wide ? 12 : 8) {
                layoutPicker
                Spacer(minLength: 0)
                participantCount.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                layoutPicker
                participantCount
            }
        }
    }

    private var participantCount: some View {
        HStack(spacing: 7) {
            WorkspaceIcon("person.2", size: 15)
            Text(countLabel).font(MSTheme.font(wide ? 12 : 10))
        }.foregroundStyle(ConferenceRoomColors.muted).accessibilityIdentifier("conferenceParticipantCount")
    }

    private var layoutPicker: some View {
        HStack(spacing: 3) {
            layoutButton(.gallery, label: "Сетка", icon: "square.grid.2x2", id: "conferenceLayoutGallery")
            layoutButton(.speaker, label: "Выступающий", icon: "person", id: "conferenceLayoutSpeaker")
        }.padding(4)
            .background(ConferenceRoomColors.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ConferenceRoomColors.line))
    }

    private func layoutButton(_ option: Layout, label: String, icon: String, id: String) -> some View {
        Button {
            if selectedLayout != option { railPage = 0 }
            selectedLayout = option
            if option == .gallery { pinnedID = nil }
        } label: {
            HStack(spacing: wide ? 7 : 5) {
                WorkspaceIcon(icon, size: 15)
                Text(tr(label)).font(MSTheme.font(wide ? 12 : 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, wide ? 10 : 5)
                .frame(maxWidth: wide ? nil : .infinity, minHeight: wide ? 36 : 38)
                .background(mode == option ? ConferenceRoomColors.selected.opacity(0.65) : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(mode == option ? ConferenceRoomColors.activeBorder.opacity(0.5) : .clear))
                .foregroundStyle(mode == option ? ConferenceRoomColors.text : ConferenceRoomColors.muted)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
            .accessibilityAddTraits(mode == option ? .isSelected : [])
    }

    private func featuredWidth(_ width: CGFloat, height: CGFloat) -> CGFloat {
        guard wide || height < 360 else { return width }
        let hasRail = attendees.count > 1
        let reserve: CGFloat = wide ? (hasRail ? 122 : 0) : (hasRail ? 90 : 0)
        return min(width, max(140, (height - reserve) * 16 / 9))
    }

    private func speakerTile(_ attendee: ConferenceRoomAttendee, width: CGFloat) -> some View {
        ZStack {
            backdrop(attendee)
            avatar(attendee, size: min(wide ? 100 : 62, max(wide ? 60 : 42, width * 0.14)), featured: true)
            visual(attendee, true)
                .frame(width: width, height: width * 9 / 16).allowsHitTesting(false)
        }.frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Text(attendee.name).lineLimit(1)
                    WorkspaceIcon(attendee.microphone ? "mic" : "mic.slash", size: 15)
                }.font(MSTheme.font(11)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(ConferenceRoomColors.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if pinned != nil {
                    Button {
                        pinnedID = nil
                    } label: {
                        badge("Открепить", icon: "pin", speaking: false)
                    }.buttonStyle(.plain).accessibilityLabel(tr("Открепить участника"))
                        .accessibilityIdentifier("conferenceUnpin")
                } else if attendee.speaking {
                    badge("Говорит", icon: "waveform", speaking: true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if ownCamera, !attendee.own, let own = attendees.first(where: \.own) {
                    ZStack {
                        backdrop(own)
                        avatar(own, size: 30)
                        visual(own, true).allowsHitTesting(false)
                    }.frame(width: wide ? 96 : 69, height: wide ? 64 : 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(8).accessibilityIdentifier("conferenceLocalVideo")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: wide ? 13 : 15))
            .overlay(RoundedRectangle(cornerRadius: wide ? 13 : 15).strokeBorder(ConferenceRoomColors.line))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conferenceFeaturedParticipant")
    }

    private func badge(_ title: String, icon: String, speaking: Bool) -> some View {
        HStack(spacing: 6) {
            WorkspaceIcon(icon, size: 14)
            Text(tr(title)).font(MSTheme.font(11, weight: .semibold)).lineLimit(1)
        }.padding(.horizontal, 10).frame(minHeight: speaking ? 30 : 44)
            .foregroundStyle(speaking ? ConferenceRoomColors.speaking : ConferenceRoomColors.text)
            .background(speaking ? Color(red: 0.10, green: 0.18, blue: 0.16) : ConferenceRoomColors.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(speaking ? ConferenceRoomColors.speaking.opacity(0.5) :
                                                                                    ConferenceRoomColors.activeBorder))
            .padding(10)
    }

    @ViewBuilder private func speakerRail(_ people: [ConferenceRoomAttendee], width: CGFloat) -> some View {
        if !people.isEmpty {
            let pageSize = 3
            let gap: CGFloat = wide ? 10 : 7
            let columns = min(pageSize, max(2, people.count))
            let gaps = CGFloat(columns - 1) * gap
            let railWidth = wide ? min(width, CGFloat(columns) * 82 * 16 / 9 + gaps) : width
            let tileWidth = max(0, (railWidth - gaps) / CGFloat(columns))
            let pages = stride(from: 0, to: people.count, by: pageSize).map { start in
                Array(people[start..<min(start + pageSize, people.count)])
            }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        HStack(spacing: gap) {
                            ForEach(page) { person in
                                tile(person, width: tileWidth, height: wide ? min(92, tileWidth * 9 / 16) : tileWidth, gallery: false)
                            }
                        }.frame(width: railWidth).id(index)
                    }
                }.scrollTargetLayout()
            }.frame(width: railWidth).scrollIndicators(.hidden).scrollTargetBehavior(.paging).scrollPosition(id: $railPage)
                .accessibilityIdentifier("conferenceSpeakerRail")
                .onChange(of: pages.count, initial: true) { _, count in
                    railPage = min(railPage ?? 0, count - 1)
                }
            if pages.count > 1 {
                HStack(spacing: 2) {
                    ForEach(pages.indices, id: \.self) { index in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { railPage = index }
                        } label: {
                            Circle().fill((railPage ?? 0) == index ? ConferenceRoomColors.text : ConferenceRoomColors.muted.opacity(0.45))
                                .frame(width: 6, height: 6).frame(minWidth: 30, minHeight: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(tr("Страница")) \(index + 1)")
                    }
                }
            }
        }
    }

    private func gallery(width: CGFloat, height: CGFloat) -> some View {
        let columns = attendees.count == 1 ? 1 : (wide && width >= 960 && attendees.count != 2 && attendees.count != 4 ? 3 : 2)
        let gap: CGFloat = wide ? 10 : 7
        let rows = max(1, min(columns == 3 ? 2 : 3, (attendees.count + columns - 1) / columns))
        let fittingWidth = max(90, (height - CGFloat(rows - 1) * gap) * 16 / (9 * CGFloat(rows)))
        let proposedWidth = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let tileWidth = wide ? min(proposedWidth, fittingWidth) : proposedWidth
        return VStack(spacing: gap) {
            ForEach(Array(stride(from: 0, to: ordered.count, by: columns)), id: \.self) { offset in
                HStack(spacing: gap) {
                    ForEach(ordered[offset..<min(offset + columns, ordered.count)]) { attendee in
                        tile(attendee, width: tileWidth, height: tileWidth * 9 / 16, gallery: true)
                    }
                }
            }
        }
    }

    private func tile(_ attendee: ConferenceRoomAttendee, width: CGFloat, height: CGFloat, gallery: Bool) -> some View {
        let corner: CGFloat = wide && gallery ? 15 : 12
        let shape = RoundedRectangle(cornerRadius: corner)
        return Button {
            pinnedID = attendee.id
            railPage = 0
            selectedLayout = .speaker
        } label: {
            ZStack {
                backdrop(attendee)
                avatar(attendee, size: min(wide && gallery ? 76 : 44, max(32, width * (wide && gallery ? 0.24 : 0.31))))
                    .padding(.bottom, wide && gallery ? 0 : 17)
                visual(attendee, false)
                    .frame(width: width, height: height).allowsHitTesting(false)
            }.frame(width: width, height: height)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(attendee.name).lineLimit(1)
                        if !wide || !gallery { Spacer(minLength: 0) }
                        WorkspaceIcon(attendee.speaking ? "waveform" : attendee.microphone ? "mic" : "mic.slash", size: 12)
                            .foregroundStyle(attendee.speaking ? ConferenceRoomColors.speaking : ConferenceRoomColors.muted)
                    }.font(MSTheme.font(wide && gallery ? 12 : 10)).padding(.horizontal, 7).padding(.vertical, 5)
                        .background(ConferenceRoomColors.background.opacity(0.88), in: RoundedRectangle(cornerRadius: wide && gallery ? 8 : 0))
                        .padding(wide && gallery ? 9 : 0)
                }
                .clipShape(shape).overlay(shape.strokeBorder(attendee.speaking ? ConferenceRoomColors.speaking : ConferenceRoomColors.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(tr("Показать крупно")): \(attendee.name)")
            .accessibilityValue(tr(attendee.microphone ? "Микрофон включён" : "Микрофон выключен"))
            .accessibilityIdentifier("conferenceParticipantTile.\(attendee.id)")
    }

    private func backdrop(_ attendee: ConferenceRoomAttendee) -> some View {
        RadialGradient(colors: [attendee.tone.backdrop, ConferenceRoomColors.surface], center: .center,
                       startRadius: 0, endRadius: 180)
    }

    private func avatar(_ attendee: ConferenceRoomAttendee, size: CGFloat, featured: Bool = false) -> some View {
        Text(attendee.initials).font(MSTheme.font(size * 0.33, weight: .semibold))
            .foregroundStyle(featured ? ConferenceRoomColors.text : attendee.tone.avatarText)
            .frame(width: size, height: size)
            .background(featured ? .white.opacity(0.10) : attendee.tone.avatarBackground, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(featured ? 0.2 : 0)))
            .accessibilityHidden(true)
    }
}
