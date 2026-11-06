import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI

@MainActor @Observable public final class FoldersModel {
    public private(set) var folders: [PersonalFolder] = []
    public private(set) var items: [PersonalFolderItem] = []
    public private(set) var selected: PersonalFolder?
    public private(set) var state: LoadState = .loading
    public private(set) var itemsState: LoadState = .loading
    public private(set) var busy = false
    public private(set) var loadingItems = false
    public private(set) var nextCursor: String?
    public private(set) var candidates = false
    public var filter: FolderFilter = .all
    public var search = ""
    public var error: String?
    private let repository: FoldersRepository
    private var epoch = UUID()
    private var pageEpoch = UUID()
    private var loadEpoch = UUID()
    private var closed = false
    public init(repository: FoldersRepository) { self.repository = repository }
    public func close() {
        closed = true; epoch = UUID(); pageEpoch = UUID(); loadEpoch = UUID()
        folders = []; items = []; selected = nil; error = nil; nextCursor = nil
        busy = false; loadingItems = false
    }
    public func load() async {
        guard !closed else { return }; loadEpoch = UUID(); let request = loadEpoch
        do {
            let result = try await repository.list()
            guard !closed, request == loadEpoch else { return }
            folders = result.sorted { $0.position < $1.position }
            state = folders.isEmpty ? .empty : .content; error = nil
            if let selected {
                self.selected = folders.first { $0.id == selected.id }
                if self.selected == nil { items = []; nextCursor = nil; pageEpoch = UUID(); loadingItems = false }
            }
        } catch {
            guard !closed, request == loadEpoch else { return }
            self.error = userMessage(error); state = folders.isEmpty ? .failed : .content
        }
    }
    public func open(_ folder: PersonalFolder) async {
        guard !busy, !closed else { return }
        selected = folder; filter = .all; search = ""; candidates = false
        await loadItems()
    }
    public func setCandidates(_ value: Bool) async {
        guard !busy, !closed else { return }; candidates = value; await loadItems()
    }
    public func loadItems(more: Bool = false) async {
        guard !closed, let selected, !more || (!loadingItems && nextCursor != nil) else { return }
        pageEpoch = UUID(); let request = pageEpoch
        let cursor = more ? nextCursor : nil
        if !more { items = []; nextCursor = nil; itemsState = .loading }
        loadingItems = true; error = nil
        do {
            let page = try await repository.items(selected.id, candidates: candidates, filter: filter, search: search, before: cursor)
            guard !closed, request == pageEpoch, self.selected?.id == selected.id else { return }
            let known = Set(items.map(\.id)); items += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor.flatMap { $0.isEmpty || $0 == cursor ? nil : $0 }
            itemsState = items.isEmpty ? .empty : .content; loadingItems = false
        } catch {
            guard !closed, request == pageEpoch else { return }
            self.error = userMessage(error); itemsState = items.isEmpty ? .failed : .content; loadingItems = false
        }
    }
    public func save(name: String, renaming: UUID? = nil) async -> Bool {
        await mutate {
            if let renaming { _ = try await self.repository.rename(renaming, name: name) }
            else { _ = try await self.repository.create(name: name) }
        }
    }
    public func delete(_ folder: PersonalFolder) async -> Bool {
        let wasSelected = selected?.id == folder.id
        let success = await mutate { try await self.repository.delete(folder.id) }
        if success, wasSelected { selected = nil; items = []; nextCursor = nil; pageEpoch = UUID() }
        return success
    }
    public func move(_ folder: PersonalFolder, delta: Int) async {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }), folders.indices.contains(index + delta) else { return }
        var ids = folders.map(\.id); ids.swapAt(index, index + delta)
        _ = await mutate { _ = try await self.repository.order(ids) }
    }
    public func alphabetize() async {
        let ids = folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
        _ = await mutate { _ = try await self.repository.order(ids) }
    }
    public func toggle(_ item: PersonalFolderItem) async {
        guard let selected else { return }
        let included = candidates ? !item.inFolder : false
        if await mutate({ _ = try await self.repository.setItem(selected.id, kind: item.kind, id: item.itemID, included: included) }) {
            await loadItems()
        }
    }
    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        guard !busy, !closed else { return false }; busy = true; error = nil
        pageEpoch = UUID(); loadingItems = false
        let current = epoch
        do {
            try await operation(); guard !closed, current == epoch else { return false }
            await load(); guard !closed, current == epoch else { return false }
            busy = false; return true
        } catch {
            guard !closed, current == epoch else { return false }
            busy = false; self.error = userMessage(error); return false
        }
    }
}
