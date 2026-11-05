import SwiftUI
import MeetSpaceCore
import MeetSpaceMedia
import MeetSpaceDesignSystem

struct LiveConferenceView: View {
    @Bindable var session: ConferenceSession
    let close: () async -> Void
    @State private var showParticipants = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private let background = Color(red: 0.106, green: 0.125, blue: 0.180)
    private let panel = Color(red: 0.137, green: 0.176, blue: 0.235)
    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 780 && !typeSize.isAccessibilitySize
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title).font(MSTheme.font(17, weight: .semibold)).lineLimit(2)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.conference")
                        Text(tr(status)).font(MSTheme.font(12)).foregroundStyle(.white.opacity(0.7))
                            .accessibilityIdentifier("conferenceStatus")
                    }
                    Spacer()
                    if let reaction = session.lastReaction { Text(reaction).font(.title) }
                    if session.phase == .connected {
                        Menu {
                            ForEach(["👍", "👏", "❤️", "😂"], id: \.self) { emoji in
                                Button(emoji) { Task { await session.react(emoji) } }
                            }
                        } label: { Image(systemName: "face.smiling").frame(width: 44, height: 44) }
                            .accessibilityLabel(tr("Отправить реакцию"))
                    }
                }.padding(.horizontal, 20)
                if let error = session.error {
                    Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(Color(red: 1, green: 0.65, blue: 0.67))
                        .padding(.horizontal, 20).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conferenceError")
                }
                if [.prejoin, .waiting, .failed, .ended, .suspended].contains(session.phase) {
                    prejoin.frame(maxWidth: 600).frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 12) {
                        if wide || !session.chatVisible { videoGrid }
                        if session.chatVisible { chatPanel.frame(maxWidth: wide ? 350 : .infinity) }
                    }.padding(.horizontal, 12)
                    controls
                }
            }.padding(.top, 16).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(background.ignoresSafeArea())
        }.foregroundStyle(.white).tint(Color(red: 0.67, green: 0.73, blue: 1))
            .preferredColorScheme(.dark).interactiveDismissDisabled()
            .sheet(isPresented: $showParticipants) { participantsPanel }
    }

    private var status: String {
        switch session.phase {
        case .prejoin: "Перед входом во встречу"
        case .waiting: "Ожидаем допуска"
        case .connecting: "Подключение…"
        case .connected: "Вы во встрече"
        case .reconnecting: "Восстанавливаем соединение…"
        case .suspended: "Медиа приостановлено"
        case .failed: "Не удалось подключиться"
        case .ended: "Участие завершено"
        }
    }
    private var prejoin: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 20)
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(panel)
                    VStack(spacing: 16) {
                        Avatar(String(session.participant.displayName.prefix(2)).uppercased(), size: 80)
                        Text(session.participant.displayName).font(MSTheme.font(18, weight: .semibold))
                        Label(tr("Камера и микрофон ещё не включены"), systemImage: "video.slash")
                            .font(MSTheme.font(12)).foregroundStyle(.white.opacity(0.7))
                    }.padding()
                }.frame(height: 230)
                if session.phase == .prejoin {
                    Toggle(tr("Включить микрофон при входе"), isOn: $session.wantsMicrophone).disabled(session.microphoneBlocked)
                    Toggle(tr("Включить камеру при входе"), isOn: $session.wantsCamera).disabled(session.cameraBlocked)
                    Button(tr("Присоединиться")) { session.start() }.buttonStyle(MSButtonStyle())
                        .accessibilityIdentifier("conferenceJoin")
                } else if session.phase == .waiting {
                    ProgressView().tint(.white)
                    Text(tr("Организатор должен разрешить вход. Камера и микрофон выключены."))
                        .multilineTextAlignment(.center)
                } else if session.phase == .failed || session.phase == .suspended {
                    Button(tr("Повторить")) { session.start() }.buttonStyle(MSButtonStyle())
                        .accessibilityIdentifier("conferenceJoin")
                }
                Button(tr("Выйти")) { Task { await close() } }.frame(minHeight: 44)
                    .accessibilityIdentifier("conferenceLeave")
            }.padding(24)
        }
    }
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 160))], spacing: 12) {
                let roster = session.participants.filter { $0.canParticipate }
                if roster.isEmpty { participantTile(session.participant) }
                ForEach(roster) { participantTile($0) }
                ForEach(session.videoTracks.filter { session.isScreenTrack($0) }) { track in
                    if let media = session.media {
                        media.videoView(trackID: track.id, mirrored: false)
                            .frame(minHeight: 180).background(panel).clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel(tr("Демонстрация экрана"))
                    }
                }
            }
        }
    }
    private func participantTile(_ participant: ConferenceParticipant) -> some View {
        let own = participant.id == session.participant.id
        let video = session.videoTracks.first {
            !session.isScreenTrack($0) && (own ? $0.isLocal : session.participantID(for: $0) == participant.id)
        }
        return ZStack(alignment: .bottomLeading) {
            panel
            if let media = session.media, let video, (own ? session.camera : participant.cameraEnabled) {
                media.videoView(trackID: video.id, mirrored: own && session.frontCamera)
            } else {
                Avatar(String(participant.displayName.prefix(2)).uppercased(), size: 66)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                Text(own ? tr("Вы") : participant.displayName).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: (own ? session.microphone : participant.microphoneEnabled) ? "mic" : "mic.slash")
            }.font(MSTheme.font(12)).padding(12).background(.black.opacity(0.35))
        }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 18))
    }
    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                control(session.microphone ? "mic.fill" : "mic.slash", "Микрофон", id: "conferenceMic",
                        active: session.microphone, disabled: session.microphoneBlocked || session.busy || session.phase != .connected) {
                    Task { await session.toggleMicrophone() }
                }
                control(session.camera ? "video.fill" : "video.slash", "Камера", id: "conferenceCamera",
                        active: session.camera, disabled: session.cameraBlocked || session.busy || session.phase != .connected) {
                    Task { await session.toggleCamera() }
                }
                control("person.2", "Участники", id: "conferenceParticipants") {
                    showParticipants = true; Task { await session.refreshParticipants() }
                }
                control("bubble.left", "Чат", id: "conferenceChat", active: session.chatVisible) {
                    session.chatVisible.toggle(); if session.chatVisible { Task { await session.refreshChat() } }
                }
                control("phone.down.fill", "Выйти", id: "conferenceLeave", destructive: true) { Task { await close() } }
            }.padding(.horizontal, 12)
            HStack(spacing: 24) {
                Button { Task { await session.switchCamera() } } label: { Label(tr("Сменить камеру"), systemImage: "arrow.triangle.2.circlepath.camera") }
                    .disabled(!session.camera || session.busy)
                Button { session.toggleSpeaker() } label: {
                    Label(tr(session.speaker ? "Динамик" : "Аудиовыход"), systemImage: "speaker.wave.2")
                }
            }.font(MSTheme.font(11)).frame(minHeight: 44)
            if !session.audioRoute.isEmpty { Text(session.audioRoute).font(MSTheme.font(10)).foregroundStyle(.white.opacity(0.6)) }
        }
    }
    private func control(_ icon: String, _ label: String, id: String, active: Bool = false,
                         disabled: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(destructive ? Color(red: 0.8, green: 0.31, blue: 0.38) : active ? Color(red: 0.28, green: 0.38, blue: 0.64) : panel,
                                in: RoundedRectangle(cornerRadius: 14))
                Text(tr(label)).font(MSTheme.font(10)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .accessibilityLabel(tr(label)).accessibilityValue(tr(active ? "Включён" : "Выключен"))
            .accessibilityIdentifier(id)
    }
    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Чат встречи")).font(MSTheme.font(17, weight: .semibold))
                Spacer()
                Button { session.chatVisible = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel(tr("Закрыть")).accessibilityIdentifier("conferencePanelClose")
            }.padding(.horizontal, 16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.senderName).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(Color(red: 0.7, green: 0.76, blue: 1))
                                Text(message.isDeleted ? tr("Сообщение удалено") : message.text).font(MSTheme.font(14))
                                ForEach(message.attachments) { attachment in
                                    Label(attachment.filename, systemImage: "doc").font(MSTheme.font(12))
                                }
                                Text(message.createdAt, style: .time).font(MSTheme.font(10)).foregroundStyle(.white.opacity(0.55))
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(red: 0.176, green: 0.224, blue: 0.302), in: RoundedRectangle(cornerRadius: 14))
                                .id(message.id)
                        }
                    }.padding(14)
                }.onChange(of: session.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(tr("Написать сообщение…"), text: $session.chatText, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).accessibilityIdentifier("conferenceChatInput")
                Button { Task { await session.sendMessage() } } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }
                    .disabled(session.busy || session.chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(tr("Отправить сообщение")).accessibilityIdentifier("conferenceChatSend")
            }.padding(14)
        }.background(panel).clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private var participantsPanel: some View {
        NavigationStack {
            List {
                ForEach(session.participants) { participant in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(participant.displayName).font(.headline)
                            Spacer()
                            Text(tr(role(participant.role))).font(.caption).foregroundStyle(.secondary)
                        }
                        if participant.isWaiting, session.participant.canAdmit {
                            HStack {
                                Button(tr("Допустить")) { Task { await session.admit(participant, decision: "admit") } }
                                Button(tr("Отклонить"), role: .destructive) { Task { await session.admit(participant, decision: "reject") } }
                            }.buttonStyle(.bordered)
                        } else if session.participant.canModerate(participant, action: "kick") {
                            Menu(tr("Управление участником")) {
                                Button(tr(participant.microphoneBlocked ? "Разрешить микрофон" : "Заблокировать микрофон")) {
                                    Task { await session.moderate(participant, action: "mute", blocked: !participant.microphoneBlocked) }
                                }
                                if session.participant.canModerate(participant, action: "camera") {
                                    Button(tr(participant.cameraBlocked ? "Разрешить камеру" : "Заблокировать камеру")) {
                                        Task { await session.moderate(participant, action: "camera", blocked: !participant.cameraBlocked) }
                                    }
                                }
                                Button(tr(participant.screenBlocked ? "Разрешить демонстрацию" : "Заблокировать демонстрацию")) {
                                    Task { await session.moderate(participant, action: "screen", blocked: !participant.screenBlocked) }
                                }
                                if session.participant.canModerate(participant, action: "role") {
                                    Button(tr(participant.role == "co_host" ? "Сделать участником" : "Назначить соведущим")) {
                                        Task { await session.moderate(participant, action: "role", role: participant.role == "co_host" ? "participant" : "co_host") }
                                    }
                                }
                                Button(tr("Удалить из встречи"), role: .destructive) { Task { await session.moderate(participant, action: "kick") } }
                            }.disabled(session.busy)
                        }
                    }.padding(.vertical, 5)
                }
            }.navigationTitle(tr("Участники")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Готово")) { showParticipants = false }.accessibilityIdentifier("conferencePanelClose")
                } }
                .refreshable { await session.refreshParticipants() }
        }
    }
    private func role(_ value: String) -> String {
        switch value { case "owner": "Организатор"; case "co_host": "Соведущий"; case "guest": "Гость"; default: "Участник" }
    }
}
