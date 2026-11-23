import SwiftUI
import MeetSpaceCore
import MeetSpaceMedia
import MeetSpaceDesignSystem

struct LiveConferenceView: View {
    @Bindable var session: ConferenceSession
    var recordings: RecordingsModel? = nil
    var workspaceTheme: ColorScheme = .light
    let close: () async -> Void
    @State private var sidePanel: ConferenceRoomPanelTab?
    @State private var showRecording = false
    @State private var showMore = false
    @State private var confirmLeave = false
    @State private var showInvitation = false
    private let panel = ConferenceRoomColors.surface

    var body: some View {
        Group {
            if [.prejoin, .waiting, .failed, .ended, .suspended].contains(session.phase) {
                prejoin
            } else {
                ConferenceRoomLayout(title: session.title, status: status, startedAt: session.startedAt,
                                     panelVisible: sidePanel != nil, back: { confirmLeave = true }, actions: roomActions) { wide in
                    headerActions(wide: wide)
                } notice: {
                    if let error = session.error {
                        Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(Color(red: 1, green: 0.65, blue: 0.67))
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5).accessibilityIdentifier("conferenceError")
                    }
                    if !showMore, session.hasScreenBroadcast || session.screenShareError != nil {
                        ScreenShareControls(session: session)
                    }
                } video: { wide in
                    ConferenceRoomStage(roster: roster, showSelf: session.videoPreferences.selfVideo, ownCamera: session.camera,
                                        wide: wide, remoteScreen: !screenTracks.isEmpty) { attendee, focused in
                        participantVisual(attendee, focused: focused)
                    } screenShare: {
                        remoteScreenViews
                    }.overlay(alignment: .topTrailing) {
                        if let reaction = session.lastReaction {
                            Text(reaction).font(.title2).padding(.top, 48).padding(.trailing, 8)
                                .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                } panel: {
                    ConferenceRoomPanel(selected: sidePanel ?? .chat, participantCount: roster.count, select: { showPanel($0) }, close: closePanel) {
                        if sidePanel == .participants { participantsPanel } else { chatPanel }
                    }.environment(\.colorScheme, workspaceTheme)
                }
                .preferredColorScheme(.dark)
            }
        }.interactiveDismissDisabled()
            .onChange(of: session.phase) { _, phase in
                if phase == .ended || phase == .failed {
                    showRecording = false
                    closePanel()
                }
            }
            .accessibilityHidden(showRecording)
            .allowsHitTesting(!showRecording)
            .overlay {
                if showRecording, let recordings {
                    ConferenceRecordingSheet(session: session, model: recordings) { showRecording = false }
                        .environment(\.colorScheme, workspaceTheme)
                }
            }
            .task(id: session.phase) {
                guard session.phase == .connected, let recordings else { return }
                while !Task.isCancelled {
                    await recordings.loadConference(session.conferenceID)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .sheet(isPresented: $showMore) {
                moreOptions
            }
            .sheet(isPresented: $showInvitation) {
                if let invitation = session.invitationURL { ConferenceInvitationSheet(title: session.title, url: invitation) }
            }
            .confirmationDialog(tr("Выйти из встречи?"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button(tr("Выйти из встречи"), role: .destructive) { Task { await close() } }
                    .accessibilityIdentifier("conferenceConfirmLeave")
                Button(tr("Остаться"), role: .cancel) {}
            } message: {
                Text(tr("Остальные участники смогут продолжить разговор."))
            }
    }

    @ViewBuilder private func headerActions(wide: Bool) -> some View {
        if let recordings {
            let records = recordings.conferenceItems[session.conferenceID] ?? []
            let active = records.first(where: \.active)
            ConferenceRoomRecordingButton(title: active?.statusTitle ?? "Запись", status: active?.status, wide: wide) {
                showRecording = true
            }.disabled(session.phase != .connected)
        }
        Button { showInvitation = true } label: {
            ConferenceRoomHeaderLabel(title: "Пригласить", icon: "link", expanded: wide)
        }.buttonStyle(.plain).disabled(session.invitationURL == nil)
            .accessibilityLabel(tr("Пригласить")).accessibilityIdentifier("conferenceInvite")
        Menu {
            Button(tr("Переподключиться"), systemImage: "arrow.clockwise") { session.reconnect() }
                .disabled(session.phase != .connected)
            Button(tr("Дополнительно"), systemImage: "ellipsis") { showMore = true }
                .accessibilityIdentifier("conferenceMediaOptions")
        } label: {
            ConferenceRoomHeaderLabel(title: "Управление встречей", icon: "arrow.clockwise")
        }.buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
            .accessibilityLabel(tr("Управление встречей")).accessibilityIdentifier("conferenceReconnect")
    }

    private var roomActions: [ConferenceRoomAction] {
        [
            ConferenceRoomAction(id: "conferenceMic", title: "Микрофон", icon: session.microphone ? "mic" : "mic.slash",
                                 active: session.microphone, disabled: session.microphoneBlocked || session.busy || session.phase != .connected) {
                Task { await session.toggleMicrophone() }
            },
            ConferenceRoomAction(id: "conferenceCamera", title: "Камера", icon: session.camera ? "video" : "video.slash",
                                 active: session.camera, disabled: session.cameraBlocked || session.busy || session.phase != .connected) {
                Task { await session.toggleCamera() }
            },
            ConferenceRoomAction(id: "conferenceParticipants", title: "Участники", icon: "person.2", active: sidePanel == .participants) {
                togglePanel(.participants)
            },
            ConferenceRoomAction(id: "conferenceChat", title: "Чат", icon: "bubble.left", active: sidePanel == .chat) {
                togglePanel(.chat)
            },
            ConferenceRoomAction(id: "conferenceLeave", title: "Выйти", icon: "rectangle.portrait.and.arrow.right",
                                 destructive: true) {
                confirmLeave = true
            }
        ]
    }

    private func showPanel(_ tab: ConferenceRoomPanelTab) {
        sidePanel = tab
        session.chatVisible = tab == .chat
        Task {
            if tab == .chat { await session.refreshChat() } else { await session.refreshParticipants() }
        }
    }

    private func togglePanel(_ tab: ConferenceRoomPanelTab) {
        if sidePanel == tab { closePanel() } else { showPanel(tab) }
    }

    private func closePanel() {
        sidePanel = nil
        session.chatVisible = false
    }

    private var roster: [ConferenceRoomAttendee] {
        var current = session.participants.filter(\.canParticipate)
        if !current.contains(where: { $0.id == session.participant.id }) { current.append(session.participant) }
        let tones: [ConferenceRoomAttendee.Tone] = [.amber, .mint, .violet]
        return current.enumerated().map { index, person in
            let own = person.id == session.participant.id
            return ConferenceRoomAttendee(id: person.id.uuidString.lowercased(), name: own ? tr("Вы") : person.displayName,
                                          initials: callInitials(person.displayName), tone: own ? .blue : tones[index % tones.count],
                                          own: own, microphone: own ? session.microphone : person.microphoneEnabled)
        }
    }

    private var screenTracks: [ConferenceVideoTrack] {
        session.videoTracks.filter { session.isScreenTrack($0) && !$0.isLocal }
    }

    @ViewBuilder private func participantVisual(_ attendee: ConferenceRoomAttendee, focused: Bool) -> some View {
        if let media = session.media,
           let participant = (session.participants + [session.participant]).first(where: { $0.id.uuidString.lowercased() == attendee.id }),
           attendee.own ? session.camera : participant.cameraEnabled,
           let track = session.videoTracks.first(where: {
               !session.isScreenTrack($0) && (attendee.own ? $0.isLocal : session.participantID(for: $0) == participant.id)
           }) {
            media.videoView(trackID: track.id, mirrored: attendee.own && session.frontCamera, fit: focused)
        }
    }

    private var remoteScreenViews: some View {
        ForEach(screenTracks) { track in
            if let media = session.media {
                VStack(alignment: .leading, spacing: 8) {
                    Text((session.participants.first { $0.id == session.participantID(for: track) }?.displayName ?? tr("Участник")) + " · " + tr("Демонстрация экрана"))
                        .font(MSTheme.font(12)).fixedSize(horizontal: false, vertical: true)
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { media.videoView(trackID: track.id, mirrored: false, fit: true) }
                        .background(panel).clipShape(RoundedRectangle(cornerRadius: 15))
                }.accessibilityIdentifier("remoteScreenStage")
            }
        }
    }

    private var moreOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Дополнительно")).font(MSTheme.font(19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { showMore = false } label: { WorkspaceIcon("xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Закрыть")).accessibilityIdentifier("conferenceMediaOptionsClose")
                }
                ScreenShareControls(session: session).foregroundStyle(.white)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { mediaOptions }
                    VStack(alignment: .leading, spacing: 8) { mediaOptions }
                }
                if !session.audioRoute.isEmpty {
                    Text(session.audioRoute).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                }
                Divider()
                Text(tr("Отправить реакцию")).font(MSTheme.font(13, weight: .semibold))
                HStack {
                    ForEach(["👍", "👏", "❤️", "😂"], id: \.self) { emoji in
                        Button(emoji) { Task { await session.react(emoji) }; showMore = false }.frame(minWidth: 44, minHeight: 44)
                    }
                }
            }.padding(22)
        }.presentationDetents([.medium, .large])
    }

    @ViewBuilder private var mediaOptions: some View {
        Button { Task { await session.switchCamera() } } label: { Label(tr("Сменить камеру"), systemImage: "arrow.triangle.2.circlepath.camera") }
            .disabled(!session.camera || session.busy).frame(minHeight: 44)
        Button { session.toggleSpeaker() } label: {
            Label(tr(session.speaker ? "Динамик" : "Аудиовыход"), systemImage: "speaker.wave.2")
        }.frame(minHeight: 44)
    }
    private var status: String {
        switch session.phase {
        case .prejoin: "Перед входом во встречу"
        case .waiting: "Ожидаем допуска"
        case .connecting: "Подключение…"
        case .connected: "Встреча в эфире"
        case .reconnecting: "Восстанавливаем соединение…"
        case .suspended: "Медиа приостановлено"
        case .failed: "Не удалось подключиться"
        case .ended: "Участие завершено"
        }
    }
    private var prejoin: some View {
        MeetingPrejoinLayout(onBack: { Task { await close() } }) {
            MeetingCameraPreview(name: session.participant.displayName, camera: session.wantsCamera,
                                 microphone: session.wantsMicrophone,
                                 cameraDisabled: session.cameraBlocked || session.phase != .prejoin,
                                 microphoneDisabled: session.microphoneBlocked || session.phase != .prejoin,
                                 toggleCamera: { session.wantsCamera.toggle() },
                                 toggleMicrophone: { session.wantsMicrophone.toggle() })
        } details: {
            MeetingPrejoinHeading(title: session.title, subtitle: tr(status))
            if let error = session.error {
                Text(tr(error)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conferenceError")
            }
            if session.phase == .prejoin {
                MeetingPrejoinName(name: .constant(session.participant.displayName)).disabled(true)
                if !session.audioRoute.isEmpty {
                    MeetingMicrophoneRow(route: session.audioRoute) { showMore = true }
                }
                Button { session.start() } label: {
                    Label(tr("Присоединиться"), systemImage: "arrow.right").labelStyle(MeetingNextLabelStyle())
                }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("conferenceJoin")
            } else if session.phase == .waiting {
                ProgressView()
                Text(tr("Организатор должен разрешить вход. Камера и микрофон выключены."))
                    .font(MSTheme.font(13)).fixedSize(horizontal: false, vertical: true)
            } else if session.phase == .failed || session.phase == .suspended {
                Button(tr("Повторить")) { session.start() }.buttonStyle(MSButtonStyle())
                    .accessibilityIdentifier("conferenceJoin")
            }
            if session.phase != .prejoin {
                Button(tr("Выйти")) { Task { await close() } }.frame(minHeight: 44)
                    .accessibilityIdentifier("conferenceLeave")
            }
        }
    }
    private var chatPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ConferenceRoomDate(date: session.messages.first?.createdAt)
                        ForEach(session.messages) { message in
                            let own = message.senderId == session.participant.userId || message.senderId == session.participant.id
                            ConferenceRoomMessageBubble(own: own, time: message.createdAt.formatted(date: .omitted, time: .shortened)) {
                                Text(message.senderName).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(ConferenceRoomPanelColors.accent)
                                    .accessibilityIdentifier("conferenceMessageSender.\(message.id.uuidString.lowercased())")
                                Text(message.isDeleted ? tr("Сообщение удалено") : message.text).font(MSTheme.font(12))
                                ForEach(message.attachments) { attachment in
                                    Label(attachment.filename, systemImage: "doc").font(MSTheme.font(12))
                                }
                            }.id(message.id)
                        }
                    }.padding(14)
                }.background(ConferenceRoomPanelColors.feed).onChange(of: session.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            ConferenceRoomComposer(draft: $session.chatText, disabled: session.busy || session.phase != .connected) {
                Task { await session.sendMessage() }
            }
        }.background(ConferenceRoomPanelColors.card)
    }
    private var participantsPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.participants) { participant in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ConferenceRoomPersonLabel(name: participant.displayName, initials: callInitials(participant.displayName),
                                                      subtitle: participantSubtitle(participant), own: participant.id == session.participant.id)
                            if session.participant.canModerate(participant, action: "kick") {
                                moderationMenu(for: participant)
                            }
                        }
                        if participant.isWaiting, session.participant.canAdmit {
                            HStack {
                                Button(tr("Допустить")) { Task { await session.admit(participant, decision: "admit") } }
                                Button(tr("Отклонить"), role: .destructive) { Task { await session.admit(participant, decision: "reject") } }
                            }.buttonStyle(.bordered).disabled(session.busy)
                        }
                    }.padding(.vertical, 11)
                    Divider()
                }
            }.padding(.horizontal, 14)
        }.background(ConferenceRoomPanelColors.feed)
            .refreshable { await session.refreshParticipants() }
    }
    private func participantSubtitle(_ participant: ConferenceParticipant) -> String {
        [tr(role(participant.role)),
         participant.isWaiting ? tr("Ожидает допуска") : nil,
         participant.microphoneBlocked ? tr("Микрофон заблокирован") : nil,
         participant.cameraBlocked ? tr("Камера заблокирована") : nil,
         participant.screenBlocked ? tr("Демонстрация заблокирована") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func moderationMenu(for participant: ConferenceParticipant) -> some View {
        Menu {
            if session.participant.canModerate(participant, action: "mute") {
                Button(tr(participant.microphoneBlocked ? "Разрешить микрофон" : "Заблокировать микрофон")) {
                    Task { await session.moderate(participant, action: "mute", blocked: !participant.microphoneBlocked) }
                }
            }
            if session.participant.canModerate(participant, action: "camera") {
                Button(tr(participant.cameraBlocked ? "Разрешить камеру" : "Заблокировать камеру")) {
                    Task { await session.moderate(participant, action: "camera", blocked: !participant.cameraBlocked) }
                }
            }
            if session.participant.canModerate(participant, action: "screen") {
                Button(tr(participant.screenBlocked ? "Разрешить демонстрацию" : "Заблокировать демонстрацию")) {
                    Task { await session.moderate(participant, action: "screen", blocked: !participant.screenBlocked) }
                }
            }
            if session.participant.canModerate(participant, action: "role") {
                Button(tr(participant.role == "co_host" ? "Сделать участником" : "Назначить соведущим")) {
                    Task { await session.moderate(participant, action: "role", role: participant.role == "co_host" ? "participant" : "co_host") }
                }
            }
            Button(tr("Удалить из встречи"), role: .destructive) { Task { await session.moderate(participant, action: "kick") } }
        } label: {
            WorkspaceIcon("ellipsis", size: 18).frame(width: 44, height: 44)
        }.buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
            .accessibilityLabel(tr("Управление участником") + ": " + participant.displayName)
            .disabled(session.busy)
    }
    private func role(_ value: String) -> String {
        switch value { case "owner": "Организатор"; case "co_host": "Соведущий"; case "guest": "Гость"; default: "Участник" }
    }
}
