import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct CallPreviewView: View {
    @Bindable var model: AppModel
    let route: AppRoute

    var body: some View {
        switch route {
        case .personalCall: DemoPersonalCall(model: model)
        case .prejoin: DemoMeetingPrejoin(model: model)
        default: DemoConferenceView(model: model)
        }
    }
}

private struct DemoMeetingPrejoin: View {
    let model: AppModel
    @State private var name = ""
    @State private var microphone = true
    @State private var camera = !AccountVideoPreferences.load(for: nil).cameraOff
    @State private var guest = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MeetingPrejoinLayout(onBack: { dismiss() }) {
            MeetingCameraPreview(name: name.isEmpty ? model.demoProfile.name : name, camera: camera, microphone: microphone,
                                 toggleCamera: { camera.toggle() }, toggleMicrophone: { microphone.toggle() })
        } details: {
            MeetingPrejoinHeading(title: model.demoPrejoinTitle ?? tr("Дизайн-синхронизация"),
                                  subtitle: tr("Проверьте звук и камеру перед встречей"))
            Button {
                guest.toggle()
            } label: {
                Label(tr(guest ? "Вход без аккаунта · гость" : "Присоединиться как гость"), systemImage: "person")
                    .font(MSTheme.font(12)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).frame(minHeight: 44).padding(.vertical, 1)
                    .foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).accessibilityAddTraits(guest ? .isSelected : [])
            MeetingPrejoinName(name: $name, guest: guest)
                .padding(.top, 8)
            MeetingMicrophoneRow(route: tr("Встроенный микрофон")) { model.navigate(.audioSettings) }
            VStack(spacing: 0) {
                Button {
                    let participant = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.demoConferenceEntry = DemoConferenceEntry(name: participant, microphone: microphone, camera: camera,
                                                                     title: model.demoPrejoinTitle, guest: guest)
                    model.navigate(.call)
                } label: {
                    Label(tr("Присоединиться"), systemImage: "arrow.right").labelStyle(MeetingNextLabelStyle())
                }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("conferencePreviewJoin")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(tr("Вернуться к встречам")) { dismiss() }.buttonStyle(MSTextButtonStyle())
            }.padding(.top, 13)
            Text(tr("Демоэкраны · камера и микрофон устройства не используются"))
                .font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 6)
        }.onAppear { if name.isEmpty { name = model.demoProfile.name } }
    }
}

struct MeetingPrejoinLayout<Preview: View, Details: View>: View {
    let onBack: () -> Void
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let details: () -> Details
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 780 && !typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                PageHeader(title: "Перед встречей") {
                    WorkspaceHeaderButton("arrow.left", label: "Вернуться к встречам", action: onBack)
                        .accessibilityIdentifier("prejoinBack")
                }
                GeometryReader { available in
                    ScrollView {
                        if wide {
                            let splitWidth = max(0, min(available.size.width, 1210) - 96 - 32)
                            let cameraWidth = splitWidth * 5 / 9
                            HStack(spacing: 32) {
                                preview().frame(width: cameraWidth, height: cameraWidth * 0.75)
                                info
                            }
                            .padding(.horizontal, 48).padding(.vertical, 24)
                            .frame(maxWidth: 1210).frame(maxWidth: .infinity, minHeight: available.size.height)
                        } else {
                            let cameraWidth = max(0, min(available.size.width, 556) - 36)
                            VStack(spacing: 25) {
                                preview().frame(height: max(typeSize.isAccessibilitySize ? 270 : 220, cameraWidth * 0.75))
                                info
                            }.padding(.horizontal, 18).padding(.vertical, 22)
                                .frame(maxWidth: 556).frame(maxWidth: .infinity)
                        }
                    }.scrollBounceBehavior(.basedOnSize)
                }
            }.background(MSTheme.background.ignoresSafeArea())
                .environment(\.workspaceWidth, proxy.size.width)
        }.toolbar(.hidden)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12, content: details)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeetingCameraPreview: View {
    let name: String
    let camera: Bool
    let microphone: Bool
    var cameraDisabled = false
    var microphoneDisabled = false
    let toggleCamera: () -> Void
    let toggleMicrophone: () -> Void
    @Environment(\.workspaceWidth) private var width
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wide = width >= 780 && !typeSize.isAccessibilitySize
        let size: CGFloat = wide ? 96 : 76
        let shape = RoundedRectangle(cornerRadius: wide ? 25 : 20)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(callInitials(name)).font(MSTheme.font(wide ? 30 : 25, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(Color(red: 0.28, green: 0.41, blue: 0.75))
                .frame(width: size, height: size)
                .background(Color(red: 0.87, green: 0.90, blue: 0.98), in: Circle())
                .accessibilityHidden(true)
            Text(tr(camera ? "Камера включится при входе" : "Камера выключена"))
                .font(MSTheme.font(12)).foregroundStyle(Color(red: 0.75, green: 0.80, blue: 0.88))
                .multilineTextAlignment(.center).padding(.top, wide ? 18 : 12)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12).padding(.bottom, typeSize.isAccessibilitySize ? 48 : 0)
            .background(Color(red: 0.133, green: 0.176, blue: 0.25), in: shape)
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    button(microphone ? "mic" : "mic.slash", label: "Микрофон", id: "prejoinMicrophone",
                           enabled: microphone, disabled: microphoneDisabled, action: toggleMicrophone)
                    button(camera ? "video" : "video.slash", label: "Камера", id: "prejoinCamera",
                           enabled: camera, disabled: cameraDisabled, action: toggleCamera)
                }.padding(.bottom, wide ? 20 : 16)
            }.accessibilityIdentifier("prejoinCameraPreview")
    }

    private func button(_ icon: String, label: String, id: String, enabled: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            WorkspaceIcon(icon, size: 20)
                .frame(width: 48, height: 48)
                .foregroundStyle(enabled ? .white : Color(red: 0.16, green: 0.22, blue: 0.3))
                .background(enabled ? .white.opacity(0.13) : .white, in: RoundedRectangle(cornerRadius: 14))
                .opacity(disabled ? 0.52 : 1)
        }.buttonStyle(.plain).disabled(disabled)
            .accessibilityLabel(tr(label)).accessibilityValue(tr(enabled ? "Включено" : "Выключено"))
            .accessibilityAddTraits(enabled ? .isSelected : [])
            .accessibilityIdentifier(id)
    }
}

