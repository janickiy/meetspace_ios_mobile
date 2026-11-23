import SwiftUI
import AVKit
import Combine
import MeetSpaceCore
import MeetSpaceDesignSystem

/// The scroll view belongs to each navigation destination, so returning to the library
/// restores the search controls and the user's position in its results.
struct RecordingPage<Content: View>: View {
    let title: String
    let onBack: () -> Void
    var error: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            RecordingsPageHeader(title: title, onBack: onBack)
            if let error {
                Text(tr(error)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(MSTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("recordingsError")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, sizeClass == .compact ? 16 : 24)
                    .padding(.top, sizeClass == .compact ? 6 : 20).padding(.bottom, 24)
                    .frame(maxWidth: 1140, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(MSTheme.ink).background(MSTheme.background)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

struct LiveRecordingDetail: View {
    let model: RecordingsModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        RecordingPage(title: "Просмотр записи", onBack: { dismiss() }, error: model.error) {
            if let row = model.selected, row.id == id {
                RecordingDetailContent(entry: RecordingLibraryEntry(row: row, account: model.account),
                                       model: model, row: row, onAllRecordings: { dismiss() })
                #if os(macOS)
                if let url = model.exportURL { ShareLink(tr("Сохранить файл"), item: url) }
                #endif
                HStack {
                    Button(tr("Обновить запись")) { Task { await load() } }
                        .buttonStyle(MSTextButtonStyle())
                    Spacer()
                    if model.canDeleteSelected {
                        Button(tr("Удалить запись"), role: .destructive) { confirmingDelete = true }
                            .frame(minHeight: 44)
                    }
                }.font(MSTheme.font(12)).disabled(model.loading || model.downloading)
            } else if model.loading {
                ProgressView(tr("Загружаем запись…")).frame(maxWidth: .infinity).padding()
            } else {
                if model.error == nil { Text(tr("Запись недоступна")) }
                Button(tr("Повторить")) { Task { await load() } }
                    .buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("recording.retry")
            }
        }
        .task(id: id) { await load() }
        .refreshable { await load() }
        .onDisappear { model.releaseSelection() }
        .confirmationDialog(tr("Удалить запись и все её материалы для всех участников?"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(tr("Удалить запись"), role: .destructive) {
                Task {
                    await model.deleteSelected()
                    if !model.items.contains(where: { $0.id == id }) { dismiss() }
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { shown in
            if !shown { Task { await model.dismissExport() } }
        })) {
            if let url = model.exportURL { RecordingExportSheet(url: url) }
        }
        #endif
    }

    private func load() async {
        if let row = model.items.first(where: { $0.id == id }) { await model.select(row) }
    }
}

struct RecordingDetailContent: View {
    let entry: RecordingLibraryEntry
    var model: RecordingsModel? = nil
    var row: RecordingLibraryItem? = nil
    let onAllRecordings: () -> Void
    @Environment(\.workspaceWidth) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    private var wide: Bool { width >= 780 && !typeSize.isAccessibilitySize }
    private var files: [RecordingFile] { row?.recording.files.filter { $0.type != "preview_jpg" } ?? [] }
    private var dateText: String { entry.date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide).year()) }
    private var timeText: String { entry.date.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).hour().minute()) }
    private var status: String? { entry.statusTitle.map(tr) }
    private var archiveAvailable: Bool {
        row?.recording.ready == true && files.contains { $0.type == "tracks_archive" && $0.available }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Button(action: onAllRecordings) {
                HStack(spacing: 7) { WorkspaceIcon("arrow.left", size: 16); Text(tr("Все записи")) }
                    .font(MSTheme.font(12)).frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr(entry.kind.title)).font(MSTheme.font(10, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(MSTheme.accent).accessibilityIdentifier("recordingKind")
                Text(entry.title).font(MSTheme.font(wide ? 26 : 23, weight: .semibold, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("recordingTitle")
                Text([dateText, entry.peopleText].compactMap { $0 }.joined(separator: " · "))
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            }
            if wide {
                HStack(alignment: .top, spacing: 22) {
                    playback.frame(maxWidth: .infinity)
                    information.frame(width: min(365, width * 0.36))
                }
            } else {
                playback
                information
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.clear.aspectRatio(wide ? 1.6 : 16.0 / 11, contentMode: .fit)
                if model?.playbackURL == nil { stageControls.padding(22) }
            }
            .frame(maxWidth: .infinity)
            .background {
                RecordingPreview(entry: entry, large: true)
                    .overlay { if row?.recording.media == nil { Color(red: 0.10, green: 0.13, blue: 0.21).opacity(0.68) } }
            }
            .overlay {
                if let model, let url = model.playbackURL {
                    RecordingPlayerView(url: url, audioCover: row?.recording.media?.type == "final_audio" ? entry : nil) {
                        model.playbackFailed(url: url)
                    }.id(url)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            if let model, model.downloading {
                ProgressView(value: model.progress).accessibilityIdentifier("recordingDownloadProgress")
                Text(tr("Загружаем и проверяем файл…")).font(MSTheme.font(12))
                Button(tr("Отменить загрузку")) { Task { await model.cancelDownload() } }
                    .buttonStyle(MSTextButtonStyle())
            }
            RecordingListRetention(demo: model == nil)
        }
    }

    @ViewBuilder private var stageControls: some View {
        if let model, let media = row?.recording.media {
            Button {
                Task { await model.download(fileID: media.id, play: true) }
            } label: {
                Image(systemName: "play.fill").font(.system(size: 24))
                    .frame(width: 62, height: 62).foregroundStyle(.white)
                    .background(Color(red: 0.09, green: 0.13, blue: 0.22).opacity(0.85), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.55)) }
            }.buttonStyle(.plain).disabled(model.downloading || model.loading)
                .accessibilityLabel(tr("Воспроизвести запись")).accessibilityIdentifier("playRecording")
        } else {
            let message = stageMessage
            VStack(spacing: 12) {
                Text(tr(message.title)).font(MSTheme.font(19, weight: .semibold, relativeTo: .title3))
                    .accessibilityIdentifier(row?.recording.ready == false ? "recordingStatus" : "recordingStageTitle")
                if let subtitle = message.subtitle {
                    Text(tr(subtitle)).font(MSTheme.font(12)).foregroundStyle(Color(white: 0.85))
                }
            }.foregroundStyle(.white).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 290)
        }
    }

    private var stageMessage: (title: String, subtitle: String?) {
        if let recording = row?.recording, !recording.ready {
            return (recording.statusTitle, recording.active ? "Материалы появятся после завершения обработки." : nil)
        }
        if model == nil && entry.isLive {
            return ("Встреча ещё в эфире", "Материалы появятся после завершения обработки.")
        }
        if entry.kind == .tracks {
            return ("Отдельная дорожка каждого участника", model == nil ? "Архив дорожек — в разделе «Материалы»."
                    : archiveAvailable ? "Скачайте архив в разделе «Материалы»." : "Архив дорожек недоступен.")
        }
        if model == nil {
            return (entry.kind == .audio ? "Демонстрационная аудиозапись" : "Демонстрационная видеозапись", nil)
        }
        return ("Воспроизведение недоступно", nil)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading("О записи")
                detailRow("Дата записи", dateText + " · " + timeText)
                if let duration = entry.durationText, row?.recording.active != true {
                    detailRow("Длительность", duration)
                }
                if let size = entry.sizeText ?? materialSize { detailRow("Размер", size) }
                if let owner = entry.owner { detailRow("Организатор", owner) }
                if let count = entry.participantCount { detailRow("Участники", String(count)) }
                if let status { detailRow("Статус", status, valueID: row?.recording.ready == false ? nil : "recordingStatus") }
            }.msCard(padding: 18)
            materials
        }
    }

