import SwiftUI
import MeetSpaceCore
import MeetSpaceMedia
import MeetSpaceDesignSystem

struct DirectCallView: View {
    @Bindable var call: DirectCallCoordinator
    @Environment(\.dynamicTypeSize) private var typeSize
    private let background = Color(red: 0.078, green: 0.118, blue: 0.188)
    private var connected: Bool { call.mediaSession?.phase == .connected && call.currentCall?.status == .accepted }
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Button { call.minimize() } label: {
                            Image(systemName: "chevron.down").frame(width: 44, height: 44)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                        }.accessibilityLabel(tr("Свернуть звонок")).accessibilityIdentifier("directCallMinimize")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Личный звонок")).font(MSTheme.font(16, weight: .semibold))
                                .accessibilityIdentifier("screen.directCall")
                            Label(tr("Разговор один на один"), systemImage: "person.2")
                                .font(MSTheme.font(10)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                        if connected {
                            Text(String(format: "%02d:%02d", call.elapsedSeconds / 60, call.elapsedSeconds % 60))
                                .font(.system(size: 12, design: .monospaced)).padding(10)
                                .background(.white.opacity(0.07), in: Capsule())
                                .accessibilityLabel(tr("Длительность звонка"))
                        }
                    }
                    if connected, let session = call.mediaSession { ScreenShareControls(session: session) }
                    video.frame(height: max(typeSize.isAccessibilitySize ? 340 : 260,
                        proxy.size.height - (call.error != nil || call.mediaSession?.error != nil ? 370 : 280)))
                    if let error = call.error ?? call.mediaSession?.error {
                        Text(tr(error)).font(MSTheme.font(13)).multilineTextAlignment(.center)
                            .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.67)).accessibilityIdentifier("directCallError")
                    }
                    if call.otherDevice {
                        Text(tr("Звонок продолжается на другом устройстве.")).multilineTextAlignment(.center)
                        Button(tr("Закрыть")) { call.minimize() }.frame(minHeight: 44)
                    } else if call.currentCall?.isTerminal == true {
                        Button(tr("Готово")) { call.minimize() }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("directCallDone")
                    } else {
                        if call.currentCall?.status == .accepted { mediaControls }
                        else { HStack(spacing: 40) {
                            control("phone.down.fill", call.isIncoming ? "Отклонить" : "Завершить", id: "directCallEnd", color: MSTheme.danger) {
                                Task { await call.end() }
                            }.disabled(call.ending)
                            if call.isIncoming {
                                control("phone.fill", "Ответить", id: "directCallAnswer", color: MSTheme.success) {
                                    Task { await call.answer() }
                                }.disabled(call.busy)
                            }
                        }
                        }
                        if call.uncertain {
                            Button(tr(call.ending ? "Проверить отмену" : "Проверить состояние")) {
                                Task {
                                    if call.ending { await call.end() }
                                    await call.reconcile()
                                }
                            }.frame(minHeight: 44).disabled(call.busy)
                                .accessibilityIdentifier("directCallReconcile")
                            if let peer = call.pendingPeer, !call.ending {
                                Button(tr("Повторить вызов")) { Task { await call.startOutgoing(peer: peer, isVideo: call.cameraWanted) } }
                                    .frame(minHeight: 44).disabled(call.busy)
                            }
                        }
                    }
                }.padding(.horizontal, proxy.size.width >= 780 ? 24 : 12).padding(.vertical, 16).frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }.background(background.ignoresSafeArea())
        }.foregroundStyle(.white).tint(.white).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    @ViewBuilder private var video: some View {
        if let session = call.mediaSession, let media = session.media,
           let remote = session.videoTracks.first(where: { !$0.isLocal && session.isScreenTrack($0) }) ?? session.videoTracks.first(where: { !$0.isLocal }) {
            media.videoView(trackID: remote.id, mirrored: false, fit: session.isScreenTrack(remote))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topTrailing) { localPreview(session).padding(14) }
                .overlay(alignment: .bottomLeading) { peerLabels.padding(18).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16)).padding(12) }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(RadialGradient(colors: [Color(red: 0.176, green: 0.227, blue: 0.345), Color(red: 0.106, green: 0.149, blue: 0.235)], center: .center, startRadius: 10, endRadius: 500))
                VStack(spacing: 22) {
                    Text(String((call.peer?.displayName ?? "").prefix(2)).uppercased())
                        .font(MSTheme.font(37)).frame(width: 112, height: 112)
                        .background(Color(red: 0.259, green: 0.349, blue: 0.506), in: Circle())
                    peerLabels
                }.padding(22)
            }.overlay(alignment: .topTrailing) {
                if let session = call.mediaSession { localPreview(session).padding(12) }
            }
        }
    }
    private var peerLabels: some View {
        VStack(spacing: 12) {
            Text(call.peer?.displayName ?? tr("Личный звонок"))
                .font(MSTheme.font(25, weight: .semibold)).multilineTextAlignment(.center)
            Text(tr(status)).font(MSTheme.font(13)).foregroundStyle(connected ? Color(red: 0.58, green: 0.85, blue: 0.76) : .white.opacity(0.65))
                .accessibilityIdentifier("directCallStatus")
        }
    }
    @ViewBuilder private func localPreview(_ session: ConferenceSession) -> some View {
        if session.camera, let media = session.media, let local = session.videoTracks.first(where: { $0.isLocal && !session.isScreenTrack($0) }) {
            media.videoView(trackID: local.id, mirrored: session.frontCamera)
                .frame(width: 90, height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Ваше видео")).accessibilityIdentifier("directCallLocalVideo")
        }
    }
    private var mediaControls: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 125 : 65))], spacing: 16) {
                control(call.mediaSession?.microphone == true ? "mic.fill" : "mic.slash", "Микрофон", id: "directCallMic") {
                    Task { await call.setMuted(call.mediaSession?.microphone == true) }
                }.disabled(!connected || call.busy).accessibilityValue(tr(call.mediaSession?.microphone == true ? "Включён" : "Выключен"))
                control(call.mediaSession?.camera == true ? "video.fill" : "video.slash", "Камера", id: "directCallCamera") {
                    Task { await call.toggleCamera() }
                }.disabled(!connected || call.busy).accessibilityValue(tr(call.mediaSession?.camera == true ? "Включена" : "Выключена"))
                control("speaker.wave.2", "Динамик", id: "directCallSpeaker") { call.mediaSession?.toggleSpeaker() }
                control("phone.down.fill", "Завершить", id: "directCallEnd", color: MSTheme.danger) {
                    Task { await call.end() }
                }.disabled(call.ending)
                if call.mediaSession?.camera == true {
                    control("arrow.triangle.2.circlepath.camera", "Сменить камеру", id: "directCallSwitchCamera") {
                        Task { await call.mediaSession?.switchCamera() }
                    }
                }
            }

            if let route = call.mediaSession?.audioRoute, !route.isEmpty {
                Text(tr(route)).font(MSTheme.font(11)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }
    private func control(_ image: String, _ label: String, id: String, color: Color = .white.opacity(0.12), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: image).font(.system(size: 22)).frame(width: 56, height: 56).background(color, in: RoundedRectangle(cornerRadius: 18))
                Text(tr(label)).font(MSTheme.font(11)).multilineTextAlignment(.center)
            }.frame(minWidth: 64, minHeight: 88)
        }.buttonStyle(.plain).accessibilityLabel(tr(label)).accessibilityIdentifier(id)
    }
    private var status: String {
        if call.ending { return "Завершаем звонок…" }
        if call.otherDevice { return "Другое устройство" }
        switch call.currentCall?.status {
        case .ringing: return call.isIncoming ? "Входящий звонок" : "Вызываем…"
        case .accepted:
            switch call.mediaSession?.phase {
            case .connected: return "Соединение установлено"
            case .reconnecting: return "Восстанавливаем соединение…"
            case .failed: return "Не удалось подключиться"
            default: return "Подключение…"
            }
        case .declined: return "Вызов отклонён"
        case .cancelled: return "Вызов отменён"
        case .missed: return "Нет ответа"
        case .ended: return "Звонок завершён"
        case nil: return call.uncertain ? "Проверяем состояние звонка…" : "Вызываем…"
        }
    }
}

private struct DirectCallPresentation: ViewModifier {
    @Bindable var model: AppModel
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
        .fullScreenCover(isPresented: shown) { if let call = model.identity.calls { DirectCallView(call: call) } }
        #else
        .sheet(isPresented: shown) { if let call = model.identity.calls { DirectCallView(call: call).frame(minWidth: 420, minHeight: 650) } }
        #endif
    }
}
extension View {
    func directCallPresentation(model: AppModel) -> some View { modifier(DirectCallPresentation(model: model)) }
}
