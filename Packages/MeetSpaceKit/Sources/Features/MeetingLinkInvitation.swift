import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import MeetSpaceAPI
import MeetSpaceCore
import MeetSpaceDesignSystem
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum MeetingLinkInvitation {
    case live(Conference, ConferenceRepository)
    case demo(Int)

    var cachedURL: URL? {
        switch self {
        case let .live(meeting, repository): ConferenceInviteGateway.shareURL(for: meeting, origin: repository.origin)
        case let .demo(id): URL(string: "https://meet.example.org/i/demo-\(id)")
        }
    }

    /// Получает актуальную ссылку на встречу или возвращает сохранённую демонстрационную ссылку.
    func refreshURL() async throws -> URL? {
        guard case let .live(meeting, repository) = self else { return cachedURL }
        return ConferenceInviteGateway.shareURL(for: try await repository.read(meeting.id), origin: repository.origin)
    }
}

struct MeetingLinkInvitationSheet: View {
    let title: String
    let invitation: MeetingLinkInvitation
    let canInvitePeople: Bool
    let close: () -> Void
    @State private var people = false
    @State private var refreshedURL: URL?
    @State private var loadError: String?
    @State private var loading = false
    @State private var copied = false
    @State private var copyFailed = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var url: URL? { refreshedURL ?? invitation.cachedURL }

    var body: some View {
        if people {
            MeetingInvitationRecipients(invitation: invitation) { people = false }
        } else {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 780 && !typeSize.isAccessibilitySize
                WorkspaceFormSheet(title: "Пригласить на встречу", identifier: "meetingInvite", maxWidth: wide ? 680 : 440, close: close) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(verbatim: title).font(MSTheme.font(17, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            linkActions
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if wide, let url {
                            MeetingInviteQR(url: url, size: 180).frame(width: 180)
                                .accessibilityElement(children: .combine).accessibilityIdentifier("meetingInvite.qr")
                        }
                    }
                }
            }.task {
                if url == nil { await refresh() }
            }
        }
    }

    @ViewBuilder private var linkActions: some View {
        if let url {
            WorkspaceFormField(title: "Ссылка-приглашение") {
                Text(verbatim: url.absoluteString).textSelection(.enabled)
                    .workspaceFormInput().accessibilityIdentifier("meetingInvite.url")
            }
            Button {
                copied = copyMeetingLink(url)
                copyFailed = !copied
            } label: {
                Label(tr(copied ? "Ссылка скопирована" : "Скопировать ссылку"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }.buttonStyle(MSButtonStyle()).accessibilityIdentifier("meetingInvite.copy")
            if copyFailed {
                Text(tr("Не удалось скопировать ссылку. Её можно выделить вручную.")).foregroundStyle(MSTheme.danger)
            }
        } else if loading {
            ProgressView()
        } else {
            Text(tr(loadError ?? "Ссылка на встречу недоступна.")).foregroundStyle(MSTheme.muted)
            Button(tr("Повторить")) { Task { await refresh() } }
        }
        if canInvitePeople {
            Button { people = true } label: {
                Label(tr("Пригласить по имени или email"), systemImage: "person.badge.plus")
                    .font(MSTheme.font(14, weight: .semibold)).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line))
            }.buttonStyle(.plain).accessibilityIdentifier("meetingInvite.people")
        }
        if url != nil {
            Text(tr("По ссылке можно присоединиться без аккаунта.")).foregroundStyle(MSTheme.muted)
            if case .demo = invitation { Text(tr("Адрес демонстрационный.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
        }
    }

    /// Обновляет ссылку в открытом окне приглашения и показывает результат запроса.
    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await invitation.refreshURL()
            try Task.checkCancellation()
            refreshedURL = next
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = userMessage(error) }
        }
    }
}

struct MeetingInviteQR: View {
    let url: URL
    let size: CGFloat
    var inset: CGFloat = 10
    var line = MSTheme.line
    var muted = MSTheme.muted

    var body: some View {
        if let image = image {
            VStack(spacing: 5) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .scaledToFit().padding(inset).frame(width: size, height: size)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(line)).padding(.bottom, 6)
                Text(tr("Подключиться с телефона")).font(MSTheme.font(12, weight: .semibold))
                Text(tr("Наведите камеру на QR-код")).font(MSTheme.font(11)).foregroundStyle(muted)
            }.multilineTextAlignment(.center)
        }
    }

    private static let context = CIContext()
    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage else { return nil }
        return Self.context.createCGImage(image, from: image.extent)
    }
}

@MainActor func copyMeetingLink(_ url: URL) -> Bool {
    #if os(iOS)
    UIPasteboard.general.setItems([["public.url": url, "public.utf8-plain-text": url.absoluteString]])
    return true
    #else
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.writeObjects([url as NSURL])
    #endif
}
