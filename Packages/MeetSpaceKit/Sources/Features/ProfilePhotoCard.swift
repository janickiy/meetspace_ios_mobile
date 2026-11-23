import SwiftUI
import PhotosUI
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers
import MeetSpaceCore
import MeetSpaceDesignSystem

@MainActor @Observable final class DemoAccountProfile {
    var name = "Александр Соколов"
    var bio = ""
    var server: ServerOrigin?
    var photo: Data?
    var notificationDraft = NotificationPreferences()
    var savedNotifications = NotificationPreferences()
    var notificationSound = true
}

private struct SelectedPortrait: Transferable, Identifiable {
    let id = UUID()
    let image: CGImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            guard let source = CGImageSourceCreateWithURL(file.file as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024
                  ] as CFDictionary) else { throw ClientError.unsupportedFile }
            return SelectedPortrait(image: thumbnail)
        }
    }
}

struct ProfilePhotoCard: View {
    let name: String
    let photo: Data?
    var hasPhoto: Bool
    var save: (Data?) async -> Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection: PhotosPickerItem?
    @State private var choosing = false
    @State private var portrait: SelectedPortrait?
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) :
            AnyLayout(HStackLayout(spacing: 18))
        VStack(alignment: .leading, spacing: 8) {
            layout {
                Button { choosing = true } label: {
                    ProfileAvatar(name: name, size: 96, cornerRadius: 27, photo: photo)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera").font(.system(size: 12)).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(MSTheme.accent, in: Circle())
                                .overlay(Circle().strokeBorder(MSTheme.surface, lineWidth: 2))
                        }
                }.buttonStyle(.plain).accessibilityLabel(tr(hasPhoto ? "Изменить фото" : "Добавить фото"))
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("Фото профиля")).font(MSTheme.font(15, weight: .semibold))
                    Text(tr("Ваше фото видно участникам встреч и чатов.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }
                        VStack(alignment: .leading, spacing: 4) { actions }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MSTheme.line))
            .photosPicker(isPresented: $choosing, selection: $selection, matching: .images)
            .task(id: selection) {
                guard let selection else { return }
                error = nil
                do {
                    let result = try await selection.loadTransferable(type: SelectedPortrait.self)
                    guard !Task.isCancelled else { return }
                    guard let result else { throw ClientError.unsupportedFile }
                    portrait = result
                } catch { if !Task.isCancelled { self.error = userMessage(error); self.selection = nil } }
            }
            .sheet(item: $portrait, onDismiss: { selection = nil }) { selected in
                PortraitCropView(image: selected.image, save: save)
            }
            .confirmationDialog(tr("Удалить фото профиля?"), isPresented: $removing) {
                Button(tr("Удалить"), role: .destructive) { Task { _ = await save(nil) } }
            }
    }

    @ViewBuilder private var actions: some View {
        Button { choosing = true } label: {
            Label(tr(hasPhoto ? "Изменить фото" : "Добавить фото"), systemImage: hasPhoto ? "pencil" : "square.and.arrow.up")
                .font(MSTheme.font(12, weight: .semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line))
        }.buttonStyle(.plain)
        if hasPhoto { Button(tr("Удалить"), role: .destructive) { removing = true }.frame(minHeight: 44) }
    }
}

private struct PortraitCropView: View {
    let image: CGImage
    let save: (Data?) async -> Bool
    @State private var zoom = 1.0
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var crop: CGImage? {
        let side = max(1, Int(Double(min(image.width, image.height)) / zoom))
        return image.cropping(to: CGRect(x: Int(Double(image.width - side) * x), y: Int(Double(image.height - side) * y),
                                         width: side, height: side))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let crop { Image(decorative: crop, scale: 1).resizable().aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 288).frame(maxWidth: .infinity) }
                    slider("Масштаб", $zoom, 1...4)
                    slider("По горизонтали", $x, 0...1)
                    slider("По вертикали", $y, 0...1)
                    if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                    Button(tr("Сохранить фото")) {
                        guard let data = encodedCrop() else { error = "Не удалось сохранить фото"; return }
                        saving = true
                        Task {
                            if await save(data) { dismiss() }
                            else { error = "Не удалось сохранить фото"; saving = false }
                        }
                    }.buttonStyle(MSButtonStyle())
                }.padding(24)
            }.disabled(saving).navigationTitle(tr("Фото профиля")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("xmark", label: "Отмена") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving)
    }
    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr(label)).font(MSTheme.font(13, weight: .semibold))
            Slider(value: value, in: range) { Text(tr(label)) }
        }
    }
    private func encodedCrop() -> Data? {
        guard let crop else { return nil }
        let side = min(crop.width, 512)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.interpolationQuality = .high; context.draw(crop, in: rect)
        let bytes = NSMutableData()
        guard let resized = context.makeImage(), let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }
}