    private var materialSize: String? {
        guard !files.isEmpty else { return nil }
        var total: Int64 = 0
        for file in files {
            guard let size = file.sizeBytes else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(tr(title)).font(MSTheme.font(16, weight: .semibold))
            .padding(.bottom, 12).accessibilityAddTraits(.isHeader)
    }

    private func detailRow(_ title: String, _ value: String, valueID: String? = nil) -> some View {
        VStack(spacing: 0) {
            Divider()
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(tr(title)).foregroundStyle(MSTheme.muted)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(value).multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .accessibilityIdentifier(valueID ?? "")
            }.font(MSTheme.font(12)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
        }
    }

    private var materials: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("Материалы")
            if let model {
                if files.isEmpty {
                    Text(tr(row?.recording.active == true ? "Файлы ещё обрабатываются." : "Доступных материалов нет."))
                        .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                }
                ForEach(files) { file in
                    Divider()
                    HStack(spacing: 10) {
                        fileIcon(archive: file.type == "tracks_archive")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.filename).font(MSTheme.font(12, weight: .semibold))
                            Text(fileDescription(file)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { Task { await model.download(fileID: file.id, play: false) } } label: {
                            WorkspaceIcon("arrow.down.to.line", size: 19).frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
                            .accessibilityLabel(tr("Скачать") + " " + file.filename).accessibilityIdentifier("downloadRecording")
                            .disabled(row?.recording.ready != true || !file.available || model.downloading || model.loading)
                    }.padding(.vertical, 6)
                }
                if !files.isEmpty {
                    Text(tr("Файлы до 512 МБ загружаются полностью перед открытием."))
                        .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).padding(.top, 8)
                }
            } else if entry.isLive {
                Text(tr("Файлы ещё обрабатываются.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            } else {
                HStack(spacing: 10) {
                    fileIcon(archive: entry.kind == .tracks)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr(entry.kind == .tracks ? "Архив дорожек" : entry.kind.title)).font(MSTheme.font(12, weight: .semibold))
                        Text(tr("Медиафайл не подключён")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    }
                }
                ShareLink(item: demoSummary) { Label(tr("Поделиться сведениями"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(MSTextButtonStyle()).font(MSTheme.font(12)).padding(.top, 6)
                    .accessibilityIdentifier("recording.shareDetails")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).msCard(padding: 18)
    }

    private func fileDescription(_ file: RecordingFile) -> String {
        let size = file.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let suffix = (file.filename as NSString).pathExtension.uppercased()
        return [suffix.isEmpty ? nil : suffix, size, file.available ? nil : tr("Недоступно")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func fileIcon(archive: Bool) -> some View {
        WorkspaceIcon(archive ? "archivebox" : "doc", size: 18).foregroundStyle(MSTheme.accent)
            .frame(width: 35, height: 40).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private var demoSummary: String {
        [tr("Демонстрационная запись"), entry.title, dateText + " · " + timeText, tr(entry.kind.title),
         entry.durationText, entry.sizeText, entry.owner, entry.peopleText].compactMap { $0 }.joined(separator: "\n")
    }
}

private struct RecordingPlayerView: View {
    let audioCover: RecordingLibraryEntry?
    let onFailure: () -> Void
    @Environment(\.scenePhase) private var phase
    @State private var player: AVPlayer

    init(url: URL, audioCover: RecordingLibraryEntry?, onFailure: @escaping () -> Void) {
        self.audioCover = audioCover
        self.onFailure = onFailure
        _player = State(initialValue: AVPlayer(url: url))
    }
    var body: some View {
        VideoPlayer(player: player) {
            if let audioCover { RecordingPreview(entry: audioCover, large: true).allowsHitTesting(false) }
        }
            .accessibilityIdentifier("recordingPlayer")
            .onReceive(player.publisher(for: \.status)) { if $0 == .failed { onFailure() } }
            .onReceive(player.publisher(for: \.currentItem).compactMap { $0 }.flatMap { $0.publisher(for: \.status) }) {
                if $0 == .failed { onFailure() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)) { _ in onFailure() }
            .onAppear { player.play() }
            .onChange(of: phase) { _, value in if value != .active { player.pause() } }
            .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
}

#if os(iOS)
private struct RecordingExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