struct MeetingPrejoinHeading: View {
    let title: String
    let subtitle: String
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Ваша следующая встреча"), systemImage: "video")
                .font(MSTheme.font(11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 30)
                .foregroundStyle(MSTheme.accent).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(MSTheme.font(width >= 780 ? 30 : 26, weight: .semibold, relativeTo: .title2))
                .tracking(-0.5).accessibilityAddTraits(.isHeader).accessibilityIdentifier("screen.conference")
            Text(subtitle).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MeetingPrejoinName: View {
    @Binding var name: String
    var guest = false
    var body: some View {
        let label = tr(guest ? "Как вас представить?" : "Ваше имя")
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(MSTheme.font(13, weight: .semibold))
            TextField(label, text: $name).textFieldStyle(.plain).font(MSTheme.font(15)).textContentType(.name)
                .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 50)
                .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line))
                .accessibilityIdentifier("prejoinName")
        }
    }
}

struct MeetingMicrophoneRow: View {
    let route: String
    let configure: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            WorkspaceIcon("mic", size: 17)
            Text(route).font(MSTheme.font(11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton("gearshape", label: "Настроить устройства", action: configure)
        }.foregroundStyle(MSTheme.muted)
    }
}

struct MeetingNextLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.title.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            configuration.icon.accessibilityHidden(true)
        }
    }
}

private struct DemoPersonalCall: View {
    let model: AppModel
    private let showSelf = AccountVideoPreferences.load(for: nil).selfVideo
    @State private var connectedAt: Date?
    @State private var microphone = true
    @State private var camera = false
    @State private var sharing = false
    @State private var confirmSharing = false
    @Environment(\.dismiss) private var dismiss

    private var peer: String {
        for route in model.messagesPath.reversed() {
            if case let .thread(index) = route, let contact = DemoChatStore.contacts.first(where: { $0.id == index }) {
                return contact.name
            }
        }
        return tr("Анна Кузнецова")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = connectedAt.map { max(0, Int(timeline.date.timeIntervalSince($0))) } ?? 0
            PersonalCallScreen(active: connectedAt != nil, elapsed: elapsed, demo: true, close: { dismiss() }) { compact, short in
                PersonalCallStage(compact: compact, short: short, connected: connectedAt != nil, ringing: connectedAt == nil,
                                  peerName: peer, status: connectedAt == nil ? "Вы звоните…" : "На связи", demo: true) {
                    EmptyView()
                } local: {
                    if showSelf {
                        PersonalSelfPreview(name: model.demoProfile.name, compact: compact, short: short, camera: camera, microphone: microphone) {
                            EmptyView()
                        }
                    }
                }.overlay(alignment: .bottom) {
                    if sharing {
                        Label(tr("Вы демонстрируете экран"), systemImage: "display").font(MSTheme.font(11))
                            .padding(12).frame(maxWidth: .infinity)
                            .background(PersonalCallColors.control, in: RoundedRectangle(cornerRadius: 12)).padding(12)
                    }
                }
            } footer: { compact in
                VStack(spacing: compact ? 14 : 16) {
                    Text(tr("Предпросмотр звонка")).font(MSTheme.font(compact ? 10 : 11))
                        .foregroundStyle(PersonalCallColors.secondary)
                    PersonalCallControlGroup(compact: compact) {
                        PersonalCallControl("Микрофон", icon: microphone ? "mic" : "mic.slash", id: "demoDirectCallMic", compact: compact,
                                            active: microphone, displayLabel: microphone ? "Микрофон" : "Без звука") { microphone.toggle() }
                            .accessibilityValue(tr(microphone ? "Включён" : "Выключен"))
                        PersonalCallControl("Камера", icon: camera ? "video" : "video.slash", id: "demoDirectCallCamera", compact: compact,
                                            active: camera) { camera.toggle() }
                            .accessibilityValue(tr(camera ? "Включена" : "Выключена"))
                        PersonalCallControl(sharing ? "Остановить" : "Показать экран", icon: "display", id: "demoDirectCallShare", compact: compact,
                                            active: sharing, displayLabel: "Экран") {
                            if sharing { sharing = false } else { confirmSharing = true }
                        }
                        PersonalCallControl("Завершить", icon: "phone.down", id: "demoDirectCallEnd", compact: compact,
                                            tint: PersonalCallColors.end) { dismiss() }
                    }
                }
            }
        }.toolbar(.hidden)
            .task {
                guard connectedAt == nil else { return }
                do { try await Task.sleep(for: .seconds(4.5)) } catch { return }
                connectedAt = .now
            }
            .alert(tr("Демонстрация экрана"), isPresented: $confirmSharing) {
                Button(tr("Начать демонстрацию")) { sharing = true }
                Button(tr("Отмена"), role: .cancel) {}
            } message: { Text(tr("Просмотр экрана звонка. Камера, микрофон и соединение не включены.")) }
    }
}
