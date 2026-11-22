import SwiftUI
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceDesignSystem

struct LiveMeetingDetails: View {
    let item: MeetingListItem<Conference>
    let zone: TimeZone
    let workspace: ConferenceWorkspace
    let recordings: RecordingsModel?
    let openRecording: () -> Void
    @State private var confirmingFinish = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tr(item.statusTitle)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        .padding(6).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 5))
                    Text(verbatim: item.title).font(MSTheme.font(21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        if let date = item.date {
                            Text(calendarText(date, format: "d MMMM yyyy · HH:mm", zone: zone))
                        }
                        if let duration = item.duration { Text("\(duration) " + tr("мин")) }
                        Text(tr(item.mine ? "Вы организатор" : "Вы участник"))
                        if item.value.waitingRoomEnabled { Text(tr("Зал ожидания включён")) }
                    }.font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                    if item.status == .past {
                        if let recordings { materials(recordings) }
                    } else {
                        Button(tr(item.status == .active ? "Подключиться" : "Открыть встречу")) {
                            dismiss()
                            Task { await workspace.join(item.value) }
                        }.buttonStyle(MSButtonStyle())
                        if let url = invitation {
                            ShareLink(item: url) { Label(tr("Пригласить по ссылке"), systemImage: "link") }
                                .buttonStyle(MSButtonStyle(primary: false))
                        }
                        if item.mine {
                            Button(tr(finishTitle), role: .destructive) { confirmingFinish = true }
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.navigationTitle(tr(item.status == .past ? "Материалы встречи" : "О встрече")).msInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("Готово")) { dismiss() }.disabled(recordings?.loading == true)
                    }
                }
                .interactiveDismissDisabled(recordings?.loading == true)
                .confirmationDialog(tr(item.status == .active ? "Завершить встречу для всех участников?" : "Отменить встречу?"),
                                    isPresented: $confirmingFinish, titleVisibility: .visible) {
                    Button(tr(finishTitle), role: .destructive) {
                        dismiss()
                        Task { await workspace.finish(item.value) }
                    }
                }
        }
    }

    private var finishTitle: String { item.status == .active ? "Завершить встречу" : "Отменить встречу" }

    private var invitation: URL? {
        guard let code = try? ConferenceInviteGateway.inviteCode(from: item.value.inviteCode, origin: workspace.repository.origin) else { return nil }
        return workspace.repository.origin.url.appendingPathComponent("i").appendingPathComponent(code)
    }

    private func materials(_ model: RecordingsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.controlling { ProgressView() }
            if let error = model.error {
                Text(tr(error)).foregroundStyle(MSTheme.danger)
                Button(tr("Повторить")) { Task { await loadMaterials(model) } }
            } else if let rows = model.conferenceItems[item.id], rows.isEmpty {
                Text(tr(item.cancelled ? "Встреча была отменена. Записей и материалов нет." : "Встреча завершена без записи."))
                    .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
            }
            ForEach(model.conferenceItems[item.id] ?? []) { recording in
                Button {
                    Task {
                        await model.select(RecordingLibraryItem(conference: item.value, recording: recording))
                        if model.selected?.id == recording.id { openRecording() }
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr(RecordingMode(rawValue: recording.mode)?.title ?? recording.mode))
                            Text(calendarText(recording.createdAt, format: "d MMMM · HH:mm", zone: zone) + " · " + tr(recording.statusTitle))
                                .font(MSTheme.font(11))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }.buttonStyle(MSButtonStyle(primary: false))
            }
        }.disabled(model.loading || model.controlling)
            .task(id: item.id) { await loadMaterials(model) }
    }

    private func loadMaterials(_ model: RecordingsModel) async {
        model.error = nil
        await model.loadConference(item.id)
    }
}
