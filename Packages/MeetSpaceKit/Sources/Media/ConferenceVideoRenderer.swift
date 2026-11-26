#if os(iOS)
import SwiftUI
import UIKit
@preconcurrency import WebRTC

@MainActor final class ConferenceRendererRegistry {
    private struct Attachment {
        let track: RTCVideoTrack
        weak var view: RTCMTLVideoView?
    }
    private var attachments: [UUID: Attachment] = [:]
    /// Подключает видеодорожку к представлению и заменяет предыдущее подключение с тем же идентификатором.
    /// - Parameters:
    ///   - track: Дорожка WebRTC, поставляющая кадры.
    ///   - view: Представление Metal для вывода кадров.
    ///   - id: Идентификатор подключения этого представления.
    func attach(_ track: RTCVideoTrack, view: RTCMTLVideoView, id: UUID) {
        detach(id)
        attachments[id] = Attachment(track: track, view: view)
        track.add(view)
    }
    /// Отсоединяет представление от дорожки и очищает последний показанный кадр.
    /// - Parameter id: Идентификатор подключения представления к дорожке.
    func detach(_ id: UUID) {
        guard let attachment = attachments.removeValue(forKey: id), let view = attachment.view else { return }
        attachment.track.remove(view); view.renderFrame(nil)
    }
    /// Отсоединяет от видеодорожки все зарегистрированные представления.
    /// - Parameter trackID: Идентификатор видеодорожки WebRTC.
    func detach(trackID: String) {
        let ids = attachments.filter { $0.value.track.trackId == trackID }.map(\.key)
        for id in ids { detach(id) }
    }
    /// Отсоединяет все зарегистрированные представления от их видеодорожек.
    func detachAll() { for id in Array(attachments.keys) { detach(id) } }
}

@MainActor struct ConferenceVideoRenderer: UIViewRepresentable {
    let track: RTCVideoTrack?
    let mirrored: Bool
    let fit: Bool
    let registry: ConferenceRendererRegistry
    final class Coordinator {
        let id = UUID()
        let registry: ConferenceRendererRegistry
        var track: RTCVideoTrack?
        /// Сохраняет реестр для подключения и отсоединения дорожки при обновлениях SwiftUI.
        /// - Parameter registry: Реестр представлений текущего медиадвижка.
        init(registry: ConferenceRendererRegistry) { self.registry = registry }
    }
    /// Создаёт координатор, который хранит привязку экземпляра представления к дорожке.
    func makeCoordinator() -> Coordinator { Coordinator(registry: registry) }
    /// Создаёт Metal-представление и применяет начальные параметры вывода видео.
    /// - Parameter context: Контекст SwiftUI с координатором привязки дорожки.
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true; view.isAccessibilityElement = false
        updateUIView(view, context: context)
        return view
    }
    /// Обновляет привязку дорожки, отражение и режим вписывания кадра.
    /// - Parameters:
    ///   - view: Представление, в котором воспроизводится дорожка.
    ///   - context: Контекст SwiftUI с текущим координатором.
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        if context.coordinator.track !== track {
            registry.detach(context.coordinator.id)
            context.coordinator.track = track
            if let track { registry.attach(track, view: view, id: context.coordinator.id) }
        }
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }
    /// Отсоединяет дорожку и очищает ссылку координатора при удалении представления.
    /// - Parameters:
    ///   - view: Удаляемое представление видео.
    ///   - coordinator: Координатор, владеющий привязкой к реестру.
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.registry.detach(coordinator.id); coordinator.track = nil
    }
}
#endif
