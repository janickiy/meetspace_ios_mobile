import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceMedia
#if os(iOS)
@preconcurrency import AVFoundation
#endif

@MainActor @Observable final class AudioSettingsModel {
    enum Check: String { case microphone, speaker, signals }
    struct Input: Identifiable { let id: String; let name: String }
    private(set) var preferences: DeviceAudioPreferences
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var check: Check?
    private(set) var level: Float = 0
    private(set) var inputs: [Input] = []
    private(set) var outputName = "По умолчанию"
    private(set) var notice: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let audioOwner = UUID()
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var previousSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    #endif

    /// Загружает сохранённые настройки звука для экрана аккаунта.
    /// - Parameter defaults: Хранилище настроек аудиоустройства.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DeviceAudioPreferences.load(defaults: defaults)
    }

    /// Обновляет список доступных входов и название активного аудиовыхода.
    func refresh() {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        inputs = (audio.availableInputs ?? []).map { Input(id: $0.uid, name: $0.portName) }
        outputName = audio.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        if outputName.isEmpty { outputName = "По умолчанию" }
        #endif
    }
    /// Загружает настройки при открытии экрана и запускает отслеживание уровня проверочного сигнала.
    func appear() {
        preferences = DeviceAudioPreferences.load(defaults: defaults)
        refresh()
        #if os(iOS)
        sampling?.cancel()
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                if let player = self.player {
                    player.updateMeters()
                    self.level = player.volume == 0 ? 0 : Self.normalizedLevel(player.averagePower(forChannel: 0))
                }
            }
        }
        #endif
    }
    /// Останавливает измерение уровня и проверку звука при закрытии экрана.
    func disappear() { sampling?.cancel(); sampling = nil; stop() }
    /// Применяет изменение к актуальным настройкам звука, проверяет их и сохраняет.
    /// - Parameter change: Замыкание, изменяющее настройки устройства.
    func update(_ change: (inout DeviceAudioPreferences) -> Void) {
        stop()
        preferences = DeviceAudioPreferences.load(defaults: defaults)
        change(&preferences)
        preferences = preferences.validated()
        preferences.save(defaults: defaults)
    }
    /// Возвращает сохранённый уровень микрофона, динамика или звуковых сигналов.
    /// - Parameter kind: Аудиоканал, уровень которого нужно прочитать.
    func volume(for kind: Check) -> Float {
        switch kind {
        case .microphone: preferences.inputGain
        case .speaker: preferences.speakerVolume
        case .signals: preferences.signalVolume
        }
    }

    /// Сохраняет уровень выбранного канала и применяет его к активной проверке.
    /// - Parameters:
    ///   - value: Новый уровень канала в диапазоне 0…1.
    ///   - kind: Аудиоканал для изменения.
    func setVolume(_ value: Float, for kind: Check) {
        var next = DeviceAudioPreferences.load(defaults: defaults)
        switch kind {
        case .microphone: next.inputGain = value
        case .speaker: next.speakerVolume = value
        case .signals: next.signalVolume = value
        }
        preferences = next.validated()
        preferences.save(defaults: defaults)
        NotificationCenter.default.post(name: DeviceAudioPreferences.levelsDidChange, object: nil)
        #if os(iOS)
        guard check == kind else { return }
        if kind == .microphone {
            let session = AVAudioSession.sharedInstance()
            if session.isInputGainSettable {
                do { try session.setInputGain(preferences.inputGain) }
                catch { notice = "Не удалось изменить громкость микрофона." }
            }
        } else {
            player?.volume = volume(for: kind)
        }
        #endif
    }
    /// Запускает проверку выбранного аудиоканала либо останавливает уже идущую проверку этого канала.
    /// - Parameters:
    ///   - kind: Микрофон, динамик или звуковые сигналы.
    ///   - respectingSilentMode: Учитывать ли беззвучный режим при воспроизведении.
    func test(_ kind: Check, respectingSilentMode: Bool = false) async {
        if check == kind { stop(); return }
        stop(); notice = nil
        preferences = DeviceAudioPreferences.load(defaults: defaults)
        let current = generation
        guard AudioSessionUse.beginProbe(owner: audioOwner, stop: { [weak self] in self?.stop() }) else {
            notice = "Завершите звонок, чтобы проверить звук."; return
        }
        #if os(iOS)
        do {
            if kind == .microphone {
                let permitted = await AVAudioApplication.requestRecordPermission()
                guard current == generation, !Task.isCancelled else { return }
                guard permitted else { stop(); notice = "Разрешите доступ к микрофону в настройках устройства."; return }
                try prepare(recording: true)
                let session = AVAudioSession.sharedInstance()
                if let uid = preferences.preferredInputUID {
                    guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else {
                        stop(); notice = "Выбранный микрофон не подключён."; return
                    }
                    try session.setPreferredInput(input)
                } else { try session.setPreferredInput(nil) }
                let engine = AVAudioEngine()
                self.engine = engine
                try engine.inputNode.setVoiceProcessingEnabled(preferences.noiseSuppression)
                let hardwareGain = session.isInputGainSettable
                if hardwareGain { try session.setInputGain(preferences.inputGain) }
                let format = engine.inputNode.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else { throw ConferenceMediaError.capture }
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                    var sum: Float = 0
                    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                    let rms = sqrt(sum / Float(buffer.frameLength))
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current else { return }
                        self.level = Self.microphoneProbeLevel(rms: rms, inputGain: self.preferences.inputGain,
                                                               hardwareGain: hardwareGain)
                    }
                }
                tapInstalled = true
                engine.prepare(); try engine.start()
            } else {
                try prepare(recording: false, respectingSilentMode: respectingSilentMode)
                let player = try AVAudioPlayer(data: Self.testTone(signals: kind == .signals))
                player.volume = volume(for: kind)
                player.isMeteringEnabled = true
                self.player = player
                guard player.play() else { throw ConferenceMediaError.audioSession }
            }
            check = kind; refresh()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(kind == .microphone ? 15 : 2))
                guard !Task.isCancelled, let self, self.generation == current else { return }; self.stop()
            }
        } catch { stop(); notice = "Не удалось запустить проверку звука. Проверьте подключение устройства." }
        #else
        stop(); notice = "Проверка звука доступна на iPhone и iPad."
        #endif
    }
    /// Завершает проверку звука, обнуляет индикатор и освобождает аудиосессию.
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        #if os(iOS)
        if let engine {
            engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0) }; self.engine = nil
        }
        tapInstalled = false
        player?.stop(); player = nil
        if let prior = previousSession {
            previousSession = nil
            // A late CallKit activation already owns the session. Stop our engine/player,
            // but do not deactivate it or restore a category over the system call.
            if !AudioSessionUse.systemAudioActive {
                let audio = AVAudioSession.sharedInstance()
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                try? audio.setCategory(prior.0, mode: prior.1, options: prior.2)
            }
        }
        #endif
        check = nil; level = 0; AudioSessionUse.endProbe(owner: audioOwner)
    }
    /// Переводит мощность в децибелах в линейный уровень индикатора от 0 до 1.
    /// - Parameter decibels: Средняя мощность канала в децибелах.
    static func normalizedLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, pow(10, decibels / 20)))
    }
    /// Вычисляет показание индикатора микрофона с учётом усиления.
    /// - Parameters:
    ///   - rms: Среднеквадратичная амплитуда входного сигнала.
    ///   - inputGain: Выбранный коэффициент усиления.
    ///   - hardwareGain: Применено ли усиление аппаратно.
    static func microphoneProbeLevel(rms: Float, inputGain: Float, hardwareGain: Bool) -> Float {
        guard rms.isFinite, inputGain > 0 else { return 0 }
        let adjusted = hardwareGain ? rms : rms * inputGain
        return min(1, max(0, adjusted * 5))
    }
    #if os(iOS)
    /// Активирует аудиосессию для записи с микрофона или воспроизведения проверочного сигнала.
    /// - Parameters:
    ///   - recording: Нужна ли запись с микрофона.
    ///   - respectingSilentMode: Учитывать ли беззвучный режим при воспроизведении.
    private func prepare(recording: Bool, respectingSilentMode: Bool = false) throws {
        let audio = AVAudioSession.sharedInstance()
        if previousSession == nil { previousSession = (audio.category, audio.mode, audio.categoryOptions) }
        let category: AVAudioSession.Category = recording ? .playAndRecord : (respectingSilentMode ? .ambient : .playback)
        try audio.setCategory(category,
                              mode: recording ? .voiceChat : .default,
                              options: recording ? [.allowBluetooth, .defaultToSpeaker] : [])
        try audio.setActive(true)
    }
    #endif
    /// Генерирует секундный проверочный тон в формате WAV с частотой дискретизации 24 кГц.
    ///
    /// Short in-memory PCM; microphone samples are never saved or transmitted.
    /// - Parameter signals: Переключать ли тон с 440 на 660 Гц для проверки звука уведомлений.
    static func testTone(signals: Bool) -> Data {
        let sampleRate = 24000, count = sampleRate
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let envelope = min(1, t * 30) * min(1, (1 - t) * 30)
            let frequency = signals && t > 0.4 ? 660.0 : 440.0
            var sample = Int16(sin(2 * Double.pi * frequency * t) * 6000 * envelope).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var result = Data("RIFF".utf8)
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        append32(UInt32(36 + pcm.count)); result.append(Data("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        result.append(Data("data".utf8)); append32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
