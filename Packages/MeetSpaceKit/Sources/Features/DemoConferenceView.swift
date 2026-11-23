import SwiftUI
import ImageIO
import MeetSpaceDesignSystem

/// The local examples use the same room and panel as an authenticated meeting.
struct DemoConferenceView: View {
    let model: AppModel
    private let meetingTitle: String
    private let displayName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var theme
    @State private var microphone = true
    @State private var camera = false
    @State private var selected: ConferenceRoomPanelTab?
    @State private var showingLeave = false
    @State private var showingInvite = false
    @State private var showingRecord = false
    @State private var reconnecting = false
    @State private var draft = ""
    @State private var chat: [DemoMessage] = [
        DemoMessage(author: "Анна Кузнецова", text: "Отправила материалы к встрече в общий чат.", own: false),
        DemoMessage(author: "Дмитрий Волков", text: "Покажу новую версию после обсуждения.", own: false)
    ]

    private let link = URL(string: "https://meet.example.org/i/design")
    @State private var startedAt = Date().addingTimeInterval(-768)

    private struct DemoMessage: Identifiable {
        let id = UUID()
        let author: String
        let text: String
        let own: Bool
    }

    init(model: AppModel) {
        self.model = model
        let entry = model.demoConferenceEntry
        meetingTitle = entry?.title ?? tr("Дизайн-синхронизация")
        displayName = entry?.name ?? model.demoProfile.name
        _microphone = State(initialValue: entry?.microphone ?? true)
        _camera = State(initialValue: entry?.camera ?? false)
    }

    private var attendees: [ConferenceRoomAttendee] {
        return [
            ConferenceRoomAttendee(id: "dmitry", name: "Дмитрий Волков", initials: "ДВ", tone: .blue, microphone: true, speaking: true),
            ConferenceRoomAttendee(id: "anna", name: "Анна Кузнецова", initials: "АК", tone: .amber),
            ConferenceRoomAttendee(id: "maria", name: "Мария Полякова", initials: "МП", tone: .mint),
            ConferenceRoomAttendee(id: "maxim", name: "Максим Петров", initials: "МП", tone: .violet),
            ConferenceRoomAttendee(id: "own", name: tr("Вы"), initials: callInitials(displayName), tone: .blue, own: true, microphone: microphone)
        ]
    }

