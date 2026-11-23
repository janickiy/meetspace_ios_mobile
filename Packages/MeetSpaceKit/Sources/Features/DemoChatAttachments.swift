import SwiftUI
import MeetSpaceDesignSystem
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct DemoChatAttachments: View {
    let files: [String]
    var gallery = false
    @State private var opened: File?
    private struct File: Identifiable {
        let name: String
        var id: String { name }
        var url: URL? {
            let asset = switch name {
            case "Переговорная.jpg": "meeting-room"
            case "Офис команды.jpg", "Наш офис.jpg": "office"
            case "Рабочее пространство.jpg": "workspace"
            default: ""
            }
            return asset.isEmpty ? nil : Bundle.module.url(forResource: asset, withExtension: "jpg", subdirectory: "ChatPhotos")
        }
        var image: Image? {
            guard let url else { return nil }
            #if os(iOS)
            return UIImage(contentsOfFile: url.path).map(Image.init(uiImage:))
            #else
            return NSImage(contentsOf: url).map(Image.init(nsImage:))
            #endif
        }
    }

    var body: some View {
        let attachments = files.map(File.init(name:))
        let photos = attachments.filter { $0.url != nil }
        VStack(spacing: 6) {
            if gallery && !photos.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(photos) { file in
                        photo(file).aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            } else if let first = photos.first {
                HStack(spacing: 6) {
                    photo(first)
                    if photos.count > 1 {
                        VStack(spacing: 6) {
                            ForEach(photos.dropFirst()) { photo($0) }
                        }
                    }
                }.aspectRatio(photos.count == 1 ? 1.6 : 1.5, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            ForEach(attachments.filter { $0.url == nil }) { file in
                Button { opened = file } label: {
                    if gallery {
                        ChatInfoFileRow(icon: "doc.text", title: file.name, subtitle: "2,4 МБ", trailing: "chevron.right")
                    } else { ChatFileCard(name: file.name, size: "2,4 МБ") }
                }.buttonStyle(.plain)
            }
        }.padding(.top, gallery ? 0 : (photos.isEmpty ? 5 : 7)).sheet(item: $opened) { file in
            NavigationStack {
                VStack(alignment: .leading, spacing: 15) {
                    if let image = file.image, let url = file.url {
                        image.resizable().scaledToFit().accessibilityLabel(file.name)
                        ShareLink(item: url) { Label(tr("Сохранить или поделиться"), systemImage: "square.and.arrow.up") }
                    } else {
                        Label("2,4 МБ · PDF", systemImage: "doc.text").foregroundStyle(MSTheme.accent)
                        Text(tr("Материалы к дизайн-синхронизации: навигация, первый запуск и встреча на планшете."))
                        Text(tr("Демонстрационная карточка вложения.")).foregroundStyle(MSTheme.muted)
                    }
                }.padding(20).navigationTitle(file.name).msInlineTitle()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { IconButton("xmark", label: "Закрыть") { opened = nil } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private func photo(_ file: File) -> some View {
        Button { opened = file } label: {
            GeometryReader { geometry in
                file.image?.resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }.buttonStyle(.plain).accessibilityLabel(file.name)
    }
}
