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
                        let panelWidth = min(350, max(260, (geometry.size.width - 2 * inset) * 0.25))
                        panel().frame(width: wide ? panelWidth : nil)
                            .frame(maxWidth: wide ? nil : .infinity, maxHeight: .infinity)
                    }
                }.padding(.horizontal, inset).padding(.top, wide ? 10 : 8).padding(.bottom, 6)
                toolbar(wide: wide).padding(.horizontal, inset)
                    .padding(.bottom, min(12, geometry.safeAreaInsets.bottom))
            }.foregroundStyle(ConferenceRoomColors.text)
                .ignoresSafeArea(.container, edges: .bottom)
        }.background(ConferenceRoomColors.background.ignoresSafeArea())
    }

    /// Показывает заголовок встречи, её статус и кнопки управления.
    /// - Parameter wide: Использовать ли компоновку для широкого экрана.
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
        }.padding(.top, 6).padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(ConferenceRoomColors.line).frame(height: 1) }
    }

    /// Размещает панель управления звонком, включая прокрутку при увеличенном размере текста.
    /// - Parameter wide: Использовать ли компоновку для широкого экрана.
    private func toolbar(wide: Bool) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView(.horizontal) { controls(wide: true).fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden)
            } else {
                controls(wide: wide).frame(maxWidth: wide ? nil : 540)
                    .fixedSize(horizontal: wide, vertical: false)
            }
        }.frame(maxWidth: .infinity).padding(.top, 5).padding(.bottom, 3)
            .overlay(alignment: .top) { Rectangle().fill(ConferenceRoomColors.line).frame(height: 1) }
    }

    /// Строит кнопки управления встречей и выделяет активные действия.
    /// - Parameter wide: Использовать ли компоновку для широкого экрана.
    private func controls(wide: Bool) -> some View {
        HStack(spacing: wide ? 6 : 7) {
            ForEach(actions) { control in
                Button(action: control.action) {
                    VStack(spacing: 3) {
                        WorkspaceIcon(control.icon, size: 19)
                        Text(tr(control.title))
                            .font(MSTheme.font(wide ? 11 : 10, relativeTo: .caption2))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .allowsTightening(true)
                    }.padding(.horizontal, wide ? 7 : 2)
                        .frame(minWidth: wide ? 76 : nil, maxWidth: wide ? nil : .infinity, minHeight: 46)
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
        }.padding(wide ? 3 : 2)
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
    var speechLevel: Double = 0

    var speaking: Bool { microphone && speechLevel > 0 }
    var microphoneStatus: String {
        if speaking { return tr("Говорит") }
        return tr(microphone ? "Микрофон включён" : "Микрофон выключен")
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout { case gallery, speaker }
    private var attendees: [ConferenceRoomAttendee] { showSelf ? roster : roster.filter { !$0.own } }
    private var mode: Layout { selectedLayout ?? (wide ? .gallery : .speaker) }
    private var pinned: ConferenceRoomAttendee? { attendees.first { $0.id == pinnedID } }
    private var featured: ConferenceRoomAttendee? {
        pinned ?? attendees.first(where: \.speaking) ?? attendees.first { !$0.own } ?? attendees.first
    }
    private var ordered: [ConferenceRoomAttendee] {
        attendees.filter { !$0.own } + attendees.filter(\.own)
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
        VStack(spacing: 8) {
            viewBar.frame(maxWidth: wide ? nil : 540)
            GeometryReader { geometry in
                let pairedGallery = mode == .gallery && attendees.count == 2
                let width = wide || pairedGallery ? geometry.size.width : min(geometry.size.width, 540)
                ScrollView {
                    VStack(spacing: stageGap) {
                        if remoteScreen { screenShare() }
                        if mode == .speaker, let featured {
                            let others = ordered.filter { $0.id != featured.id }
                            let sizes = speakerSizes(width: width, height: geometry.size.height, others: others.count)
                            speakerTile(featured, size: sizes.featured)
                            speakerRail(others, width: sizes.featured.width, tileHeight: sizes.railHeight)
                        } else if pairedGallery {
                            galleryPair(in: geometry.size)
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

    /// Создаёт кнопку переключения раскладки видео и сбрасывает страницу миниатюр при смене режима.
    /// - Parameters:
    ///   - option: Режим, включаемый кнопкой.
    ///   - label: Название режима.
    ///   - icon: Имя значка действия.
    ///   - id: Идентификатор элемента для тестов интерфейса и средств доступности.
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

    private let railPageSize = 3
    private let videoAspectRatio: CGFloat = 16.0 / 9.0
    private var railGap: CGFloat { wide ? 10 : 7 }
    private var stageGap: CGFloat { wide ? 10 : 8 }

    /// Рассчитывает размеры основной плитки и ленты участников с учётом доступного места.
    /// - Parameters:
    ///   - width: Ширина области видео в пунктах.
    ///   - height: Высота области видео в пунктах.
    ///   - others: Число участников помимо основного.
    private func speakerSizes(width: CGFloat, height: CGFloat, others: Int) -> (featured: CGSize, railHeight: CGFloat) {
        let pagerHeight: CGFloat = others > railPageSize ? 22 + stageGap : 0
        let available = max(0, height - pagerHeight - (others > 0 ? stageGap : 0))
        let columns = CGFloat(min(railPageSize, max(2, others)))
        let columnWidth = max(0, (width - (columns - 1) * railGap) / columns)
        let railHeight: CGFloat = others == 0 ? 0 : min(columnWidth / videoAspectRatio,
                                                         max(56, available * (wide ? 0.24 : 0.32)))
        let featuredHeight = min(width / videoAspectRatio, max(80, available - railHeight))
        let featuredWidth = min(width, featuredHeight * videoAspectRatio)
        return (CGSize(width: featuredWidth, height: featuredHeight), railHeight)
    }

    /// Показывает крупную плитку выбранного участника со статусом речи и закрепления.
    /// - Parameters:
    ///   - attendee: Участник на основной плитке.
    ///   - size: Размер основной плитки в пунктах.
    private func speakerTile(_ attendee: ConferenceRoomAttendee, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: wide ? 13 : 15)
        return ZStack {
            backdrop(attendee)
            avatar(attendee, size: min(wide ? 100 : 62, max(wide ? 60 : 42, size.width * 0.14)), featured: true)
            visual(attendee, true)
                .frame(width: size.width, height: size.height).allowsHitTesting(false)
        }.frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Text(attendee.name).lineLimit(1)
                    microphoneIndicator(for: attendee, size: 15)
                }.font(MSTheme.font(11)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(ConferenceRoomColors.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(attendee.microphoneStatus)
                    .accessibilityIdentifier("conferenceFeaturedCaption")
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
                        .overlay { tileBorder(for: own, shape: RoundedRectangle(cornerRadius: 8)) }
                        .padding(8).accessibilityIdentifier("conferenceLocalVideo")
                }
            }
            .clipShape(shape)
            .overlay { tileBorder(for: attendee, shape: shape) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conferenceFeaturedParticipant")
    }

    /// Оформляет метку речи или кнопку открепления на основной плитке.
    /// - Parameters:
    ///   - title: Подпись метки.
    ///   - icon: Имя значка действия.
    ///   - speaking: Выделить ли метку цветом говорящего.
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

    /// Строит перелистываемую ленту миниатюр под основной плиткой.
    /// - Parameters:
    ///   - people: Участники для миниатюр в порядке показа.
    ///   - width: Доступная ширина ленты в пунктах.
    ///   - tileHeight: Расчётная высота одной миниатюры в пунктах.
    @ViewBuilder private func speakerRail(_ people: [ConferenceRoomAttendee], width: CGFloat, tileHeight: CGFloat) -> some View {
        if !people.isEmpty {
            let columns = min(railPageSize, max(2, people.count))
            let gaps = CGFloat(columns - 1) * railGap
            let railWidth = min(width, CGFloat(columns) * tileHeight * videoAspectRatio + gaps)
            let tileWidth = max(0, (railWidth - gaps) / CGFloat(columns))
            let pages = stride(from: 0, to: people.count, by: railPageSize).map { start in
                Array(people[start..<min(start + railPageSize, people.count)])
            }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        HStack(spacing: railGap) {
                            ForEach(page) { person in
                                tile(person, width: tileWidth, height: tileWidth / videoAspectRatio, gallery: false)
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

    /// Располагает две плитки в ряд или столбец так, чтобы они занимали максимальную площадь с пропорциями 16:9.
    /// - Parameter size: Размер доступной области видео.
    private func galleryPair(in size: CGSize) -> some View {
        let gap: CGFloat = wide ? 10 : 7
        let stackedWidth = min(size.width, max(0, size.height - gap) / 2 * videoAspectRatio)
        let sideBySideWidth = min(max(0, size.width - gap) / 2, size.height * videoAspectRatio)
        let stacked = stackedWidth >= sideBySideWidth
        let layout = stacked ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
        let tileWidth = max(stackedWidth, sideBySideWidth)
        return layout {
            ForEach(ordered) { attendee in
                tile(attendee, width: tileWidth, height: tileWidth / videoAspectRatio, gallery: true)
            }
        }
    }

    /// Размещает участников по строкам и рассчитывает размеры плиток галереи.
    /// - Parameters:
    ///   - width: Доступная ширина галереи в пунктах.
    ///   - height: Доступная высота галереи в пунктах.
    private func gallery(width: CGFloat, height: CGFloat) -> some View {
        let columns = attendees.count == 1 ? 1 : (wide && width >= 960 && attendees.count != 4 ? 3 : 2)
        let gap: CGFloat = wide ? 10 : 7
        let rows = max(1, min(columns == 3 ? 2 : 3, (attendees.count + columns - 1) / columns))
        let fittingWidth = max(90, (height - CGFloat(rows - 1) * gap) * videoAspectRatio / CGFloat(rows))
        let proposedWidth = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let tileWidth = wide ? min(proposedWidth, fittingWidth) : proposedWidth
        let tileHeight = tileWidth / videoAspectRatio
        return VStack(spacing: gap) {
            ForEach(Array(stride(from: 0, to: ordered.count, by: columns)), id: \.self) { offset in
                HStack(spacing: gap) {
                    ForEach(ordered[offset..<min(offset + columns, ordered.count)]) { attendee in
                        tile(attendee, width: tileWidth, height: tileHeight, gallery: true)
                    }
                }
            }
        }
    }

    /// Создаёт плитку участника с индикатором речи и переходом к закреплённому крупному плану.
    /// - Parameters:
    ///   - attendee: Участник на плитке.
    ///   - width: Ширина плитки в пунктах.
    ///   - height: Высота плитки в пунктах.
    ///   - gallery: Отображается ли плитка в основной сетке.
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
                        microphoneIndicator(for: attendee, size: 13)
                    }.font(MSTheme.font(wide && gallery ? 12 : 10)).padding(.horizontal, 7).padding(.vertical, 5)
                        .background(ConferenceRoomColors.background.opacity(0.88), in: RoundedRectangle(cornerRadius: wide && gallery ? 8 : 0))
                        .padding(wide && gallery ? 9 : 0)
                }
                .clipShape(shape).overlay { tileBorder(for: attendee, shape: shape) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(tr("Показать крупно")): \(attendee.name)")
            .accessibilityValue(attendee.microphoneStatus)
            .accessibilityIdentifier("conferenceParticipantTile.\(attendee.id)")
    }

    /// Выделяет плитку на всё время реплики, чтобы говорящего было видно и поверх видео.
    /// - Parameters:
    ///   - attendee: Участник, которому принадлежит плитка.
    ///   - shape: Контур плитки с учётом её скругления.
    private func tileBorder(for attendee: ConferenceRoomAttendee, shape: RoundedRectangle) -> some View {
        shape.strokeBorder(attendee.speaking ? ConferenceRoomColors.speaking : ConferenceRoomColors.line,
                           lineWidth: attendee.speaking ? 2 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Меняет яркость микрофона вслед за громкостью речи участника.
    /// - Parameters:
    ///   - attendee: Участник с текущим состоянием микрофона и уровнем речи от 0 до 1.
    ///   - size: Размер значка в пунктах.
    private func microphoneIndicator(for attendee: ConferenceRoomAttendee, size: CGFloat) -> some View {
        let active = attendee.speaking
        let level = active ? (reduceMotion ? 1 : attendee.speechLevel) : 0
        let green = ConferenceRoomColors.speaking
        return WorkspaceIcon(attendee.microphone ? "mic" : "mic.slash", size: size)
            .foregroundStyle(active ? green.opacity(0.65 + 0.35 * level) : ConferenceRoomColors.muted)
            .background {
                Circle().fill(green.opacity(0.32 * level))
                    .frame(width: size * 1.5, height: size * 1.5)
            }
            .shadow(color: green.opacity(0.70 * level), radius: 2 * level)
            .animation(reduceMotion || !attendee.microphone ? nil : .linear(duration: 0.12), value: level)
            .accessibilityHidden(true)
    }

    /// Строит фон плитки в цветовой палитре участника.
    /// - Parameter attendee: Участник, чей цвет используется.
    private func backdrop(_ attendee: ConferenceRoomAttendee) -> some View {
        RadialGradient(colors: [attendee.tone.backdrop, ConferenceRoomColors.surface], center: .center,
                       startRadius: 0, endRadius: 180)
    }

    /// Показывает инициалы участника на круглом аватаре.
    /// - Parameters:
    ///   - attendee: Участник, чьи инициалы показываются.
    ///   - size: Диаметр аватара в пунктах.
    ///   - featured: Использовать ли оформление основной плитки.
    private func avatar(_ attendee: ConferenceRoomAttendee, size: CGFloat, featured: Bool = false) -> some View {
        Text(attendee.initials).font(MSTheme.font(size * 0.33, weight: .semibold))
            .foregroundStyle(featured ? ConferenceRoomColors.text : attendee.tone.avatarText)
            .frame(width: size, height: size)
            .background(featured ? .white.opacity(0.10) : attendee.tone.avatarBackground, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(featured ? 0.2 : 0)))
            .accessibilityHidden(true)
    }
}