    var body: some View {
        ConferenceRoomLayout(title: meetingTitle, status: reconnecting ? "Переподключение…" : "Встреча в эфире",
                             startedAt: startedAt, panelVisible: selected != nil, back: { showingLeave = true }, actions: actions) { wide in
            Button { showingRecord = true } label: {
                ConferenceRoomHeaderLabel(title: "Запись", icon: "circle", expanded: wide)
            }.buttonStyle(.plain).accessibilityLabel(tr("Запись встречи")).accessibilityIdentifier("conferenceRecordings")
            Button { showingInvite = true } label: {
                ConferenceRoomHeaderLabel(title: "Пригласить", icon: "link", expanded: wide)
            }.buttonStyle(.plain).accessibilityLabel(tr("Пригласить")).accessibilityIdentifier("conferenceInvite")
            Button {
                reconnecting = true
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    reconnecting = false
                }
            } label: {
                ConferenceRoomHeaderLabel(title: "Переподключиться", icon: "arrow.clockwise")
            }.buttonStyle(.plain).disabled(reconnecting)
                .accessibilityLabel(tr("Переподключиться")).accessibilityIdentifier("conferenceReconnect")
        } notice: {
            EmptyView()
        } video: { wide in
            ConferenceRoomStage(attendees: attendees, ownCamera: camera, wide: wide, remoteScreen: false) { person, focused in
                if person.id == "dmitry", let image = Self.previewFrame {
                    Color.clear.overlay {
                        Image(decorative: image, scale: 1).resizable()
                            .aspectRatio(contentMode: focused || wide ? .fit : .fill)
                    }.clipped()
                } else if person.own, let photo = model.demoProfile.photo {
                    ProfileAvatar(name: displayName, size: focused ? 58 : 38, photo: photo)
                }
            } screenShare: {
                EmptyView()
            }
        } panel: {
            ConferenceRoomPanel(selected: selected ?? .chat, participantCount: attendees.count,
                                select: { selected = $0 }, close: { selected = nil }) {
                if selected == .participants {
                    participantList
                } else {
                    conversation
                }
            }.environment(\.colorScheme, theme)
        }
        .toolbar(.hidden)
        .preferredColorScheme(.dark)
        .confirmationDialog(tr("Выйти из встречи?"), isPresented: $showingLeave, titleVisibility: .visible) {
            Button(tr("Выйти из встречи"), role: .destructive) {
                model.demoConferenceEntry = nil
                dismiss()
            }.accessibilityIdentifier("conferenceConfirmLeave")
            Button(tr("Остаться"), role: .cancel) {}
        } message: {
            Text(tr("Остальные участники смогут продолжить разговор."))
        }
        .sheet(isPresented: $showingInvite) {
            if let link { ConferenceInvitationSheet(title: meetingTitle, url: link, demo: true) }
        }
        .alert(tr("Запись встречи"), isPresented: $showingRecord) {
            Button(tr("Готово"), role: .cancel) {}
        } message: {
            Text(tr("Демонстрационный режим. Запись недоступна."))
        }
    }

    private var actions: [ConferenceRoomAction] {
        [
            ConferenceRoomAction(id: "conferenceMic", title: "Микрофон", icon: microphone ? "mic" : "mic.slash", active: microphone) {
                microphone.toggle()
            },
            ConferenceRoomAction(id: "conferenceCamera", title: "Камера", icon: camera ? "video" : "video.slash", active: camera) {
                camera.toggle()
            },
            ConferenceRoomAction(id: "conferenceParticipants", title: "Участники", icon: "person.2", active: selected == .participants) {
                selected = selected == .participants ? nil : .participants
            },
            ConferenceRoomAction(id: "conferenceChat", title: "Чат", icon: "bubble.left", active: selected == .chat) {
                selected = selected == .chat ? nil : .chat
            },
            ConferenceRoomAction(id: "conferenceLeave", title: "Выйти", icon: "rectangle.portrait.and.arrow.right", destructive: true) {
                showingLeave = true
            }
        ]
    }

    private var participantList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(attendees) { person in
                    HStack {
                        Text(person.initials).font(MSTheme.font(12, weight: .semibold))
                            .foregroundStyle(person.tone.avatarText).frame(width: 36, height: 36)
                            .background(person.tone.avatarBackground, in: Circle())
                        Text(person.name).font(MSTheme.font(13))
                        Spacer(minLength: 8)
                        WorkspaceIcon(person.microphone ? "mic" : "mic.slash", size: 15).foregroundStyle(ConferenceRoomPanelColors.muted)
                    }.padding(10).background(ConferenceRoomPanelColors.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(12)
        }.background(ConferenceRoomPanelColors.feed)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ConferenceRoomDate(date: Date())
                        ForEach(chat) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                if !message.own {
                                    Text(message.author).font(MSTheme.font(11, weight: .semibold))
                                        .foregroundStyle(ConferenceRoomPanelColors.accent)
                                }
                                Text(message.text).font(MSTheme.font(12))
                            }.padding(10).background(ConferenceRoomPanelColors.card, in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: message.own ? .trailing : .leading).id(message.id)
                        }
                    }.padding(12)
                }.background(ConferenceRoomPanelColors.feed)
                    .onChange(of: chat.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            ConferenceRoomComposer(draft: $draft, send: send)
        }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        chat.append(DemoMessage(author: displayName, text: message, own: true))
        draft = ""
    }

    private static let previewFrame: CGImage? = {
        guard let url = Bundle.module.url(forResource: "call-camera-demo", withExtension: "jpg", subdirectory: "ConferencePhotos"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
}
