import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LibraryView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @State private var query: String = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch route {
        case .recording(let index):
            RecordingPage(title: "Просмотр записи", onBack: { dismiss() }) {
                if let entry = model.demoRecording(at: index) {
                    RecordingDetailContent(entry: entry, onAllRecordings: allRecordings)
                } else {
                    ContentUnavailableView(tr("Запись недоступна"), systemImage: "film")
                    Button(tr("Все записи"), action: allRecordings).buttonStyle(MSTextButtonStyle())
                }
            }
        case .recordings:
            RecordingPage(title: "Записи встреч", onBack: { dismiss() }) { recordingsLibrary }
        case .demoFolder(let id):
            if let folder = model.demoFolders.folders.first(where: { $0.id == id }) {
                List {
                    ForEach(folder.items, id: \.self) { item in
                        switch item {
                        case .chat(let index):
                            if let chat = model.demoChats.visibleContacts.first(where: { $0.id == index }) {
                                Button { model.navigate(.thread(index)) } label: { Label(chat.name, systemImage: "bubble.left") }
                            }
                        case .meeting(let index):
                            if let meeting = model.demoMeetings.meetings.first(where: { $0.id == index }) {
                                Button { model.navigate(.meetingDetails(index)) } label: { Label(tr(meeting.title), systemImage: "video") }
                            }
                        }
                    }
                }.overlay { if folder.items.isEmpty { Text(tr("Папка пока пуста")).foregroundStyle(MSTheme.muted) } }
                    .navigationTitle(Text(verbatim: folder.name))
            }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    libraryHeading("ЛИЧНОЕ ПРОСТРАНСТВО", title: "Всё нужное — вместе", subtitle: "Соберите встречи и чаты по проектам.")
                    SearchBox(text: $query, placeholder: "Поиск папок")
                    ForEach(model.demoFolders.folders.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { folder in
                        Button { model.navigate(.demoFolder(folder.id)) } label: {
                            HStack(spacing: 16) {
                                WorkspaceIcon("folder", size: 25).foregroundStyle(MSTheme.accent)
                                    .frame(width: 48, height: 44)
                                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                                Text(verbatim: folder.name).font(MSTheme.font(15, weight: .semibold)); Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(MSTheme.muted)
                            }.frame(minHeight: 84).msCard().contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    FeatureNotice("Папки видны только вам. Чаты и встречи могут находиться сразу в нескольких папках.")
                }.padding(.horizontal, sizeClass == .compact ? 16 : 24).padding(.vertical, 16)
                    .frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }.background(MSTheme.background)
        }
    }
    private var recordingsLibrary: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordingLibraryContent(entries: model.demoRecordings, demo: true, open: { entry in
                if let index = Int(entry.id) { model.navigate(.recording(index)) }
            }, remove: { entry in
                if let index = Int(entry.id) { model.deleteDemoRecording(at: index) }
            })
            RecordingListRetention(demo: true)
        }
    }

    private func allRecordings() {
        let path: ReferenceWritableKeyPath<AppModel, [AppRoute]> = switch model.tab {
        case .meetings: \.meetingsPath
        case .messages: \.messagesPath
        case .profile: \.profilePath
        }
        let previous = model[keyPath: path].dropLast()
        if previous.last == .recordings { dismiss() }
        else { model[keyPath: path] = Array(previous) + [.recordings] }
    }
    private func libraryHeading(_ label: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(tr(label)).font(MSTheme.font(10, weight: .semibold)).tracking(1.2).foregroundStyle(MSTheme.accent)
            Text(tr(title)).font(MSTheme.font(24, weight: .semibold, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
            Text(tr(subtitle)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }
    }
}
