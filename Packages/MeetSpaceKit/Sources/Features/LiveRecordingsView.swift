import SwiftUI
import AVKit
import Combine
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveRecordingsView: View {
    @Bindable var model: RecordingsModel
    @State private var confirmingDelete = false
    private let scrollTopID = "recordingsScrollTop"
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selected = model.selected { detail(selected) } else { library }
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                }.padding(24).frame(maxWidth: 1140).frame(maxWidth: .infinity).id(scrollTopID)
            }
            .onChange(of: model.selected?.id) { _, _ in
                proxy.scrollTo(scrollTopID, anchor: .top)
            }
        }.background(MSTheme.background).navigationTitle(tr("Записи"))
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = model.error {
                    Text(tr(error)).font(MSTheme.font(13)).foregroundStyle(MSTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(MSTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24).padding(.vertical, 12).background(MSTheme.background)
                        .accessibilityIdentifier("recordingsError")
                }
            }
            .task { if model.items.isEmpty { await model.load() } }
            .refreshable { if let row = model.selected { await model.select(row) } else { await model.load() } }
            .onDisappear { Task { await model.back() } }
            .confirmationDialog(tr("Удалить запись и все её материалы для всех участников?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(tr("Удалить запись"), role: .destructive) { Task { await model.deleteSelected() } }
            }
            #if os(iOS)
            .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { Task { await model.dismissExport() } } })) {
                if let url = model.exportURL { RecordingExportSheet(url: url) }
            }
            #endif
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Записи встреч")).font(MSTheme.font(26, weight: .semibold))
            SearchBox(text: $model.query, placeholder: "Поиск записей")
            ViewThatFits(in: .horizontal) { HStack { filters }; VStack(alignment: .leading) { filters } }
            Text(tr("Поиск и фильтры применяются к загруженным записям.")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            if model.visibleItems.isEmpty && !model.loading {
                ContentUnavailableView(tr("Записей пока нет"), systemImage: "play.rectangle", description: Text(tr("Здесь появятся доступные вам записи встреч.")))
            }
            ForEach(model.visibleItems) { row in
                Button { Task { await model.select(row) } } label: {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 10).fill(MSTheme.accentSoft).frame(width: 90, height: 64)
                            .overlay { Image(systemName: row.recording.mode == "audio_only" ? "waveform" : "play.rectangle").font(.system(size: 26)).foregroundStyle(MSTheme.accent) }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.conference.title).font(MSTheme.font(14, weight: .semibold)).foregroundStyle(MSTheme.ink)
                            Text(row.recording.createdAt, format: .dateTime.day().month().year()).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                            Text(tr(row.recording.statusTitle)).font(MSTheme.font(11)).foregroundStyle(row.recording.ready ? MSTheme.accent : MSTheme.muted)
                        }
                        Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(MSTheme.muted).accessibilityHidden(true)
                    }.msCard().contentShape(Rectangle()).accessibilityElement(children: .combine)
                }.buttonStyle(.plain).disabled(model.loading).accessibilityIdentifier("recording.\(row.id.uuidString)")
            }
            if model.nextCursor != nil {
                Button(tr("Загрузить ещё")) { Task { await model.load(more: true) } }.buttonStyle(MSButtonStyle(primary: false)).disabled(model.loading)
            }
            Button(tr("Обновить записи")) { Task { await model.load() } }.disabled(model.loading).frame(minHeight: 44)
            FeatureNotice("Срок хранения записей задаётся сервером. Доступ проверяется перед воспроизведением и скачиванием.")
        }
    }
    @ViewBuilder private var filters: some View {
        Picker(tr("Формат записи"), selection: $model.modeFilter) {
            Text(tr("Все форматы")).tag("all")
            ForEach(RecordingMode.allCases) { Text(tr($0.title)).tag($0.rawValue) }
        }.pickerStyle(.menu).accessibilityIdentifier("recordingModeFilter")
        Picker(tr("Статус записи"), selection: $model.statusFilter) {
            Text(tr("Все статусы")).tag("all")
            Text(tr("Готовые")).tag("ready")
            Text(tr("В обработке")).tag("processing")
        }.pickerStyle(.menu)
    }
    @ViewBuilder private func detail(_ row: RecordingLibraryItem) -> some View {
        Button { Task { await model.back() } } label: { Label(tr("Все записи"), systemImage: "arrow.left") }.frame(minHeight: 44)
        Text(row.conference.title).font(MSTheme.font(26, weight: .semibold)).accessibilityIdentifier("recordingTitle")
        Text(tr(row.recording.statusTitle)).foregroundStyle(MSTheme.muted).accessibilityIdentifier("recordingStatus")
        if let url = model.playbackURL {
            RecordingPlayerView(url: url) { model.playbackFailed() }.id(url)
                .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
        } else if let media = row.recording.media {
            Button { Task { await model.download(fileID: media.id, play: true) } } label: {
                Label(tr("Воспроизвести запись"), systemImage: "play.circle.fill").frame(maxWidth: .infinity, minHeight: 120)
                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).disabled(model.downloading).accessibilityIdentifier("playRecording")
        } else {
            FeatureNotice(row.recording.active ? "Запись обрабатывается. Обновите страницу позже." : "Воспроизведение недоступно. Доступные материалы можно скачать ниже.")
        }
        if model.downloading {
            ProgressView(value: model.progress).accessibilityIdentifier("recordingDownloadProgress")
            Text(tr("Загружаем и проверяем файл…")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Button(tr("Отменить загрузку")) { Task { await model.cancelDownload() } }.frame(minHeight: 44)
        }
        Text(tr("Материалы")).font(MSTheme.font(18, weight: .semibold))
        ForEach(row.recording.files.filter { $0.type != "preview_jpg" }) { file in
            HStack {
                Image(systemName: file.type == "tracks_archive" ? "archivebox" : "doc")
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.filename).font(MSTheme.font(13))
                    if let bytes = file.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
                }
                Spacer(minLength: 4)
                Button { Task { await model.download(fileID: file.id, play: false) } } label: { Image(systemName: "arrow.down.circle").font(.system(size: 24)).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(tr("Скачать запись")).accessibilityIdentifier("downloadRecording")
                    .disabled(!row.recording.ready || !file.available || model.downloading)
            }.msCard()
        }
        #if os(macOS)
        if let url = model.exportURL { ShareLink(tr("Сохранить файл"), item: url) }
        #endif
        Button(tr("Обновить запись")) { Task { await model.select(row) } }.disabled(model.loading || model.downloading).frame(minHeight: 44)
        if model.canDeleteSelected {
            Button(tr("Удалить запись"), role: .destructive) { confirmingDelete = true }.disabled(model.loading || model.downloading).frame(minHeight: 44)
        }
        FeatureNotice("Перед воспроизведением файл загружается полностью. Максимальный размер — 512 МБ. Системный звук ReplayKit не записывается этим приложением.")
    }
}

