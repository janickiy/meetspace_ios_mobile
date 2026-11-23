import SwiftUI
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceDesignSystem

struct LiveMeetingDetails: View {
    let item: MeetingListItem<Conference>
    let zone: TimeZone
    let workspace: ConferenceWorkspace
    let recordings: RecordingsModel?
    let folders: FoldersModel?
    let openRecording: (UUID) -> Void
    let openCall: () -> Void
    let close: () -> Void
    @State var showingMaterials: Bool
    @State private var showingFolders = false
    @State private var participant: ConferenceParticipant?
    @State private var loadingMembership = true
    @State private var membershipError: String?
    @State private var transitionError: String?

    var body: some View {
        Group {
            if showingMaterials, let recordings {
                WorkspaceFormSheet(title: "Материалы встречи", identifier: "meetingMaterials", centered: true, close: close) {
                    Button(tr("О встрече")) { showingMaterials = false }
                    Text(verbatim: item.title).font(MSTheme.font(18, weight: .semibold))
                    materials(recordings)
                }
            } else {
                MeetingActionCard(item: item, scheduled: item.value.scheduledAt, started: item.value.startedAt,
                    finished: item.value.finishedAt, zone: zone, waitingRoom: item.value.waitingRoomEnabled,
                    membership: MeetingMembership(participant), loadingMembership: loadingMembership && !item.value.isClosed,
                    busy: workspace.busy, membershipFailed: membershipError != nil, error: membershipError ?? transitionError,
                    retry: membershipError == nil ? nil : { Task { await loadMembership() } },
                    invitation: .live(item.value, workspace.repository), cohostCanInvite: item.status == .active && participant?.canAdmit == true,
                    call: openCall, toggleMembership: { Task { await toggleMembership() } },
                    folder: folders == nil ? nil : { showingFolders = true },
                    materials: recordings == nil ? nil : { showingMaterials = true }, finish: {
                        Task {
                            if await workspace.finish(item.value) { close() }
                            else { transitionError = workspace.error }
                        }
                    }, close: close)
                    .task(id: item.id) { if !item.value.isClosed { await loadMembership() } }
            }
        }.sheet(isPresented: $showingFolders) {
            if let folders { WorkspaceFolderPicker(model: folders, kind: .conference, id: item.id, title: item.title) }
        }
    }

    private func loadMembership() async {
        loadingMembership = true
        transitionError = nil
        defer { loadingMembership = false }
        do {
            let value = try await workspace.repository.selfParticipant(item.id)
            if !Task.isCancelled { participant = value; membershipError = nil }
        } catch APIError.httpStatus(404) {
            if !Task.isCancelled { participant = nil; membershipError = nil }
        } catch {
            if !Task.isCancelled { participant = nil; membershipError = userMessage(error) }
        }
    }

    private func toggleMembership() async {
        guard !loadingMembership, !workspace.busy else { return }
        do {
            participant = try await workspace.updateMembership(in: item.value, leave: participant?.canParticipate == true || participant?.isWaiting == true)
            membershipError = nil
        } catch { membershipError = userMessage(error) }
    }

    private func materials(_ model: RecordingsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.controlling { ProgressView() }
            if let error = model.error {
                Text(tr(error)).foregroundStyle(MSTheme.danger)
                Button(tr("Повторить")) { Task { await loadMaterials(model) } }
            } else if let rows = model.conferenceItems[item.id], rows.isEmpty {
                Text(tr(item.cancelled ? "Встреча была отменена. Записей и материалов нет." : item.value.isClosed ? "Встреча завершена без записи." : "Для этой встречи пока нет записей."))
                    .font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
            }
            ForEach(model.conferenceItems[item.id] ?? []) { recording in
                Button {
                    Task {
                        await model.select(RecordingLibraryItem(conference: item.value, recording: recording))
                        if model.selected?.id == recording.id { openRecording(recording.id) }
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
