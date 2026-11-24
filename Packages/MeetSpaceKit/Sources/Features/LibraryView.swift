import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LibraryView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @State private var query: String = ""
    @State private var editingFolder = false
    @State private var renamedFolder: UUID?
    @State private var deletedFolder: UUID?
    @State private var name = ""
    @State private var folderError: String?
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
            FolderOverview {
                Button { editFolder(nil) } label: { Label(tr("Новая папка"), systemImage: "plus") }
                    .buttonStyle(MSButtonStyle())
            } content: { wide in
                SearchBox(text: $query, placeholder: "Поиск папок").frame(maxWidth: wide ? 300 : .infinity)
                if let folderError { Text(tr(folderError)).foregroundStyle(MSTheme.danger) }
                FolderGrid(wide: wide) {
                    ForEach(model.demoFolders.folders.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { folder in
                        let chats = folder.items.filter { if case .chat = $0 { true } else { false } }.count
                        FolderOverviewCard(name: folder.name, count: folder.items.count, chats: chats,
                                           meetings: folder.items.count - chats, wide: wide, identifier: "folder." + folder.id.uuidString.lowercased()) {
                            model.navigate(.demoFolder(folder.id))
                        } accessory: {
                            Menu {
                                Button(tr("Переименовать")) { editFolder(folder) }
                                Button(tr("Удалить папку"), role: .destructive) { deletedFolder = folder.id }
                            } label: { WorkspaceIcon("ellipsis", size: 20).frame(width: 44, height: 44) }
                                .accessibilityLabel(tr("Действия с папкой")).accessibilityValue(folder.name)
                        }
                    }
                }
                Label(tr("Папки видны только вам. Чаты и встречи могут находиться сразу в нескольких папках."), systemImage: "lock")
                    .font(MSTheme.font(wide ? 12 : 11)).foregroundStyle(MSTheme.muted)
            }
            .alert(tr(renamedFolder == nil ? "Создать папку" : "Переименовать"), isPresented: $editingFolder) {
                TextField(tr("Название папки"), text: $name)
                Button(tr("Отмена"), role: .cancel) { }
                Button(tr("Сохранить")) {
                    do { try model.demoFolders.save(name, renaming: renamedFolder); query = ""; folderError = nil }
                    catch { folderError = userMessage(error) }
                }.disabled((try? FolderValidation.text(name, maximum: 50, required: true)) == nil)
            }
            .confirmationDialog(tr("Удалить только папку? Встречи и чаты останутся."), isPresented: Binding(
                get: { deletedFolder != nil }, set: { if !$0 { deletedFolder = nil } }
            ), presenting: deletedFolder) { id in
                Button(tr("Удалить папку"), role: .destructive) { model.demoFolders.deleteFolder(id) }
                Button(tr("Отмена"), role: .cancel) { }
            }
        }
    }

    private func editFolder(_ folder: DemoFolderStore.Folder?) {
        renamedFolder = folder?.id
        name = folder?.name ?? ""
        editingFolder = true
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
}
