import SwiftUI
import MeetSpaceCore
import MeetSpaceMedia
import MeetSpaceDesignSystem

struct DirectCallView: View {
    @Bindable var call: DirectCallCoordinator
    var localName: String = ""

    private var connected: Bool { call.mediaSession?.phase == .connected && call.currentCall?.status == .accepted }
    private var ringing: Bool { call.currentCall?.status == .ringing || (call.currentCall == nil && call.pendingPeer != nil && !call.uncertain) }
    private var microphone: Bool { call.mediaSession?.microphone ?? (ringing && call.microphoneWanted) }
    private var camera: Bool { call.mediaSession?.camera ?? false }
    private var peerName: String { call.peer?.displayName ?? tr("Личный звонок") }
    private var currentMedia: ConferenceSession? { connected ? call.mediaSession : nil }

    var body: some View {
        PersonalCallScreen(active: connected, elapsed: call.elapsedSeconds, close: { call.minimize() }) { compact, short in
            stage(compact: compact, short: short)
        } footer: { compact in
            footer(compact: compact)
        }
        .interactiveDismissDisabled()
    }

    private func stage(compact: Bool, short: Bool) -> some View {
        let session = call.mediaSession
        let remote = session.flatMap(remoteTrack)
        let hasRemoteVideo = session?.media != nil && remote != nil
        return PersonalCallStage(compact: compact, short: short, connected: connected, ringing: ringing && !call.ending,
                                 peerName: peerName, status: status, hasRemoteVideo: hasRemoteVideo) {
            if let session, let media = session.media, let remote {
                media.videoView(trackID: remote.id, mirrored: false, fit: session.isScreenTrack(remote))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peerName).font(MSTheme.font(12, weight: .semibold))
                            Text(tr(status)).font(MSTheme.font(11))
                                .accessibilityIdentifier("directCallStatus")
                        }.padding(9).background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8)).padding(10)
                    }
            }
        } local: {
            if !call.otherDevice, call.currentCall?.isTerminal != true {
                PersonalSelfPreview(name: localName, compact: compact, short: short, camera: camera, microphone: microphone) {
                    if camera, let session = call.mediaSession, let media = session.media,
                       let local = session.videoTracks.first(where: { $0.isLocal && !session.isScreenTrack($0) }) {
                        media.videoView(trackID: local.id, mirrored: session.frontCamera)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(tr("Ваше видео")).accessibilityIdentifier("directCallLocalVideo")
                    }
                }
            }
        }
    }

    private func remoteTrack(in session: ConferenceSession) -> ConferenceVideoTrack? {
        session.videoTracks.first(where: { !$0.isLocal && session.isScreenTrack($0) }) ??
            session.videoTracks.first(where: { !$0.isLocal })
    }

    private func footer(compact: Bool) -> some View {
        VStack(spacing: 12) {
            if let error = call.error ?? call.mediaSession?.error {
                Text(tr(error)).font(MSTheme.font(12)).multilineTextAlignment(.center)
                    .foregroundStyle(PersonalCallColors.warning).accessibilityIdentifier("directCallError")
            }
            if let shareError = currentMedia?.screenShareError {
                Text(tr(shareError)).font(MSTheme.font(12)).multilineTextAlignment(.center)
                    .foregroundStyle(PersonalCallColors.warning).accessibilityIdentifier("screenShareError")
            }
            if currentMedia?.screenSharing == true {
                Label(tr("Вы демонстрируете экран"), systemImage: "display").font(MSTheme.font(11))
                    .foregroundStyle(PersonalCallColors.connected).accessibilityIdentifier("screenShareStatus")
            }
            if call.otherDevice {
                Text(tr("Звонок продолжается на другом устройстве.")).multilineTextAlignment(.center)
                Button(tr("Закрыть")) { call.minimize() }.buttonStyle(MSButtonStyle(primary: false))
            } else if call.currentCall?.isTerminal == true {
                Button(tr("Готово")) { call.minimize() }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("directCallDone")
            } else {
                Text(tr(connected ? "Разговор один на один" : "Собеседник услышит вас после ответа"))
                    .font(MSTheme.font(compact ? 10 : 11)).foregroundStyle(PersonalCallColors.secondary)
                    .multilineTextAlignment(.center).padding(.bottom, 4)
                if call.isIncoming {
                    HStack(spacing: 38) {
                        endControl("Отклонить", compact: compact)
                        PersonalCallControl("Ответить", icon: "phone.fill", id: "directCallAnswer", compact: compact,
                                            tint: .green, action: { Task { await call.answer() } }).disabled(call.busy)
                    }
                } else {
                    callControls(compact: compact)
                }
                if connected { audioAndCameraControls }
                if call.uncertain { recoveryControls }
            }
        }
    }

    private func callControls(compact: Bool) -> some View {
        PersonalCallControlGroup(compact: compact) {
            PersonalCallControl("Микрофон", icon: microphone ? "mic" : "mic.slash", id: "directCallMic", compact: compact,
                                active: microphone, displayLabel: microphone ? "Микрофон" : "Без звука") {
                Task { await call.setMuted(call.mediaSession?.microphone == true) }
            }.disabled(!connected || call.busy).accessibilityValue(tr(microphone ? "Включён" : "Выключен"))
            PersonalCallControl("Камера", icon: camera ? "video" : "video.slash", id: "directCallCamera", compact: compact, active: camera) {
                Task { await call.toggleCamera() }
            }.disabled(!connected || call.busy).accessibilityValue(tr(camera ? "Включена" : "Выключена"))
            if let session = currentMedia {
                ScreenShareControls(session: session, compact: compact, style: .personal)
            } else {
                PersonalCallControl("Показать экран", icon: "display", id: "screenShareStart", compact: compact, displayLabel: "Экран") {}
                    .disabled(true)
            }
            endControl("Завершить", compact: compact)
        }
    }

    private var audioAndCameraControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { secondaryControls }
            VStack(spacing: 2) { secondaryControls }
        }.font(MSTheme.font(11)).foregroundStyle(PersonalCallColors.secondary)
    }

    @ViewBuilder private var secondaryControls: some View {
        Button { call.mediaSession?.toggleSpeaker() } label: {
            Label(tr(audioRouteLabel), systemImage: "speaker.wave.2").fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("directCallSpeaker")
            .accessibilityLabel(tr("Динамик"))
            .accessibilityValue(Text(tr(call.mediaSession?.speaker == true ? "Включён" : "Выключен")))
        if camera {
            Button { Task { await call.mediaSession?.switchCamera() } } label: {
                Label(tr("Сменить камеру"), systemImage: "arrow.triangle.2.circlepath.camera")
                    .fixedSize(horizontal: true, vertical: false).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("directCallSwitchCamera")
        }
    }

    private var audioRouteLabel: String {
        guard let route = call.mediaSession?.audioRoute, !route.isEmpty else { return "Динамик" }
        return route
    }

    private var recoveryControls: some View {
        VStack(spacing: 4) {
            Button(tr(call.ending ? "Проверить отмену" : "Проверить состояние")) {
                Task {
                    if call.ending { await call.end() }
                    await call.reconcile()
                }
            }.frame(minHeight: 44).disabled(call.busy).accessibilityIdentifier("directCallReconcile")
            if let peer = call.pendingPeer, !call.ending {
                Button(tr("Повторить вызов")) { Task { await call.startOutgoing(peer: peer, isVideo: call.cameraWanted) } }
                    .frame(minHeight: 44).disabled(call.busy)
            }
        }
    }

    private func endControl(_ label: String, compact: Bool) -> some View {
        PersonalCallControl(label, icon: "phone.down", id: "directCallEnd", compact: compact, tint: PersonalCallColors.end) {
            Task { await call.end() }
        }.disabled(call.ending)
    }

    private var status: String {
        if call.ending { return "Завершаем звонок…" }
        if call.otherDevice { return "Другое устройство" }
        switch call.currentCall?.status {
        case .ringing: return call.isIncoming ? "Входящий звонок" : "Вы звоните…"
        case .accepted:
            switch call.mediaSession?.phase {
            case .connected: return "На связи"
            case .reconnecting: return "Восстанавливаем соединение…"
            case .failed: return "Не удалось подключиться"
            default: return "Подключение…"
            }
        case .declined: return "Вызов отклонён"
        case .cancelled: return "Вызов отменён"
        case .missed: return "Нет ответа"
        case .ended: return "Звонок завершён"
        case nil: return call.uncertain ? "Проверяем состояние звонка…" : "Вы звоните…"
        }
    }
}

enum PersonalCallColors {
    static let background = Color(red: 0.078, green: 0.118, blue: 0.188)
    static let ink = Color(red: 0.945, green: 0.961, blue: 1)
    static let secondary = Color(red: 0.69, green: 0.75, blue: 0.86)
    static let stroke = Color(red: 0.2, green: 0.255, blue: 0.341)
    static let control = Color(red: 0.169, green: 0.224, blue: 0.318)
    static let active = Color(red: 0.851, green: 0.898, blue: 0.98)
    static let end = Color(red: 0.859, green: 0.31, blue: 0.396)
    static let connected = Color(red: 0.58, green: 0.85, blue: 0.76)
    static let warning = Color(red: 1, green: 0.74, blue: 0.77)
}

struct PersonalCallScreen<Stage: View, Footer: View>: View {
    let active: Bool
    let elapsed: Int
    var demo = false
    let close: () -> Void
    @ViewBuilder let stage: (Bool, Bool) -> Stage
    @ViewBuilder let footer: (Bool) -> Footer
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var headerHeight: CGFloat = 66
    @State private var footerHeight: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 600
            let short = compact && proxy.size.height < 650
            let minimum: CGFloat = typeSize.isAccessibilitySize ? 380 : 270
            ScrollView {
                VStack(spacing: 0) {
                    header(compact: compact)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    stage(compact, short).frame(height: max(minimum, proxy.size.height - headerHeight - footerHeight))
                        .padding(.horizontal, compact ? 12 : 24)
                    footer(compact).frame(maxWidth: .infinity).padding(.horizontal, compact ? 16 : 24)
                        .padding(.top, short ? 13 : 16).padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
            }.scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(PersonalCallColors.ink).tint(PersonalCallColors.active)
        .background(PersonalCallColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 10) {
            Button(action: close) {
                WorkspaceIcon("chevron.down", size: 18).frame(width: compact ? 34 : 40, height: compact ? 36 : 40)
                    .background(PersonalCallColors.control, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PersonalCallColors.stroke))
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tr("Свернуть звонок"))
                .accessibilityIdentifier(demo ? "demoDirectCallMinimize" : "directCallMinimize")
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Личный звонок")).font(MSTheme.font(compact ? 16 : 18, weight: .semibold, relativeTo: .headline))
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier(demo ? "screen.demoDirectCall" : "screen.directCall")
                HStack(spacing: 4) {
                    if active { WorkspaceIcon("lock", size: 11) }
                    Text(tr(active ? "Соединение установлено" : "Соединяем вас с собеседником"))
                        .font(MSTheme.font(compact ? 9 : 10))
                }.foregroundStyle(PersonalCallColors.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if active {
                HStack(spacing: 5) {
                    WorkspaceIcon("phone", size: 12).foregroundStyle(PersonalCallColors.connected)
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(MSTheme.font(compact ? 11 : 12)).monospacedDigit().lineLimit(1)
                }.padding(.horizontal, compact ? 9 : 12).padding(.vertical, 8)
                    .background(PersonalCallColors.control, in: Capsule())
                    .overlay(Capsule().strokeBorder(PersonalCallColors.stroke))
                    .accessibilityLabel(tr("Длительность звонка"))
            }
        }.padding(.horizontal, compact ? 16 : 24).padding(.top, compact ? 7 : 12)
            .padding(.bottom, compact ? 14 : 15)
    }
}

struct PersonalCallStage<Remote: View, Local: View>: View {
    let compact: Bool
    let short: Bool
    let connected: Bool
    let ringing: Bool
    let peerName: String
    let status: String
    var hasRemoteVideo = false
    var demo = false
    @ViewBuilder let remote: () -> Remote
    @ViewBuilder let local: () -> Local

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 24 : 26)
        ZStack {
            shape.fill(RadialGradient(colors: [Color(red: 0.176, green: 0.227, blue: 0.345),
                                                Color(red: 0.129, green: 0.176, blue: 0.267),
                                                Color(red: 0.106, green: 0.149, blue: 0.235)],
                                      center: UnitPoint(x: 0.48, y: 0.42), startRadius: 0, endRadius: compact ? 320 : 670))
            if hasRemoteVideo { remote() } else { placeholder }
        }.overlay(alignment: .topTrailing) { local().padding(compact ? 14 : 22) }
            .clipShape(shape).overlay(shape.strokeBorder(PersonalCallColors.stroke).allowsHitTesting(false))
    }

    private var placeholder: some View {
        VStack(spacing: 0) {
            avatar
            Text(peerName).font(MSTheme.font(short ? 22 : compact ? 25 : 27, weight: .semibold, relativeTo: .title2))
                .padding(.top, short ? 21 : 27).multilineTextAlignment(.center)
            Text(tr(status)).font(MSTheme.font(13)).multilineTextAlignment(.center)
                .foregroundStyle(connected ? PersonalCallColors.connected : PersonalCallColors.secondary)
                .padding(.top, short ? 8 : 12)
                .accessibilityIdentifier(demo ? "demoDirectCallStatus" : "directCallStatus")
            if connected {
                Label(tr("Камера собеседника выключена"), systemImage: "video.slash")
                    .font(MSTheme.font(compact ? 9 : 10)).multilineTextAlignment(.center)
                    .foregroundStyle(PersonalCallColors.secondary).padding(.top, compact ? 15 : 20)
            } else if ringing {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle().fill(PersonalCallColors.secondary.opacity(1 - Double(index) * 0.2)).frame(width: 5, height: 5)
                    }
                }.padding(.top, 21).accessibilityHidden(true)
            }
        }.padding(.horizontal, 14).padding(.top, compact ? (short ? 38 : 64) : 0)
    }

    private var avatar: some View {
        let size: CGFloat = short ? 82 : compact ? 112 : 150
        return Text(callInitials(peerName)).font(MSTheme.font(short ? 28 : compact ? 37 : 48, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .foregroundStyle(PersonalCallColors.active)
            .background(Color(red: 0.259, green: 0.349, blue: 0.506), in: Circle())
            .overlay(Circle().strokeBorder(PersonalCallColors.active.opacity(0.16)))
            .background { Circle().fill(PersonalCallColors.active.opacity(0.025)).padding(compact ? -25 : -33) }
            .background { Circle().fill(PersonalCallColors.active.opacity(0.035)).padding(compact ? -12 : -16) }
            .accessibilityHidden(true)
    }
}

struct PersonalSelfPreview<Video: View>: View {
    let name: String
    let compact: Bool
    let short: Bool
    let camera: Bool
    let microphone: Bool
    @ViewBuilder let video: () -> Video

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 14 : 18)
        let size: CGFloat = short ? 27 : compact ? 34 : 47
        ZStack {
            shape.fill(Color(red: 0.204, green: 0.255, blue: 0.345))
            Circle().fill(Color(red: 0.271, green: 0.333, blue: 0.455))
                .overlay(Circle().strokeBorder(PersonalCallColors.active.opacity(0.26)))
                .frame(width: size, height: size)
                .overlay {
                    if name.isEmpty {
                        WorkspaceIcon("person", size: size * 0.42)
                    } else {
                        Text(callInitials(name)).font(MSTheme.font(short ? 9 : compact ? 11 : 15))
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
                .foregroundStyle(PersonalCallColors.active).accessibilityHidden(true)
            video().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            WorkspaceIcon(camera ? "video" : "video.slash", size: 12)
                .foregroundStyle(camera ? PersonalCallColors.connected : PersonalCallColors.secondary).padding(8)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Text(tr("Вы")).font(MSTheme.font(compact ? 9 : 10)).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                WorkspaceIcon(microphone ? "mic" : "mic.slash", size: compact ? 10 : 12)
            }.padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 5 : 7)
                .background(PersonalCallColors.background.opacity(0.8), in: RoundedRectangle(cornerRadius: compact ? 7 : 9))
                .padding(compact ? 6 : 9).allowsHitTesting(false)
        }
        .frame(width: short ? 62 : compact ? 78 : 124, height: short ? 78 : compact ? 102 : 150)
        .clipShape(shape).overlay(shape.strokeBorder(Color(red: 0.318, green: 0.377, blue: 0.475)).allowsHitTesting(false))
    }
}

