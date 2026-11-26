import Foundation
import ReplayKit
import CoreMedia
import ImageIO
import MeetSpaceBroadcast

/// ReplayKit supplies serialized video callbacks. The lock also fences memory pressure/control callbacks.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let state = NSLock()
    private var connection: BroadcastUploadConnection?
    private var converter: ScreenFrameConverter?
    private var configuration = ScreenBroadcastConfiguration()
    private var active = false
    private var paused = false
    private var finished = false
    private var lastTimestamp: Int64 = -1
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Подключает расширение ReplayKit к приложению и готовит преобразователь кадров с согласованными ограничениями.
    /// - Parameter setupInfo: Дополнительные сведения о запуске, переданные ReplayKit.
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let group = Bundle.main.object(forInfoDictionaryKey: BroadcastInstallation.groupInfoKey) as? String else {
            end(.unavailable); return
        }
        let channel = BroadcastUploadConnection(appGroupIdentifier: group)
        do {
            let limits = try channel.start { [weak self] reason in self?.end(reason) }
            let installed = state.withLock { () -> Bool in
                guard !finished else { return false }
                connection = channel; configuration = limits
                converter = ScreenFrameConverter(maxWidth: limits.maxWidth, maxHeight: limits.maxHeight)
                active = true; return true
            }
            guard installed else { channel.finish(reason: .user); return }
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .userInitiated))
            pressure.setEventHandler { [weak self] in self?.end(.memoryPressure) }
            state.withLock { if !finished { memoryPressure = pressure } }
            pressure.resume()
            if state.withLock({ finished }) { pressure.cancel() }
        } catch { channel.finish(reason: .hostUnavailable); end(.hostUnavailable) }
    }
    /// Передаёт видеокадры ReplayKit приложению с учётом ориентации и предельной частоты кадров.
    /// - Parameters:
    ///   - sampleBuffer: Буфер с изображением, временной меткой и метаданными ориентации.
    ///   - sampleBufferType: Тип данных ReplayKit. Для передачи выбирается видео.
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // System and microphone audio are intentionally not transported by this extension.
        guard sampleBufferType == .video else { return }
        do {
            let work: (BroadcastUploadConnection, ScreenBroadcastFrame)? = try autoreleasepool {
                try state.withLock {
                    guard active, !paused, !finished, let connection, let sessionID = connection.sessionID,
                          let converter, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
                    let timestamp = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), timescale: 1_000_000_000, method: .default)
                    guard timestamp.isValid, timestamp.isNumeric, timestamp.value >= 0 else { throw ScreenFrameConversionError.invalidBuffer }
                    let interval = Int64(1_000_000_000 / configuration.maxFrameRate)
                    guard lastTimestamp < 0 || timestamp.value - lastTimestamp >= interval else { return nil }
                    let raw = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
                    guard let orientation = CGImagePropertyOrientation(rawValue: raw) else { throw ScreenFrameConversionError.invalidBuffer }
                    let frame = try converter.convert(buffer, orientation: orientation, sessionID: sessionID, timestampNs: timestamp.value)
                    lastTimestamp = timestamp.value
                    return (connection, frame)
                }
            }
            // Never hold the handler lock across IPC: a failed send can synchronously deliver onStop.
            if let work { _ = try work.0.send(frame: work.1) }
        } catch { end(.invalidFrame) }
    }
    /// Приостанавливает отправку кадров, освобождает буферы и сообщает приложению о паузе.
    override func broadcastPaused() {
        let current = state.withLock { () -> BroadcastUploadConnection? in
            paused = true; converter?.releaseBuffers(); return connection
        }
        current?.pause()
    }
    /// Разрешает обработку новых кадров после паузы и сообщает приложению о возобновлении.
    override func broadcastResumed() {
        let current = state.withLock { () -> BroadcastUploadConnection? in
            guard !finished else { return nil }; paused = false; return connection
        }
        current?.resume()
    }
    /// Освобождает ресурсы расширения при штатном завершении демонстрации.
    override func broadcastFinished() { cleanup(.user) }

    /// Однократно останавливает канал и мониторинг памяти, освобождает буферы и возвращает признак первой остановки.
    /// - Parameter reason: Причина остановки, передаваемая приложению.
    @discardableResult private func cleanup(_ reason: ScreenBroadcastStopReason) -> Bool {
        let result = state.withLock { () -> (Bool, BroadcastUploadConnection?) in
            guard !finished else { return (false, nil) }
            finished = true; active = false; memoryPressure?.cancel(); memoryPressure = nil
            converter?.releaseBuffers(); converter = nil
            let current = connection; connection = nil; return (true, current)
        }
        result.1?.finish(reason: reason)
        return result.0
    }
    /// Завершает демонстрацию с сообщением ReplayKit после освобождения ресурсов.
    /// - Parameter reason: Причина остановки, определяющая текст системного сообщения.
    private func end(_ reason: ScreenBroadcastStopReason) {
        guard cleanup(reason) else { return }
        let message = reason == .memoryPressure ? "Недостаточно памяти для демонстрации экрана." : "Демонстрация экрана завершена. Вернитесь в MeetSpace для нового запуска."
        finishBroadcastWithError(NSError(domain: "MeetSpaceBroadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
