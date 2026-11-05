import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct MessagesView: View {
    @Bindable var model: AppModel
    @State private var query: String = ""
    @State private var selected: Int = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !typeSize.isAccessibilitySize
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PageHeader(title: "Чаты") {
                        IconButton("square.and.pencil", label: "Новый чат") { model.notice = "Новые чаты станут доступны после входа." }
                    }
                    SearchBox(text: $query, placeholder: "Поиск сообщений").padding(20)
                    ScrollView {
                        StateContent(state: model.contentState, retry: { model.contentState = .content }) {
                            VStack(spacing: 4) {
                                ForEach(DemoData.people.indices, id: \.self) { index in
                                    let person = DemoData.people[index]
                                    if query.isEmpty || tr(person.0).localizedCaseInsensitiveContains(query) {
                                        Button {
                                            selected = index
                                            if !wide { model.navigate(.thread(index)) }
                                        } label: {
                                            HStack(spacing: 12) {
                                                Avatar(person.1)
                                                VStack(alignment: .leading, spacing: 7) {
                                                    Text(tr(person.0)).font(MSTheme.font(13, weight: .semibold))
                                                    Text(tr(person.2)).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).lineLimit(2)
                                                }
                                                Spacer(minLength: 0)
                                                Text("12:30").font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                                            }.padding(14).background(wide && selected == index ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                        }.buttonStyle(.plain).accessibilityIdentifier("chat.\(index)")
                                    }
                                }
                            }.padding(.horizontal, 16)
                        }
                    }
                }.frame(width: wide ? 340 : nil)
                if wide {
                    Rectangle().fill(MSTheme.line).frame(width: 1)
                    ThreadView(model: model, personIndex: selected).frame(maxWidth: .infinity)
                }
            }.background(MSTheme.background)
        }.toolbar(.hidden).accessibilityIdentifier("screen.messages")
    }
}

struct ThreadView: View {
    @Bindable var model: AppModel
    var personIndex = 0
    @State private var draft: String = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Avatar(DemoData.people[personIndex].1, size: 36)
                Text(tr(DemoData.people[personIndex].0)).font(MSTheme.font(14, weight: .semibold))
                Spacer(minLength: 0)
                IconButton("phone", label: "Личный звонок") { model.navigate(.personalCall) }
            }.padding(16).background(MSTheme.surface)
            ScrollView {
                VStack(spacing: 18) {
                    Text(tr("Сегодня")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    bubble("Доброе утро! Материалы к встрече готовы. Посмотрите, когда будет минутка.", outgoing: false)
                    bubble("Спасибо! Посмотрю перед встречей. Есть пара идей по навигации.", outgoing: true)
                    bubble("Встречаемся в 10:00. Обсудим новую версию и планы команды.", outgoing: false)
                    FeatureNotice("Сообщения в демо не отправляются. История здесь — пример из макетов.")
                }.padding(20)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Image(systemName: "paperclip").foregroundStyle(MSTheme.muted).accessibilityHidden(true)
                TextField(tr("Сообщение"), text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain)
                    .accessibilityIdentifier("messageDraft")
                Button { model.notice = "Сообщения в демо не отправляются. История здесь — пример из макетов." } label: {
                    Image(systemName: "arrow.up").frame(width: 44, height: 44).foregroundStyle(MSTheme.surface)
                        .background(MSTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel(tr("Отправить сообщение")).disabled(draft.isEmpty)
            }.padding(16).background(MSTheme.surface)
        }.background(MSTheme.background).navigationTitle(tr("Чат")).msInlineTitle().accessibilityIdentifier("screen.thread")
    }
    private func bubble(_ message: String, outgoing: Bool) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 30) }
            VStack(alignment: .trailing, spacing: 6) {
                Text(tr(message)).frame(maxWidth: .infinity, alignment: .leading)
                Text("12:30").font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
            }.padding(14).frame(maxWidth: 400).background(outgoing ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            if !outgoing { Spacer(minLength: 30) }
        }
    }
}
