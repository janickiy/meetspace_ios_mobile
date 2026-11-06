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
    func attach(_ track: RTCVideoTrack, view: RTCMTLVideoView, id: UUID) {
        detach(id)
        attachments[id] = Attachment(track: track, view: view)
        track.add(view)
    }
    func detach(_ id: UUID) {
        guard let attachment = attachments.removeValue(forKey: id), let view = attachment.view else { return }
        attachment.track.remove(view); view.renderFrame(nil)
    }
    func detach(trackID: String) {
        let ids = attachments.filter { $0.value.track.trackId == trackID }.map(\.key)
        for id in ids { detach(id) }
    }
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
        init(registry: ConferenceRendererRegistry) { self.registry = registry }
    }
    func makeCoordinator() -> Coordinator { Coordinator(registry: registry) }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true; view.isAccessibilityElement = false
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        if context.coordinator.track !== track {
            registry.detach(context.coordinator.id)
            context.coordinator.track = track
            if let track { registry.attach(track, view: view, id: context.coordinator.id) }
        }
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.registry.detach(coordinator.id); coordinator.track = nil
    }
}
#endif
