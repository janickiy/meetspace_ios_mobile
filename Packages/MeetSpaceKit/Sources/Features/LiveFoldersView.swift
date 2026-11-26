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
        FolderOverview {
            HStack {
                Button { renaming = nil; name = ""; editing = true } label: { Label(tr("Создать папку"), systemImage: "plus") }
                    .buttonStyle(MSButtonStyle()).accessibilityIdentifier("createFolder")
                Menu {
                    Button(tr("По алфавиту")) { Task { await model.alphabetize() } }
                    Button(tr("Обновить")) { Task { await model.load() } }
                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }
                    .accessibilityLabel(tr("Порядок папок"))
            }.disabled(model.busy)
        } content: { wide in
            if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger).accessibilityIdentifier("foldersError") }
            if model.state == .loading { ProgressView() }
            if model.state == .empty { Text(tr("Папок пока нет")).foregroundStyle(MSTheme.muted) }
            FolderGrid(wide: wide) {
                ForEach(model.folders) { folder in
                    FolderOverviewCard(name: folder.name, count: folder.itemCount, chats: folder.conversationCount,
                                       meetings: folder.conferenceCount, wide: wide, identifier: "folder." + folder.id.uuidString.lowercased()) {
                        Task { await model.open(folder); showingItems = model.selected != nil }
                    } accessory: {
                        Menu {
                            Button(tr("Переименовать")) { renaming = folder; name = folder.name; editing = true }
                            Button(tr("Выше")) { Task { await model.move(folder, delta: -1) } }
                                .disabled(model.folders.first?.id == folder.id)
                            Button(tr("Ниже")) { Task { await model.move(folder, delta: 1) } }
                                .disabled(model.folders.last?.id == folder.id)
                            Button(tr("Удалить папку"), role: .destructive) { deleting = folder }
                        } label: { WorkspaceIcon("ellipsis", size: 20).frame(width: 44, height: 44) }
                            .accessibilityLabel(tr("Действия с папкой")).accessibilityValue(folder.name)
                            .accessibilityIdentifier("folderMenu." + folder.id.uuidString.lowercased())
                    }.disabled(model.busy)
                }
            }
            Label(tr("Папки видны только вам. Удаление папки не удаляет встречи и чаты."), systemImage: "lock")
                .font(MSTheme.font(wide ? 12 : 11)).foregroundStyle(MSTheme.muted)
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
                        .toolbar { ToolbarItem(placement: .cancellationAction) { MSLiquidAction(.cancel, inToolbar: true) { editing = false }.disabled(model.busy) } }
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

struct FolderOverview<Actions: View, Content: View>: View {
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.workspaceWidth) private var width
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wide = width >= 700 && !typeSize.isAccessibilitySize
        let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 20))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        ScrollView {
            VStack(alignment: .leading, spacing: wide ? 24 : 20) {
                layout {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("ЛИЧНОЕ ПРОСТРАНСТВО")).font(MSTheme.font(10, weight: .semibold)).tracking(1.6)
                            .foregroundStyle(MSTheme.accent).accessibilityIdentifier("folders.subtitle")
                        Text(tr("Всё нужное — вместе")).font(MSTheme.font(wide ? 27 : 22, weight: .semibold, relativeTo: .title2))
                            .accessibilityAddTraits(.isHeader)
                        Text(tr("Соберите встречи и чаты по проектам.")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    actions().fixedSize(horizontal: wide, vertical: false)
                }
                content(wide)
            }.frame(maxWidth: 1050, alignment: .leading)
                .padding(.horizontal, width >= 780 ? 48 : wide ? 24 : 16)
                .padding(.vertical, wide ? 32 : 16).frame(maxWidth: .infinity)
        }.background(MSTheme.background).foregroundStyle(MSTheme.ink)
    }
}

struct FolderGrid<Cards: View>: View {
    let wide: Bool
    @ViewBuilder let cards: () -> Cards
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: wide ? 3 : 1),
                  spacing: wide ? 16 : 12, content: cards)
    }
}

struct FolderOverviewCard<Accessory: View>: View {
    let name: String
    let count: Int
    let chats: Int
    let meetings: Int
    let wide: Bool
    let identifier: String
    let open: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        let layout = wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(spacing: 16))
        Button(action: open) {
            layout {
                WorkspaceIcon("folder", size: 25).foregroundStyle(MSTheme.accent)
                    .frame(width: 48, height: 44).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: name).font(MSTheme.font(wide ? 16 : 15, weight: .semibold))
                    Text(verbatim: counts).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }.padding(.leading, wide ? 20 : 16).padding(.trailing, wide ? 20 : 60).padding(.vertical, wide ? 24 : 16)
                .frame(maxWidth: .infinity, minHeight: wide ? 172 : 116, alignment: wide ? .topLeading : .leading)
                .contentShape(Rectangle()).accessibilityElement(children: .combine)
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(MSTheme.line) }
            .overlay(alignment: wide ? .topTrailing : .trailing) { accessory().padding(.trailing, 10).padding(.top, wide ? 13 : 0) }
    }

    private var counts: String {
        [quantity(count, "элемент", "элемента", "элементов"),
         quantity(chats, "чат", "чата", "чатов"),
         quantity(meetings, "встреча", "встречи", "встреч")].joined(separator: " · ")
    }

    /// Подбирает русскую форму существительного и объединяет её с числом элементов.
    /// - Parameters:
    ///   - number: Количество элементов.
    ///   - one: Форма для единицы.
    ///   - few: Форма для двух–четырёх.
    ///   - many: Форма для пяти и более.
    private func quantity(_ number: Int, _ one: String, _ few: String, _ many: String) -> String {
        let form: String = switch (number % 100, number % 10) {
        case (11...14, _): many
        case (_, 1): one
        case (_, 2...4): few
        default: many
        }
        return "\(number) " + tr(form)
    }
}

private struct FolderContentsView: View {
    @Bindable var model: FoldersModel
    let openConversation: (UUID) -> Void
    let openConference: (Conference) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(tr("Тип содержимого"), selection: $model.filter) {
                    Text(tr("Все")).tag(FolderFilter.all)
                    Text(tr("Чаты")).tag(FolderFilter.conversation)
                    Text(tr("Встречи")).tag(FolderFilter.conference)
                }.pickerStyle(.segmented).onChange(of: model.filter) { Task { await model.loadItems() } }
                HStack {
                    SearchBox(text: $model.search, placeholder: "Поиск в папке", onSubmit: { Task { await model.loadItems() } })
                    Button(tr("Найти")) { Task { await model.loadItems() } }
                }
                if let error = model.error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if model.loadingItems { ProgressView() }
                if model.itemsState == .empty { Text(tr("Здесь пока пусто")).foregroundStyle(MSTheme.muted) }
                ForEach(model.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .conversation ? "bubble.left.and.bubble.right" : "video")
                            .foregroundStyle(MSTheme.accent).frame(width: 42, height: 42).accessibilityHidden(true)
                        Button {
                            if let conversation = item.conversation { openConversation(conversation.id) }
                            if let conference = item.conference { openConference(conference) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).foregroundStyle(MSTheme.ink)
                                Text(tr(item.conference.map { conferenceStatus($0.status) } ?? "Чат"))
                                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle()).accessibilityElement(children: .combine)
                        }.buttonStyle(.plain).disabled(item.conference?.isClosed == true)
                        Button {
                            Task { await model.remove(item) }
                        } label: {
                            Image(systemName: "minus.circle").frame(width: 44, height: 44)
                        }.accessibilityLabel(tr("Убрать из папки"))
                            .accessibilityValue(item.title)
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
