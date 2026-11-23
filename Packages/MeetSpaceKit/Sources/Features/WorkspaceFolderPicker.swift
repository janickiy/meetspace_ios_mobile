import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

@MainActor @Observable final class DemoFolderStore {
    enum Item: Hashable { case chat(Int), meeting(Int) }
    struct Folder: Identifiable {
        let id = UUID()
        let name: String
        var items: [Item]
    }
    private(set) var folders = [
        Folder(name: "Команда продукта", items: [.chat(1), .meeting(1), .chat(0), .meeting(5)]),
        Folder(name: "Запуск продукта", items: [.chat(3), .meeting(2)]),
        Folder(name: "Личное", items: [.chat(2)])
    ]

    func create(_ name: String) throws {
        let name = try FolderValidation.text(name, maximum: 50, required: true)
        guard folders.count < 100, !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { throw ClientError.invalidInput }
        folders.append(Folder(name: name, items: []))
    }

    func set(_ item: Item, in folder: UUID, included: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder }) else { return }
        if included {
            if !folders[index].items.contains(item) { folders[index].items.append(item) }
        } else {
            folders[index].items.removeAll { $0 == item }
        }
    }

    func remove(_ item: Item) {
        for index in folders.indices { folders[index].items.removeAll { $0 == item } }
    }
}

struct WorkspaceFolderPicker: View {
    private enum Source {
        case live(FoldersModel, FolderItemKind, UUID)
        case demo(DemoFolderStore, DemoFolderStore.Item)
    }
    private struct Choice: Identifiable {
        let id: UUID
        let name: String
        var included: Bool
    }
    private let source: Source
    private let title: String
    @State private var choices: [Choice] = []
    @State private var changes: [UUID: Bool] = [:]
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    init(model: FoldersModel, kind: FolderItemKind, id: UUID, title: String) {
        self.source = .live(model, kind, id)
        self.title = title
    }
    init(demo: DemoFolderStore, item: DemoFolderStore.Item, title: String) {
        self.source = .demo(demo, item)
        self.title = title
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: title).foregroundStyle(MSTheme.muted)
                    if busy { ProgressView() }
                    if let error { Text(verbatim: error).foregroundStyle(MSTheme.danger) }
                    if loaded {
                        if choices.isEmpty { Text(tr("Создайте папку для этого элемента.")) }
                        ForEach(choices) { choice in
                            let selected = changes[choice.id] ?? choice.included
                            Button {
                                changes[choice.id] = selected == choice.included ? !selected : nil
                            } label: {
                                HStack {
                                    WorkspaceIcon("folder", size: 19)
                                    Text(verbatim: choice.name)
                                    Spacer()
                                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("folderAssignment.option." + choice.id.uuidString)
                        }
                        if creating {
                            TextField(tr("Название папки"), text: $name).workspaceFormInput()
                                .accessibilityIdentifier("folderAssignment.name")
                            HStack {
                                Button(tr("Отмена")) { creating = false }.buttonStyle(MSTextButtonStyle())
                                Button(tr("Создать")) { Task { await create() } }
                                    .buttonStyle(MSButtonStyle(primary: false))
                                    .disabled((try? FolderValidation.text(name, maximum: 50, required: true)) == nil)
                            }
                        } else {
                            Button(tr("Новая папка")) { name = ""; creating = true }
                                .buttonStyle(MSButtonStyle(primary: false))
                                .accessibilityIdentifier("folderAssignment.new")
                        }
                        Button(tr("Сохранить")) { Task { await save() } }
                            .buttonStyle(MSButtonStyle()).disabled(changes.isEmpty || creating)
                            .accessibilityIdentifier("folderAssignment.save")
                    } else if !busy {
                        Button(tr("Повторить")) { Task { await load() } }.buttonStyle(MSTextButtonStyle())
                    }
                }.padding(20).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }.navigationTitle(tr("Добавить в папку")).msInlineTitle()
                .foregroundStyle(MSTheme.ink)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("Закрыть")) { dismiss() }.accessibilityIdentifier("folderAssignment.close")
                    }
                }
        }.disabled(busy).interactiveDismissDisabled(busy).task { await load() }
    }

    private func refreshChoices() async throws {
        switch source {
        case let .live(model, kind, id):
            choices = try await model.assignments(for: kind, id: id).map {
                Choice(id: $0.id, name: $0.name, included: $0.contains == true)
            }
        case let .demo(store, item):
            choices = store.folders.map { Choice(id: $0.id, name: $0.name, included: $0.items.contains(item)) }
        }
        changes = changes.filter { id, desired in choices.contains { $0.id == id && $0.included != desired } }
        loaded = true
    }

    private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await refreshChoices() }
        catch { self.error = tr(userMessage(error)) }
    }

    private func create() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            switch source {
            case let .live(model, _, _):
                guard await model.save(name: name) else { error = tr(model.error ?? "Не удалось создать папку."); return }
            case let .demo(store, _): try store.create(name)
            }
            creating = false
            loaded = false
            try await refreshChoices()
        } catch { self.error = tr(userMessage(error)) }
    }

    private func save() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            for index in choices.indices {
                let choice = choices[index]
                guard let desired = changes[choice.id] else { continue }
                switch source {
                case let .live(model, kind, id):
                    try await model.setAssignment(folder: choice.id, kind: kind, id: id, included: desired)
                case let .demo(store, item):
                    store.set(item, in: choice.id, included: desired)
                }
                choices[index].included = desired
                changes.removeValue(forKey: choice.id)
            }
            dismiss()
        } catch { self.error = tr(userMessage(error)) }
    }
}
