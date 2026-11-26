import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveRecordingsView: View {
    @Bindable var model: RecordingsModel
    let openRecording: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RecordingPage(title: "Записи встреч", onBack: { dismiss() }, error: model.error) {
            library
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .task { if model.items.isEmpty { await model.load() } }
        .refreshable { await model.load() }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordingLibraryContent(entries: model.visibleItems.map { RecordingLibraryEntry(row: $0, account: model.account) },
                                    demo: false, loading: model.loading, loadFailed: model.error != nil,
                                    moreAvailable: model.nextCursor != nil, open: { entry in
                if let id = UUID(uuidString: entry.id) { openRecording(id) }
            }, remove: { entry in
                if let row = model.items.first(where: { $0.id.uuidString == entry.id }) {
                    Task { await model.delete(row) }
                }
            })
            if model.nextCursor != nil {
                Button(tr("Загрузить ещё")) { Task { await model.load(more: true) } }
                    .buttonStyle(MSButtonStyle(primary: false)).disabled(model.loading)
            }
            RecordingListRetention(demo: false)
        }
    }
}