private struct RecordingPlayerView: View {
    let onFailure: () -> Void
    @Environment(\.scenePhase) private var phase
    @State private var player: AVPlayer
    init(url: URL, onFailure: @escaping () -> Void) { self.onFailure = onFailure; _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        VideoPlayer(player: player)
            .accessibilityIdentifier("recordingPlayer")
            .onReceive(player.publisher(for: \.status)) { if $0 == .failed { onFailure() } }
            .onReceive(player.publisher(for: \.currentItem).compactMap { $0 }.flatMap { $0.publisher(for: \.status) }) { if $0 == .failed { onFailure() } }
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

struct ConferenceRecordingControls: View {
    @Bindable var model: RecordingsModel
    let conference: Conference
    let participant: ConferenceParticipant
    @State private var expanded = false
    @State private var mode = RecordingMode.composite
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let active = model.conferenceItems[conference.id]?.first(where: \.active) {
                    Text(tr(active.statusTitle)).font(MSTheme.font(12))
                    if RecordingPermissions.canStop(active, conference: conference, participant: participant, accountID: model.account.user.id) {
                        Button(tr("Остановить запись")) { Task { await model.stop(active, conference: conference, participant: participant) } }.frame(minHeight: 44)
                    }
                } else if !model.modes.isEmpty && RecordingPermissions.canStart(conference: conference, participant: participant, accountID: model.account.user.id) {
                    Picker(tr("Формат записи"), selection: $mode) { ForEach(model.modes) { Text(tr($0.title)).tag($0) } }
                    Button(tr("Начать запись")) { Task { await model.start(conference: conference, participant: participant, mode: mode) } }.frame(minHeight: 44)
                        .accessibilityIdentifier("startServerRecording")
                } else { Text(tr("Запись недоступна для текущего состояния встречи.")).font(MSTheme.font(12)) }
                Button(tr("Обновить статус записи")) { Task { await model.loadConference(conference.id) } }.frame(minHeight: 44)
                if let error = model.error { Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger) }
            }.disabled(model.controlling)
        } label: {
            Label(tr(model.conferenceItems[conference.id]?.first(where: \.active)?.statusTitle ?? "Запись встречи"), systemImage: "record.circle").font(MSTheme.font(12))
        }
            .task(id: conference.id) {
                while !Task.isCancelled {
                    await model.loadConference(conference.id)
                    if !model.modes.contains(mode), let supported = model.modes.first { mode = supported }
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                }
            }
    }
}
