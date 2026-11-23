import SwiftUI
import ImageIO
import MeetSpaceCore
import MeetSpaceDesignSystem

/// The local examples use the same room and panel as an authenticated meeting.
struct DemoConferenceView: View {
    let model: AppModel
    private let meetingTitle: String
    private let displayName: String
    private let guest: Bool
    private let videoPreferences: AccountVideoPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var theme
    @State private var microphone = true
    @State private var camera = false
    @State private var selected: ConferenceRoomPanelTab?
    @State private var showingLeave = false
    @State private var showingInvite = false
    @State private var showingRecord = false
    @State private var recordingPhase = DemoRecordingPhase.idle
    @State private var recordingMode = RecordingMode.composite
    @State private var demoMeetingID = UUID()
    @State private var recordingID = UUID()
    @State private var recordingStartedAt: Date?
    @State private var savedRecording: Int?
    private enum DemoRecordingPhase: String {
        case idle, starting, recording, processing, ready

        var title: String {
            switch self {
            case .idle: "Запись"
            case .starting: "Запись запускается"
            case .recording: "Идёт запись"
            case .processing: "Обрабатывается"
            case .ready: "Запись готова"
            }
        }
    }
    @State private var reconnecting = false
    @State private var draft = ""
    @State private var chat: [DemoMessage] = [
        DemoMessage(author: "Мария Полякова", text: "Хорошо видно, можем начинать!", own: false, time: "10:02"),
        DemoMessage(author: "Дмитрий Волков", text: "Давайте начнём со сценария первого входа.", own: false, time: "10:08")
    ]

    private let link = URL(string: "https://meet.example.org/i/design")
    @State private var startedAt = Date().addingTimeInterval(-768)

    private struct DemoMessage: Identifiable {
        let id = UUID()
        let author: String
        let text: String
        let own: Bool
        let time: String
    }

    init(model: AppModel) {
        self.model = model
        let entry = model.demoConferenceEntry
        let preferences = AccountVideoPreferences.load(for: nil)
        videoPreferences = preferences
        guest = entry?.guest ?? false
        meetingTitle = entry?.title ?? tr("Дизайн-синхронизация")
        displayName = entry?.name ?? model.demoProfile.name
        _microphone = State(initialValue: entry?.microphone ?? true)
        _camera = State(initialValue: entry?.camera ?? !preferences.cameraOff)
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
            ConferenceRoomRecordingButton(title: recordingPhase.title,
                                          status: [.idle, .ready].contains(recordingPhase) ? nil : recordingPhase.rawValue,
                                          wide: wide) { showingRecord = true }
                .disabled(reconnecting)
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
            ConferenceRoomStage(roster: attendees, showSelf: videoPreferences.selfVideo, ownCamera: camera,
                                wide: wide, remoteScreen: false) { person, focused in
                if !videoPreferences.hideVideo, person.id == "dmitry", let image = Self.previewFrame {
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
        .preferredColorScheme(showingRecord || selected != nil ? nil : .dark)
        .accessibilityHidden(showingRecord)
        .allowsHitTesting(!showingRecord)
        .overlay {
            if showingRecord {
                ConferenceRecordingDialog(meetingTitle: meetingTitle, state: recordingState, mode: $recordingMode,
                                          demo: true, openRecording: openSavedRecording,
                                          close: { showingRecord = false }, start: startRecording, stop: stopRecording)
                    .environment(\.colorScheme, theme)
            }
        }
        .task(id: recordingPhase) {
            switch recordingPhase {
            case .starting:
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                recordingStartedAt = Date()
                recordingPhase = .recording
            case .processing:
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                recordingPhase = .ready
            default: break
            }
        }
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
    }

    private var recordingState: ConferenceRecordingDialogState {
        if guest { return .unavailable("Гости не могут запускать запись. Попросите участника встречи с аккаунтом начать запись.") }
        if recordingPhase == .idle || recordingPhase == .ready {
            return .options([.composite, .audioOnly, .individualTracks], status: recordingPhase.title)
        }
        return .active(id: recordingID, status: recordingPhase.rawValue, title: recordingPhase.title,
                       mode: recordingMode, canStop: recordingPhase == .recording)
    }

    private func startRecording(_ mode: RecordingMode) {
        guard !guest, recordingPhase == .idle || recordingPhase == .ready else { return }
        savedRecording = nil
        recordingMode = mode
        recordingID = UUID()
        recordingStartedAt = nil
        recordingPhase = .starting
    }

    private func stopRecording(_ id: UUID) {
        guard !guest, recordingPhase == .recording, id == recordingID, let recordingStartedAt else { return }
        recordingPhase = .processing
        savedRecording = model.addDemoMeetingRecording(title: meetingTitle, mode: recordingMode,
                                                       duration: Date().timeIntervalSince(recordingStartedAt),
                                                       participantCount: attendees.count, meetingID: demoMeetingID)
    }

    private var openSavedRecording: (() -> Void)? {
        guard recordingPhase == .ready, let savedRecording else { return nil }
        return {
            showingRecord = false
            model.navigate(.recording(savedRecording))
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
            LazyVStack(spacing: 0) {
                let organizer = DemoData.meetings.first(where: { tr($0.title) == meetingTitle })?.owner ?? "Вы"
                ForEach(attendees) { person in
                    HStack(spacing: 8) {
                        let isOrganizer = person.name == tr(organizer)
                        let role = person.own && guest ? "Гость" : isOrganizer ? "Организатор" : "Участник"
                        ConferenceRoomPersonLabel(name: person.name, initials: person.initials, subtitle: tr(role), own: person.own)
                        WorkspaceIcon(person.microphone ? "mic" : "mic.slash", size: 15).foregroundStyle(ConferenceRoomPanelColors.muted)
                    }.padding(.vertical, 11)
                    Divider()
                }
            }.padding(.horizontal, 14)
        }.background(ConferenceRoomPanelColors.feed)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ConferenceRoomDate(date: Date())
                        ForEach(chat) { message in
                            ConferenceRoomMessageBubble(own: message.own, time: message.time) {
                                if !message.own {
                                    Text(message.author).font(MSTheme.font(11, weight: .semibold))
                                        .foregroundStyle(ConferenceRoomPanelColors.accent)
                                }
                                Text(message.text).font(MSTheme.font(12))
                            }.id(message.id)
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
        chat.append(DemoMessage(author: displayName, text: message, own: true, time: Date().formatted(date: .omitted, time: .shortened)))
        draft = ""
    }

    private static let previewFrame: CGImage? = {
        guard let url = Bundle.module.url(forResource: "call-camera-demo", withExtension: "jpg", subdirectory: "ConferencePhotos"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
}
