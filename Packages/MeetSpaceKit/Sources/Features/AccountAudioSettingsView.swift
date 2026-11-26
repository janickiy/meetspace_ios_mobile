import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if os(iOS)
import AVKit
#endif

/// The mockup's three audio blocks, with live iOS routes and device-local MeetSpace levels.
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
            volume("Громкость микрофона", kind: .microphone, identifier: "audioMicrophoneVolume")
            hint("При проверке можно выбрать любой уровень. Во время встречи усилением встроенного микрофона может управлять iOS. При 0% микрофон выключен.")
                .padding(.bottom, 3)
            preference("Подключаться с выключенным микрофоном", identifier: "audio.mutedOnJoin", key: \.mutedOnJoin)
            rule
            preference("Шумоподавление", identifier: "audio.noiseSuppression", key: \.noiseSuppression)
            rule.padding(.top, 22)
        }
    }
    /// Собирает выбор устройства, проверку звука и регулятор громкости в одну секцию.
    /// - Parameters:
    ///   - kind: Динамик или звуковые сигналы.
    ///   - title: Заголовок секции.
    ///   - volumeLabel: Подпись регулятора.
    private func output(kind: AudioSettingsModel.Check, title: String, volumeLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(title, check: kind)
            if kind == .signals {
                hint("Громкость проверочного сигнала и звука новых сообщений внутри MeetSpace.")
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
            volume(volumeLabel, kind: kind, identifier: "audioVolume.\(kind.rawValue)")
            if kind == .signals {
                hint("Громкость системных звонков и push-уведомлений задаётся в настройках iOS.")
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
    /// Показывает заголовок секции с индикатором уровня для выбранной проверки.
    /// - Parameters:
    ///   - title: Заголовок секции.
    ///   - check: Источник, уровень которого отображает индикатор.
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
    /// Размещает выбор устройства и кнопку проверки в строку или столбец по доступной ширине.
    /// - Parameters:
    ///   - selection: Представление выбора устройства.
    ///   - test: Кнопка проверки выбранного устройства.
    @ViewBuilder private func selectRow<Selection: View, Test: View>(@ViewBuilder selection: () -> Selection, @ViewBuilder test: () -> Test) -> some View {
        if wide && !typeSize.isAccessibilitySize { HStack(spacing: 10) { selection(); test().fixedSize(horizontal: true, vertical: false) } }
        else { VStack(spacing: 10) { selection(); test() } }
    }
    /// Оформляет название устройства со стрелкой раскрытия списка.
    /// - Parameter text: Название текущего устройства.
    private func selectorLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(MSTheme.font(14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            WorkspaceIcon("chevron.down", size: 12)
        }.padding(.leading, 17).padding(.trailing, 7).padding(.vertical, 8).frame(minHeight: 46)
            .modifier(AudioSelectorChrome()).contentShape(Rectangle())
    }
    /// Показывает кнопку запуска и остановки проверки звука.
    /// - Parameter kind: Канал, который должна проверять кнопка.
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

    /// Связывает ползунок и подпись в процентах с уровнем выбранного канала.
    /// - Parameters:
    ///   - title: Подпись ползунка.
    ///   - kind: Канал, громкость которого регулируется.
    ///   - identifier: Идентификатор элемента для тестов интерфейса и средств доступности.
    private func volume(_ title: String, kind: AudioSettingsModel.Check, identifier: String) -> some View {
        let value = audio.volume(for: kind)
        let binding = Binding(get: { Double(audio.volume(for: kind)) },
                              set: { audio.setVolume(Float($0), for: kind) })
        return VStack(spacing: 2) {
            HStack(spacing: 12) {
                Text(tr(title)).font(MSTheme.font(12.6)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(Int((value * 100).rounded()))%").font(MSTheme.font(10.7, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(minWidth: 48, minHeight: 26)
                    .foregroundStyle(MSTheme.accent)
                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
            }
            AccountAudioRange(value: binding, title: title, identifier: identifier)
        }.padding(.top, 20)
    }

    /// Выводит пояснение под настройкой звука.
    /// - Parameter text: Текст пояснения.
    private func hint(_ text: String) -> some View {
        Text(tr(text)).font(MSTheme.font(11.5)).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true).foregroundStyle(MSTheme.muted)
    }

    private var rule: some View { Rectangle().fill(MSTheme.line).frame(height: 1).accessibilityHidden(true) }

    /// Связывает переключатель с логической настройкой аудиоустройства.
    /// - Parameters:
    ///   - title: Подпись переключателя.
    ///   - identifier: Идентификатор элемента для тестов интерфейса и средств доступности.
    ///   - key: Путь к изменяемому свойству настроек.
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
    /// Добавляет полю выбора устройства фон и скруглённую рамку.
    /// - Parameter content: Оформляемое поле.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11)
        content.background(MSTheme.surface, in: shape)
            .overlay(shape.strokeBorder(MSTheme.muted.opacity(0.65)).allowsHitTesting(false))
    }
}

private struct AccountAudioRange: View {
    @Binding var value: Double
    let title: String
    let identifier: String
    @Environment(\.layoutDirection) private var direction
    private let thumbSize: CGFloat = 16

    var body: some View {
        GeometryReader { bounds in
            let width = bounds.size.width
            let travel = max(0, width - thumbSize)
            let position = CGFloat(value) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(MSTheme.surfaceSecondary)
                    .overlay(Capsule().strokeBorder(MSTheme.muted.opacity(0.5)))
                    .frame(height: 8)
                Capsule().fill(MSTheme.brandAccent)
                    .frame(width: position + thumbSize / 2, height: 8)
                Circle().fill(MSTheme.brandAccent).frame(width: thumbSize, height: thumbSize)
                    .offset(x: direction == .rightToLeft ? -position : position)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    select(drag.location.x, width: width)
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in select(tap.location.x, width: width) })
        }
        .frame(height: 44)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1, step: 0.01)
                .accessibilityLabel(tr(title))
                .accessibilityValue("\(Int((value * 100).rounded()))%")
                .accessibilityIdentifier(identifier)
        }
    }

    /// Пересчитывает громкость по точке касания с учётом направления интерфейса.
    /// - Parameters:
    ///   - x: Горизонтальная координата касания в пунктах.
    ///   - width: Ширина ползунка в пунктах.
    private func select(_ x: CGFloat, width: CGFloat) {
        guard width > thumbSize else { return }
        let distance = direction == .rightToLeft ? width - x : x
        let fraction = min(1, max(0, (distance - thumbSize / 2) / (width - thumbSize)))
        let percent = (Double(fraction) * 100).rounded()
        if percent != (value * 100).rounded() { value = percent / 100 }
    }
}

#if os(iOS)
private struct AudioRoutePicker: UIViewRepresentable {
    var selector = false
    /// Создаёт системную кнопку выбора маршрута воспроизведения.
    /// - Parameter context: Контекст представления, переданный SwiftUI.
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = selector ? .clear : UIColor(MSTheme.accent)
        view.activeTintColor = view.tintColor
        view.prioritizesVideoDevices = false
        return view
    }
    /// Сохраняет системный выбор маршрута при обновлении SwiftUI.
    /// - Parameters:
    ///   - uiView: Ранее созданная кнопка выбора маршрута.
    ///   - context: Контекст представления, переданный SwiftUI.
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
