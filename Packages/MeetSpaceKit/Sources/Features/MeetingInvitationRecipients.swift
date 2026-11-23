import SwiftUI
import MeetSpaceAPI
import MeetSpaceDesignSystem

private struct InvitationRecipient: Identifiable {
    var userID: UUID?
    let email: String
    var name: String?
    var id: String { email.lowercased() }
}

struct MeetingInvitationRecipients: View {
    let invitation: MeetingLinkInvitation
    let close: () -> Void
    @State private var query = ""
    @State private var results: [InvitationRecipient] = []
    @State private var searched = ""
    @State private var selected: [InvitationRecipient] = []
    @State private var searchError: String?
    @State private var sending = false
    @State private var sendingError: String?
    @State private var status: String?

    private var input: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var candidates: [InvitationRecipient] {
        var matches = searched == input ? results : []
        if input.utf8.count <= 254, input.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
           !matches.contains(where: { $0.id == input.lowercased() }) {
            matches.append(InvitationRecipient(email: input))
        }
        return matches.filter { match in !selected.contains(where: { $0.id == match.id }) }
    }

    var body: some View {
        WorkspaceFormSheet(title: "Пригласить участников", identifier: "meetingInvitePeople", busy: sending, close: close) {
            Text(tr("Найдите коллегу или укажите email для приглашения.")).foregroundStyle(MSTheme.muted)
            WorkspaceFormField(title: "Имя или email") {
                TextField(tr("Например, Мария"), text: $query).msEmailInput().textFieldStyle(.plain).workspaceFormInput()
                    .accessibilityIdentifier("meetingInvitePeople.query")
            }
            ForEach(candidates) { person in
                Button {
                    selected.append(person)
                    query = ""
                    sendingError = nil
                    status = nil
                } label: { recipientRow(person, icon: "plus") }.buttonStyle(.plain).disabled(selected.count >= 20)
            }
            if let searchError, searched == input {
                Text(tr(searchError)).foregroundStyle(MSTheme.danger)
            } else if !input.isEmpty && input == searched && candidates.isEmpty {
                Text(tr("Нет совпадений. Введите полный email.")).foregroundStyle(MSTheme.muted)
            }
            ForEach(selected) { person in
                Button { selected.removeAll { $0.id == person.id } } label: {
                    recipientRow(person, icon: "xmark")
                }.buttonStyle(.plain).accessibilityLabel(tr("Убрать") + " " + person.email)
            }
            if let sendingError { Text(tr(sendingError)).foregroundStyle(MSTheme.danger) }
            if let status { Text(tr(status)).foregroundStyle(MSTheme.muted) }
            Button(tr("Пригласить")) { Task { await send() } }
                .buttonStyle(MSButtonStyle()).disabled(selected.isEmpty || sending)
                .accessibilityIdentifier("meetingInvitePeople.submit")
        }.task(id: input) { await search(input) }
    }

    private func recipientRow(_ person: InvitationRecipient, icon: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let name = person.name, !name.isEmpty { Text(verbatim: name).font(MSTheme.font(14, weight: .semibold)) }
                Text(verbatim: person.email).font(MSTheme.font(13))
            }
            Spacer()
            WorkspaceIcon(icon, size: 16)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
            .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func search(_ text: String) async {
        guard (2...100).contains(text.unicodeScalars.count) else { searched = ""; results = []; searchError = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let users: [InvitationRecipient]
            switch invitation {
            case let .live(meeting, repository):
                users = try await repository.invitationUsers(meeting.id, query: text).map {
                    InvitationRecipient(userID: $0.id, email: $0.email, name: $0.displayName)
                }
            case .demo:
                users = [InvitationRecipient(email: "anna@example.org", name: "Анна Кузнецова"),
                         InvitationRecipient(email: "max@example.org", name: "Максим Петров")]
                    .filter { $0.email.localizedCaseInsensitiveContains(text) || $0.name?.localizedCaseInsensitiveContains(text) == true }
            }
            try Task.checkCancellation()
            guard input == text else { return }
            results = users; searched = text; searchError = nil
        } catch {
            if !Task.isCancelled && input == text { results = []; searched = text; searchError = userMessage(error) }
        }
    }

    private func send() async {
        guard !sending, !selected.isEmpty else { return }
        sending = true
        sendingError = nil
        status = nil
        defer { sending = false }
        do {
            switch invitation {
            case let .live(meeting, repository):
                let receipt = try await repository.invite(meeting.id, emails: selected.filter { $0.userID == nil }.map(\.email),
                                                          userIDs: selected.compactMap(\.userID))
                let accepted = Set(receipt.filter { ["queued", "sent", "already_invited"].contains($0.status) }.map { $0.email.lowercased() })
                selected.removeAll { accepted.contains($0.id) }
                if selected.isEmpty { status = "Сервер принял приглашения." }
                else { sendingError = "Сервер не принял приглашения для оставшихся получателей." }
            case .demo:
                selected = []
                status = "Демонстрационный режим. Приглашения не отправляются."
            }
        } catch { sendingError = userMessage(error) }
    }
}