struct PersonalCallControlGroup<Buttons: View>: View {
    let compact: Bool
    @ViewBuilder let buttons: () -> Buttons
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12, content: buttons)
        } else {
            HStack(alignment: .top, spacing: compact ? 0 : 20, content: buttons)
                .frame(maxWidth: compact ? .infinity : 370)
        }
    }
}

struct PersonalCallControl: View {
    let label: String
    let icon: String
    let id: String
    let compact: Bool
    let active: Bool
    let tint: Color?
    let displayLabel: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, icon: String, id: String, compact: Bool, active: Bool = false, tint: Color? = nil,
         displayLabel: String? = nil, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.id = id; self.compact = compact; self.active = active
        self.tint = tint; self.displayLabel = displayLabel; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                WorkspaceIcon(icon, size: 23).foregroundStyle(tint != nil ? .white : active ? PersonalCallColors.background : PersonalCallColors.secondary)
                    .frame(width: compact ? 54 : 58, height: compact ? 52 : 54)
                    .background(tint ?? (active ? PersonalCallColors.active : PersonalCallColors.control), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(tint == nil ? 0.13 : 0.22)))
                    .opacity(isEnabled ? 1 : 0.75)
                Text(tr(displayLabel ?? label)).font(MSTheme.font(compact ? 9 : 10))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(tint == nil ? PersonalCallColors.secondary : PersonalCallColors.ink)
            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .top).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(tr(label)).accessibilityIdentifier(id)
    }
}

