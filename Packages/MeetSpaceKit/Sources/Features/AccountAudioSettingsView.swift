import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if os(iOS)
import AVKit
import MediaPlayer
#endif

/// The mockup's three audio blocks, with live iOS routes and public system volume controls.
struct AccountAudioSettingsView: View {
    @State private var audio = AudioSettingsModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let wide: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Аудио")).font(MSTheme.font(wide ? 23 : 21, weight: .semibold, relativeTo: .title2))
                    .tracking(-0.5).accessibilityAddTraits(.isHeader)
                Text(tr("Подготовьте звук к следующей встрече.")).font(MSTheme.font(13.2))
                    .lineSpacing(4).foregroundStyle(MSTheme.muted)
            }.padding(.bottom, wide ? 8 : 6)
            microphone
            output(kind: .speaker, title: "Динамик", volumeLabel: "Громкость динамика")
            output(kind: .signals, title: "Звонки и уведомления", volumeLabel: "Громкость сигналов")
            if let notice = audio.notice {
                Text(tr(notice)).font(MSTheme.font(11.5)).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(MSTheme.danger).accessibilityIdentifier("audioNotice")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(MSTheme.ink).tint(MSTheme.accent)
            .onAppear { audio.appear() }.onDisappear { audio.disappear() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.stop() } }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in audio.stop() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { event in
                let raw = event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue { audio.stop() }
                audio.refresh()
            }
            #endif
    }
    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Микрофон", check: .microphone)
            selectRow {
                Menu {
                    Button(tr("По умолчанию")) { audio.update { $0.preferredInputUID = nil } }
                    ForEach(audio.inputs) { input in Button(input.name) { audio.update { $0.preferredInputUID = input.id } } }
                } label: { selectorLabel(audio.inputs.first { $0.id == audio.preferences.preferredInputUID }?.name ?? tr(audio.preferences.preferredInputUID == nil ? "По умолчанию" : "Выбранный микрофон")) }
                .buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel(tr("Микрофон")).accessibilityIdentifier("audioMicrophoneDevice")
            } test: { checkButton(.microphone) }
            hint(audio.check == .microphone ? "Говорите — индикатор показывает уровень микрофона." :
                    "Проверьте микрофон, чтобы увидеть уровень звука и названия устройств.").padding(.top, 10)
            volume("Громкость микрофона", value: audio.inputGain) {
                AccountAudioRange(value: Binding(get: { Double(audio.inputGain) }, set: { audio.setGain(Float($0)) }),
                                  adjustable: audio.canSetInputGain, label: "Громкость микрофона",
                                  identifier: "audioMicrophoneVolume")
            }
            if !audio.canSetInputGain {
                hint("Громкость этого микрофона регулируется автоматически системой.").padding(.bottom, 3)
            }
            preference("Подключаться с выключенным микрофоном", identifier: "audio.mutedOnJoin", key: \.mutedOnJoin)
            rule
            preference("Шумоподавление", identifier: "audio.noiseSuppression", key: \.noiseSuppression)
            rule.padding(.top, 22)
        }
    }
    private func output(kind: AudioSettingsModel.Check, title: String, volumeLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(title, check: kind)
            if kind == .signals {
                hint("Громкость сигнала вызова и уведомлений о сообщениях, приглашениях и скором начале встречи.")
                    .padding(.bottom, 12)
            }
            selectRow {
                #if os(iOS)
                HStack(spacing: 8) {
                    Text(tr(audio.outputName)).font(MSTheme.font(14))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AudioRoutePicker(selector: true).frame(width: 44, height: 44)
                        .overlay(alignment: .trailing) {
                            WorkspaceIcon("chevron.down", size: 12).padding(.trailing, 7).allowsHitTesting(false)
                        }.accessibilityLabel(tr("Выбрать другое устройство"))
                }.padding(.leading, 17).frame(minHeight: 46).modifier(AudioSelectorChrome())
                #else
                selectorLabel(tr("По умолчанию"))
                #endif
            } test: { checkButton(kind) }
            volume(volumeLabel, value: audio.outputVolume) {
                #if os(iOS) && !targetEnvironment(simulator)
                SystemAudioVolume().frame(height: 44)
                    .accessibilityLabel(tr(volumeLabel)).accessibilityIdentifier("audioVolume.\(kind.rawValue)")
                #else
                AccountAudioRange(value: .constant(Double(audio.outputVolume)), adjustable: false,
                                  label: volumeLabel, identifier: "audioVolume.\(kind.rawValue)")
                #endif
            }
            #if targetEnvironment(simulator)
            hint("Громкость регулируется на iPhone или iPad.")
            #endif
            if kind == .signals {
                hint("Громкость проверки — системная. Громкость звонков и уведомлений задаётся в настройках iOS.")
            }
            #if os(iOS)
            HStack(spacing: 8) {
                Text(tr("Выбрать другое устройство")).font(MSTheme.font(12.6)).foregroundStyle(MSTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel(tr("Выбрать другое устройство"))
            }.accessibilityElement(children: .contain)
            #endif
            rule.padding(.top, 22)
        }
    }
    private func heading(_ title: String, check: AudioSettingsModel.Check) -> some View {
        HStack(spacing: 16) {
            Text(tr(title)).font(MSTheme.font(15.1, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(0..<8) { bar in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(audio.check == check && Float(bar) < audio.level * 8 ? MSTheme.success : MSTheme.background)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(MSTheme.line, lineWidth: 1))
                        .frame(width: 5, height: 15)
                }
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(tr(check == .microphone ? "Уровень микрофона" : "Тестовый звук"))
                .accessibilityValue("\(Int(audio.check == check ? audio.level * 100 : 0))%")
        }.frame(minHeight: 22.7).padding(.bottom, 16)
    }
    @ViewBuilder private func selectRow<Selection: View, Test: View>(@ViewBuilder selection: () -> Selection, @ViewBuilder test: () -> Test) -> some View {
        if wide && !typeSize.isAccessibilitySize { HStack(spacing: 10) { selection(); test().fixedSize(horizontal: true, vertical: false) } }
        else { VStack(spacing: 10) { selection(); test() } }
    }
    private func selectorLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(MSTheme.font(14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            WorkspaceIcon("chevron.down", size: 12)
        }.padding(.leading, 17).padding(.trailing, 7).padding(.vertical, 8).frame(minHeight: 46)
            .modifier(AudioSelectorChrome()).contentShape(Rectangle())
    }
    private func checkButton(_ kind: AudioSettingsModel.Check) -> some View {
        let running = audio.check == kind
        return Button { Task { await audio.test(kind) } } label: {
            HStack(spacing: 7) {
                WorkspaceIcon(running ? "stop" : kind == .microphone ? "mic" : "play", size: 17)
                Text(tr(running ? "Остановить" : "Проверить"))
                    .font(MSTheme.font(12.6, weight: .semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(running ? MSTheme.accent : MSTheme.ink)
                .background(running ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(running ? MSTheme.accent : MSTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(running ? .isSelected : [])
            .accessibilityIdentifier("audioTest.\(kind.rawValue)")
    }

    private func volume<Track: View>(_ title: String, value: Float, @ViewBuilder track: () -> Track) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Text(tr(title)).font(MSTheme.font(12.6)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(Int((value * 100).rounded()))%").font(MSTheme.font(10.7, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(minWidth: 48, minHeight: 26)
                    .foregroundStyle(MSTheme.accent)
                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
            }
            track()
        }.padding(.top, 20)
    }

    private func hint(_ text: String) -> some View {
        Text(tr(text)).font(MSTheme.font(11.5)).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true).foregroundStyle(MSTheme.muted)
    }

    private var rule: some View { Rectangle().fill(MSTheme.line).frame(height: 1).accessibilityHidden(true) }

    private func preference(_ title: String, identifier: String, key: WritableKeyPath<DeviceAudioPreferences, Bool>) -> some View {
        let enabled = Binding(get: { audio.preferences[keyPath: key] },
                              set: { value in audio.update { $0[keyPath: key] = value } })
        return Toggle(isOn: enabled) {
            Text(tr(title)).font(MSTheme.font(13.4)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(AccountSwitchStyle()).accessibilityIdentifier(identifier)
            .padding(.vertical, 7).frame(minHeight: 58)
    }
}

private struct AudioSelectorChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11)
        content.background(MSTheme.surface, in: shape)
            .overlay(shape.strokeBorder(MSTheme.muted.opacity(0.65)).allowsHitTesting(false))
    }
}

private struct AccountAudioRange: View {
    @Binding var value: Double
    let adjustable: Bool
    let label: String
    let identifier: String
    @Environment(\.layoutDirection) private var direction
    private let thumbSize: CGFloat = 15

    var body: some View {
        GeometryReader { bounds in
            let travel = max(0, bounds.size.width - thumbSize)
            let offset = travel * CGFloat(value)
            let tint = MSTheme.brandAccent.opacity(adjustable ? 1 : 0.55)
            ZStack(alignment: .leading) {
                Capsule().fill(MSTheme.surfaceSecondary)
                    .overlay(Capsule().strokeBorder(MSTheme.muted.opacity(0.5)))
                    .frame(height: 8).padding(.horizontal, 1)
                if value > 0 {
                    Capsule().fill(tint).frame(width: offset + thumbSize / 2, height: 8)
                        .padding(.leading, 1)
                }
                Circle().fill(tint).frame(width: thumbSize, height: thumbSize)
                    .offset(x: direction == .rightToLeft ? -offset : offset)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { event in setPosition(event.location.x, width: bounds.size.width) },
                         including: adjustable ? .all : .none)
                .simultaneousGesture(SpatialTapGesture()
                    .onEnded { event in setPosition(event.location.x, width: bounds.size.width) },
                                     including: adjustable ? .all : .none)
        }.frame(height: 44)
            .accessibilityRepresentation {
                Slider(value: $value, in: 0...1, step: 0.01)
                    .accessibilityLabel(tr(label)).accessibilityValue("\(Int((value * 100).rounded()))%")
                    .disabled(!adjustable).accessibilityIdentifier(identifier)
            }
    }

    private func setPosition(_ position: CGFloat, width: CGFloat) {
        guard adjustable, width > thumbSize else { return }
        let distance = direction == .rightToLeft ? width - position : position
        let next = min(1, max(0, (distance - thumbSize / 2) / (width - thumbSize)))
        value = Double((next * 100).rounded() / 100)
    }
}
#if os(iOS)
private struct SystemAudioVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(); view.showsRouteButton = false
        view.tintColor = UIColor(MSTheme.accent); return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
private struct AudioRoutePicker: UIViewRepresentable {
    var selector = false
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = selector ? .clear : UIColor(MSTheme.accent)
        view.activeTintColor = view.tintColor
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
