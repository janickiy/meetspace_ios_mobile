import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct ConferenceRecordingSheet: View {
    @Bindable var session: ConferenceSession
    @Bindable var model: RecordingsModel
    @State private var conference: Conference?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if session.phase != .connected {
                        Text(tr("Запись недоступна для текущего состояния встречи."))
                    } else if let conference {
                        ConferenceRecordingControls(model: model, conference: conference, participant: session.participant)
                    } else if let error {
                        Text(tr(error)).foregroundStyle(MSTheme.danger)
                        Button(tr("Повторить")) { Task { await load() } }
                    } else { ProgressView() }
                }.padding(24)
            }.navigationTitle(tr("Запись встречи")).msInlineTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Готово")) { dismiss() } } }
                .task(id: session.phase) { await load() }
        }
    }
    private func load() async {
        guard session.phase == .connected else { conference = nil; return }
        do {
            let result = try await session.repository.read(session.conferenceID)
            guard !Task.isCancelled, session.phase == .connected else { return }
            conference = result; error = nil
        } catch { if !Task.isCancelled { self.error = userMessage(error) } }
    }
}
