import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LiveFoldersView: View {
    @Bindable var model: FoldersModel
    let openConversation: (UUID) -> Void
    let openConference: (Conference) -> Void
    @State private var editing = false
    @State private var renaming: PersonalFolder?
    @State private var name = ""
    @State private var deleting: PersonalFolder?
    @State private var showingItems = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(tr("Личное пространство")).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
                Text(tr("Соберите встречи и чаты в удобные папки.")).foregroundStyle(MSTheme.muted)
                HStack {
                    Button { renaming = nil; name = ""; editing = true } label: { Label(tr("Создать папку"), systemImage: "folder.badge.plus") }
                        .buttonStyle(MSButtonStyle()).accessibilityIdentifier("createFolder")
                    Menu {
                        Button(tr("По алфавиту")) { Task { await model.alphabetize() } }
                        Button(tr("Обновить")) { Task { await model.load() } }
                    } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Порядок папок"))
                }.disabled(model.busy)
                if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger).accessibilityIdentifier("foldersError") }
                if model.state == .loading { ProgressView() }
                if model.state == .empty { Text(tr("Папок пока нет")).foregroundStyle(MSTheme.muted) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(model.folders) { folder in
                        HStack(spacing: 16) {
                            Button {
                                Task { await model.open(folder); showingItems = model.selected != nil }
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "folder").font(.system(size: 25)).foregroundStyle(MSTheme.accent)
                                        .frame(width: 48, height: 44).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(folder.name).font(MSTheme.font(15, weight: .semibold)).foregroundStyle(MSTheme.ink)
                                        Text("\(folder.conversationCount) \(tr("чатов")) · \(folder.conferenceCount) \(tr("встреч"))")
                                            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 78)
                            }.buttonStyle(.plain).accessibilityIdentifier("folder.\(folder.id.uuidString.lowercased())")
                            Menu {
                                Button(tr("Переименовать")) { renaming = folder; name = folder.name; editing = true }
                                Button(tr("Выше")) { Task { await model.move(folder, delta: -1) } }
                                    .disabled(model.folders.first?.id == folder.id)
                                Button(tr("Ниже")) { Task { await model.move(folder, delta: 1) } }
                                    .disabled(model.folders.last?.id == folder.id)
                                Button(tr("Удалить папку"), role: .destructive) { deleting = folder }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .accessibilityLabel(tr("Действия с папкой"))
                                .accessibilityIdentifier("folderMenu.\(folder.id.uuidString.lowercased())")
                        }.msCard(padding: 16).disabled(model.busy)
                    }
                }
                Label(tr("Папки видны только вам. Удаление папки не удаляет встречи и чаты."), systemImage: "lock")
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.background(MSTheme.background).accessibilityIdentifier("screen.liveFolders")
            .task { await model.load() }.refreshable { await model.load() }
            .navigationDestination(isPresented: $showingItems) {
                FolderContentsView(model: model, openConversation: openConversation, openConference: openConference)
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    Form {
                        TextField(tr("Название папки"), text: $name).accessibilityIdentifier("folderName")
                        if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                        Button(tr("Сохранить")) {
                            Task { if await model.save(name: name, renaming: renaming?.id) { editing = false } }
                        }.disabled((try? FolderValidation.text(name, maximum: 50, required: true)) == nil)
                            .accessibilityIdentifier("folderSave")
                    }.disabled(model.busy).navigationTitle(tr(renaming == nil ? "Создать папку" : "Переименовать"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Отмена")) { editing = false }.disabled(model.busy) } }
                        .interactiveDismissDisabled(model.busy)
                }
            }
            .confirmationDialog(tr("Удалить только папку? Встречи и чаты останутся."), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(tr("Удалить папку"), role: .destructive) {
                    if let deleting { Task { _ = await model.delete(deleting) } }; deleting = nil
                }
            }
    }
}

private struct FolderContentsView: View {
    @Bindable var model: FoldersModel
    let openConversation: (UUID) -> Void
    let openConference: (Conference) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(tr(model.candidates ? "Готово" : "Добавить в папку")) { Task { await model.setCandidates(!model.candidates) } }
                    .buttonStyle(MSButtonStyle(primary: !model.candidates)).accessibilityIdentifier("folderCandidates")
                Picker(tr("Тип содержимого"), selection: $model.filter) {
                    Text(tr("Все")).tag(FolderFilter.all)
                    Text(tr("Чаты")).tag(FolderFilter.conversation)
                    Text(tr("Встречи")).tag(FolderFilter.conference)
                }.pickerStyle(.segmented).onChange(of: model.filter) { Task { await model.loadItems() } }
                HStack {
                    SearchBox(text: $model.search, placeholder: "Поиск в папке")
                    Button(tr("Найти")) { Task { await model.loadItems() } }
                }.onSubmit { Task { await model.loadItems() } }
                if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if model.loadingItems { ProgressView() }
                if model.itemsState == .empty { Text(tr("Здесь пока пусто")).foregroundStyle(MSTheme.muted) }
                ForEach(model.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .conversation ? "bubble.left.and.bubble.right" : "video")
                            .foregroundStyle(MSTheme.accent).frame(width: 42, height: 42)
                        Button {
                            if let conversation = item.conversation { openConversation(conversation.id) }
                            if let conference = item.conference { openConference(conference) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).foregroundStyle(MSTheme.ink)
                                Text(tr(item.conference.map { conferenceStatus($0.status) } ?? "Чат"))
                                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(item.conference?.isClosed == true || model.candidates)
                        Button {
                            Task { await model.toggle(item) }
                        } label: {
                            Image(systemName: model.candidates ? (item.inFolder ? "checkmark.circle.fill" : "plus.circle") : "minus.circle")
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel(tr(model.candidates && !item.inFolder ? "Добавить в папку" : "Убрать из папки"))
                            .accessibilityIdentifier("folderItem.\(item.itemID.uuidString.lowercased())")
                    }.msCard(padding: 12)
                }
                if model.nextCursor != nil {
                    Button(tr("Показать ещё")) { Task { await model.loadItems(more: true) } }.disabled(model.loadingItems)
                }
                if model.itemsState == .failed { Button(tr("Повторить")) { Task { await model.loadItems() } } }
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity).disabled(model.busy)
        }.background(MSTheme.background).navigationTitle(model.selected?.name ?? tr("Папка"))
            .accessibilityIdentifier("screen.folderContents").refreshable { await model.loadItems() }
    }
}
