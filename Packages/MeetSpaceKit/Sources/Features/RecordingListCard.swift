import SwiftUI
import MeetSpaceDesignSystem

struct RecordingListCard: View {
    let entry: RecordingLibraryEntry
    let wide: Bool
    let grid: Bool
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    @Environment(\.workspaceWidth) private var width

    var body: some View {
        Group {
            if grid || typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: open) {
                        VStack(alignment: .leading, spacing: 8) {
                            if grid { RecordingPreview(entry: entry).aspectRatio(16 / 9, contentMode: .fit) }
                            summary
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("recording.\(entry.id)")
                    if grid { Rectangle().fill(MSTheme.line).frame(height: 1) }
                    HStack { if grid { watch }; Spacer(); delete }
                }
            } else {
                HStack(spacing: wide ? 14 : 4) {
                    Button(action: open) {
                        let coverWidth: CGFloat = wide ? (width <= 1000 ? 128 : 150) : 84
                        HStack(spacing: wide ? (width <= 1000 ? 12 : 18) : 8) {
                            RecordingPreview(entry: entry).frame(width: coverWidth, height: wide ? coverWidth * 10 / 16 : coverWidth)
                            summary
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("recording.\(entry.id)")
                    if wide { watch }
                    delete
                }
            }
        }.msCard(padding: wide && !grid ? 12 : 10)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                WorkspaceIcon(entry.kind.icon, size: wide ? 13 : 11)
                Text(tr(entry.kind.title))
            }.font(MSTheme.font(wide ? 11 : 10, weight: .semibold, relativeTo: .caption)).foregroundStyle(MSTheme.accent)
                .accessibilityIdentifier("recording.mode.\(entry.id.lowercased())")
            Text(entry.title).font(MSTheme.font(wide ? 14 : 13, weight: .semibold)).foregroundStyle(MSTheme.ink)
            Text(metadata).font(MSTheme.font(wide ? 11 : 10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
                .accessibilityIdentifier("recording.date.\(entry.id.lowercased())")
            if let owner = entry.owner {
                Text(tr("Организатор") + ": " + owner).font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
            }
            if let status = entry.statusTitle {
                Text(tr(status)).font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
                    .accessibilityIdentifier("recording.status.\(entry.id.lowercased())")
            }
        }.fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
    }

    private var metadata: String {
        let locale = Locale(identifier: "ru_RU")
        let date = entry.date.formatted(.dateTime.locale(locale).day().month(.wide))
        let time = entry.date.formatted(.dateTime.locale(locale).hour().minute())
        return [date, time, entry.peopleText].compactMap { $0 }.joined(separator: " · ")
    }

    private var watch: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                WorkspaceIcon(entry.openAction.icon, size: 15)
                if !grid || width > 1000 { Text(tr(entry.openAction.rawValue)) }
            }.font(MSTheme.font(11)).padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(MSTheme.line) }
        }.buttonStyle(.plain).accessibilityLabel(tr(entry.openAction.rawValue))
    }

    @ViewBuilder private var delete: some View {
        if entry.canDelete {
            Button(action: remove) {
                WorkspaceIcon("trash", size: 18).foregroundStyle(MSTheme.danger)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tr("Удалить запись") + " " + entry.title)
                .accessibilityIdentifier("recording.delete.\(entry.id)")
        }
    }
}

struct RecordingListRetention: View {
    let demo: Bool

    private var notice: AttributedString {
        var text = AttributedString(tr(demo ? "Готовые записи хранятся 7 дней. Ссылка на страницу доступна только участникам встречи."
                                         : "Срок хранения записей задаётся сервером. Доступ проверяется перед воспроизведением и скачиванием."))
        if demo, let range = text.range(of: tr("7 дней")) {
            text[range].font = MSTheme.font(11, weight: .semibold)
            text[range].foregroundColor = MSTheme.ink
        }
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            WorkspaceIcon("info.circle", size: 16)
            Text(notice)
                .font(MSTheme.font(11)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recordings.retentionNotice")
        }.foregroundStyle(MSTheme.muted).padding(.vertical, 12)
    }
}
