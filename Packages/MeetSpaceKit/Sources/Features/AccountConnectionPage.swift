import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct AccountConnectionPage: View {
    let app: AppModel
    let wide: Bool
    var openLicenses: (() -> Void)?
    @State private var draft = ""
    @State private var saved = false
    @State private var request: ServerOrigin?
    @State private var networkError: String?
    @State private var detailsVisible = false
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var textSize

    private var currentAddress: String {
        let server = app.isDemo ? app.demoProfile.server ?? app.configuration.server : app.identity.messaging?.account.server
        return server?.url.absoluteString ?? "https://meet.example.org"
    }

    private var origin: ServerOrigin? {
        guard draft.utf8.count <= 2048, !draft.contains(","), !draft.contains(";") else { return nil }
        return try? ServerOrigin(draft)
    }
    private var validationError: String? {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Укажите адрес сервера." }
        if origin == nil { return "Укажите HTTPS-адрес без логина, пути, параметров и фрагмента." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountDetailHeading(title: "Подключение", subtitle: "Адрес сервера вашего MeetSpace.")
                    .padding(.bottom, wide ? 32 : 30)
                ProfileField(label: "Адрес сервера") {
                    TextField("https://meet.example.org", text: $draft).msURLInput().textFieldStyle(.plain)
                        .profileInput().focused($focused).submitLabel(.done)
                        .disabled(request != nil)
                        .overlay {
                            if validationError != nil {
                                RoundedRectangle(cornerRadius: 11).strokeBorder(MSTheme.danger).allowsHitTesting(false)
                            }
                        }
                        .disabled(request != nil)
                        .accessibilityLabel(tr("Адрес сервера")).accessibilityIdentifier("accountConnectionAddress")
                        .onSubmit { focused = false }
                    if let error = validationError ?? networkError {
                        Text(tr(error)).font(MSTheme.font(12)).foregroundStyle(MSTheme.danger)
                            .accessibilityIdentifier("accountConnectionError")
                    }
                }
                saveRow.padding(.top, 26)
                HStack(alignment: .top, spacing: 9) {
                    WorkspaceIcon("info.circle", size: 16).accessibilityHidden(true)
                    Text(tr(app.isDemo ? "В деморежиме сохраняется только адрес. Подключение к серверу не выполняется."
                                       : "Для подключения к другому серверу потребуется войти в аккаунт на этом сервере."))
                        .font(MSTheme.font(12)).lineSpacing(3)
                }.foregroundStyle(MSTheme.muted).padding(.top, 24)
                if app.isDemo {
                    Button(tr("Подключиться к серверу")) {
                        let server = try? ServerOrigin(currentAddress)
                        app.leaveDemo()
                        app.show(.connect, server: server)
                    }.buttonStyle(MSTextButtonStyle()).font(MSTheme.font(12)).padding(.top, 12)
                } else if let settings = app.identity.settings {
                    serverDetails(settings).padding(.top, 12)
                }
            }.padding(.horizontal, wide ? 48 : 20).padding(.vertical, wide ? 36 : 18)
                .frame(maxWidth: 860).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(MSTheme.background).foregroundStyle(MSTheme.ink)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("accountSettingsScroll")
            .onAppear { draft = currentAddress }
            .onChange(of: draft) { _, value in
                if value != currentAddress { saved = false }
                networkError = nil
            }
            .task(id: request) {
                guard let request, let account = app.identity.messaging?.account else { return }
                await app.openLoginForServer(request, from: account)
                guard !Task.isCancelled else { return }
                networkError = app.connectionError?.message
                self.request = nil
            }
    }

    private var saveRow: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                                                   AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Button {
                guard let origin, origin.url.absoluteString != currentAddress else { return }
                focused = false
                if app.isDemo {
                    app.demoProfile.server = origin
                    draft = origin.url.absoluteString
                    saved = true
                } else {
                    networkError = nil
                    request = origin
                }
            } label: {
                Text(tr("Сохранить адрес")).padding(.horizontal, 6)
            }.buttonStyle(MSButtonStyle()).fixedSize(horizontal: true, vertical: false)
                .disabled(origin == nil || origin?.url.absoluteString == currentAddress || request != nil)
                .accessibilityIdentifier("accountConnectionSave")
            if request != nil {
                ProgressView(tr("Проверяем сервер…")).font(MSTheme.font(12))
            } else if saved {
                Label(tr("Адрес сохранён"), systemImage: "checkmark")
                    .font(MSTheme.font(12)).foregroundStyle(MSTheme.accent)
                    .accessibilityIdentifier("accountConnectionSaved")
            }
        }
    }

    private func serverDetails(_ model: SettingsModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                focused = false
                detailsVisible.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(tr("Сведения о сервере"))
                    WorkspaceIcon(detailsVisible ? "chevron.up" : "chevron.down", size: 12)
                }
            }.buttonStyle(MSTextButtonStyle()).font(MSTheme.font(12))
                .accessibilityValue(tr(detailsVisible ? "Развёрнуто" : "Свёрнуто"))
                .accessibilityIdentifier("accountConnectionDetails")
            if detailsVisible {
                if let error = model.capabilitiesError { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if let value = model.capabilities {
                    LabeledContent(tr("Версия сервера"), value: value.buildVersion)
                    LabeledContent(tr("Режимы записи"), value: value.recordingModes.isEmpty ? tr("Недоступны") : value.recordingModes.joined(separator: ", "))
                }
                if let integrations = model.integrations {
                    capabilityRow("Почтовый провайдер", value: integrations.email)
                    capabilityRow("Push-провайдер", value: integrations.push)
                    capabilityRow("Внешний календарь", value: integrations.calendar)
                }
                Text(tr("Возможности сообщает выбранный сервер. Они не подтверждают работоспособность внешней доставки или установку провайдера."))
                    .foregroundStyle(MSTheme.muted)
                Divider()
                Label(tr("Установка сервера по SSH"), systemImage: "terminal").font(MSTheme.font(15, weight: .semibold))
                Text(tr("Откройте мастер «Развернуть свой сервер» на первом экране."))
                    .foregroundStyle(MSTheme.muted).accessibilityIdentifier("installerAvailable")
                if model.busy { ProgressView().accessibilityIdentifier("settingsLoading") }
                Button(tr("Обновить настройки")) { Task { await model.load() } }
                    .buttonStyle(MSButtonStyle(primary: false)).disabled(model.busy)
                if let openLicenses {
                    AccountShortcutRow(title: "Лицензии компонентов", symbol: "doc.text", identifier: "openComponentLicenses", action: openLicenses)
                        .msCard(padding: 0)
                }
            }
        }.font(MSTheme.font(12))
    }

    private func capabilityRow(_ title: String, value: String) -> some View {
        let label = switch value {
        case "noop": "Не настроен"
        case "mock": "Тестовый режим"
        case "http": "Внешний шлюз"
        case "smtp": "SMTP"
        default: "Неизвестный режим"
        }
        return LabeledContent(tr(title), value: tr(label))
    }
}