func callInitials(_ name: String) -> String {
    let initials = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
    return String(initials).uppercased()
}

private struct DirectCallPresentation: ViewModifier {
    @Bindable var model: AppModel
    private var localName: String { model.identity.settings?.profile.name ?? model.identity.messaging?.account.user.name ?? "" }
    private var shown: Binding<Bool> {
        Binding(get: {
            guard model.activeConference == nil, let call = model.identity.calls else { return false }
            return !call.minimized && (call.isActive || call.currentCall != nil)
        }, set: { if !$0 { model.identity.calls?.minimize() } })
    }
    func body(content: Content) -> some View {
        // Give the navigation container its own reduced frame. Changing only its safe-area
        // inset while dismissing the call cover clips page headers on compact iOS layouts.
        VStack(spacing: 0) {
            if let call = model.identity.calls, call.isActive, call.minimized {
                Button { call.resume() } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text(call.peer?.displayName ?? tr("Личный звонок")).lineLimit(1)
                        Spacer()
                        Text(tr("Вернуться к звонку")).font(MSTheme.font(12))
                    }.padding(12).foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("directCallBanner")
            }
            content
        }
        #if os(iOS)
        .fullScreenCover(isPresented: shown) { if let call = model.identity.calls { DirectCallView(call: call, localName: localName) } }
        #else
        .sheet(isPresented: shown) { if let call = model.identity.calls { DirectCallView(call: call, localName: localName).frame(minWidth: 420, minHeight: 650) } }
        #endif
    }
}
extension View {
    func directCallPresentation(model: AppModel) -> some View { modifier(DirectCallPresentation(model: model)) }
}
