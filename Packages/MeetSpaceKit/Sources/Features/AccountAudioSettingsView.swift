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
                Text(tr("Аудио")).font(MSTheme.font(21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(tr("Подготовьте звук к следующей встрече.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
            }.padding(.bottom, 6)
            microphone
            output(kind: .speaker, title: "Динамик", volume: "Громкость динамика")
            output(kind: .signals, title: "Звонки и уведомления", volume: "Громкость сигналов")
            if let notice = audio.notice { Text(tr(notice)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger).accessibilityIdentifier("audioNotice") }
            Text(tr("Настройки применяются автоматически.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }.tint(MSTheme.accent).accessibilityIdentifier("accountAudioPanel")
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
                .accessibilityLabel(tr("Микрофон")).accessibilityIdentifier("audioMicrophoneDevice")
            } test: { checkButton(.microphone) }
            Text(tr(audio.check == .microphone ? "Говорите — индикатор показывает уровень микрофона." : "Проверьте микрофон, чтобы увидеть уровень звука и названия устройств."))
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).padding(.top, 10)
            volumeTitle("Громкость микрофона", value: audio.inputGain).padding(.top, 20)
            Slider(value: Binding(get: { Double(audio.inputGain) }, set: { audio.setGain(Float($0)) }), in: 0...1)
                .disabled(!audio.canSetInputGain).frame(minHeight: 44)
                .accessibilityLabel(tr("Громкость микрофона")).accessibilityIdentifier("audioMicrophoneVolume")
            if !audio.canSetInputGain {
                Text(tr("Громкость этого микрофона регулируется автоматически системой."))
                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            Toggle(tr("Подключаться с выключенным микрофоном"), isOn: Binding(get: { audio.preferences.mutedOnJoin }, set: { value in audio.update { $0.mutedOnJoin = value } }))
                .font(MSTheme.font(13)).frame(minHeight: 58).accessibilityIdentifier("audioMutedOnJoin")
            Divider()
            Toggle(tr("Шумоподавление"), isOn: Binding(get: { audio.preferences.noiseSuppression }, set: { value in audio.update { $0.noiseSuppression = value } }))
                .font(MSTheme.font(13)).frame(minHeight: 58).accessibilityIdentifier("audioNoiseSuppression")
            Divider().padding(.top, 9)
        }
    }
    private func output(kind: AudioSettingsModel.Check, title: String, volume: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(title, check: kind)
            if kind == .signals {
                Text(tr("Громкость сигнала вызова и уведомлений о сообщениях, приглашениях и скором начале встречи."))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).padding(.bottom, 12)
            }
            selectRow {
                #if os(iOS)
                HStack(spacing: 8) {
                    Text(audio.outputName).font(MSTheme.font(14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel(tr("Выбрать другое устройство"))
                }.padding(.leading, 13).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(MSTheme.line, lineWidth: 1))
                #else
                selectorLabel(tr("По умолчанию"))
                #endif
            } test: { checkButton(kind) }
            volumeTitle(volume, value: audio.outputVolume).padding(.top, 20)
            #if os(iOS)
            SystemAudioVolume().frame(height: 44).accessibilityIdentifier("audioVolume.\(kind.rawValue)")
            #else
            Slider(value: .constant(Double(audio.outputVolume))).disabled(true).frame(minHeight: 44)
            #endif
            if kind == .signals {
                Text(tr("Громкость проверки — системная. Громкость звонков и уведомлений задаётся в настройках iOS."))
                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            #if os(iOS)
            HStack {
                Text(tr("Выбрать другое устройство")).font(MSTheme.font(13)).foregroundStyle(MSTheme.accent)
                AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel(tr("Выбрать другое устройство"))
            }.accessibilityElement(children: .contain)
            #endif
            Divider().padding(.top, 22)
        }
    }
    private func heading(_ title: String, check: AudioSettingsModel.Check) -> some View {
        HStack(spacing: 16) {
            Text(tr(title)).font(MSTheme.font(15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach(0..<8) { bar in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(audio.check == check && Float(bar) < audio.level * 8 ? MSTheme.success : MSTheme.background)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(MSTheme.line, lineWidth: 1))
                        .frame(width: 5, height: 15)
                }
            }.accessibilityLabel(tr(check == .microphone ? "Уровень микрофона" : "Тестовый звук"))
                .accessibilityValue("\(Int(audio.check == check ? audio.level * 100 : 0))%")
        }.padding(.bottom, 16)
    }
    @ViewBuilder private func selectRow<Selection: View, Test: View>(@ViewBuilder selection: () -> Selection, @ViewBuilder test: () -> Test) -> some View {
        if wide && !typeSize.isAccessibilitySize { HStack(spacing: 10) { selection(); test().fixedSize(horizontal: true, vertical: false) } }
        else { VStack(spacing: 10) { selection(); test() } }
    }
    private func selectorLabel(_ text: String) -> some View {
        HStack { Text(text).lineLimit(2); Spacer(minLength: 8); Image(systemName: "chevron.down").font(.system(size: 11)) }
            .font(MSTheme.font(14)).foregroundStyle(MSTheme.ink).padding(.horizontal, 13).frame(minHeight: 46)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(MSTheme.line, lineWidth: 1))
    }
    private func checkButton(_ kind: AudioSettingsModel.Check) -> some View {
        Button { Task { await audio.test(kind) } } label: {
            Label(tr(audio.check == kind ? "Остановить" : "Проверить"), systemImage: audio.check == kind ? "stop" : kind == .microphone ? "mic" : "play")
                .font(MSTheme.font(13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 46).padding(.horizontal, 14)
                .background(audio.check == kind ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(audio.check == kind ? MSTheme.accent : MSTheme.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("audioTest.\(kind.rawValue)")
    }
    private func volumeTitle(_ text: String, value: Float) -> some View {
        HStack {
            Text(tr(text)).font(MSTheme.font(13)); Spacer(minLength: 12)
            Text("\(Int(value * 100))%").font(MSTheme.font(11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(MSTheme.accent).padding(.horizontal, 8).padding(.vertical, 5)
                .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
        }
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
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = UIColor(MSTheme.accent)
        view.activeTintColor = UIColor(MSTheme.accent); view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
