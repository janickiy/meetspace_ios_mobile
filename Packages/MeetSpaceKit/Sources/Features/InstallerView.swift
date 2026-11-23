import SwiftUI
import UniformTypeIdentifiers
import MeetSpaceInstaller
import MeetSpaceDesignSystem

struct InstallerView: View {
    @Bindable var app: AppModel
    @State private var model = InstallerModel()
    @State private var importing = false
    @State private var confirmStop = false
    @State private var confirmForget = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var kickerLeading: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var subtitleLeading: CGFloat = 7
    @ScaledMetric(relativeTo: .callout) private var noteLeading: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var labelLeading: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 1000 && !typeSize.isAccessibilitySize
            HStack(spacing: 0) {
                if wide { OnboardingAside(install: true).frame(width: geometry.size.width * 0.30) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        wizardHeader(wide: wide)
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(MSTheme.font(14)).foregroundStyle(MSTheme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(MSTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("installer.error")
                        }
                        if model.busy {
                            sectionCard {
                                HStack(spacing: 12) { ProgressView(); Text("Проверяем состояние сервера…") }
                                Button("Отменить проверку") { model.cancelLocalOperation() }
                                    .buttonStyle(InstallerButtonStyle(primary: false))
                            }
                        } else { content }
                    }
                    .frame(maxWidth: geometry.size.width < 760 ? 560 : 648, alignment: .leading)
                    .padding(.horizontal, wide ? 40 : 20).padding(.top, 20).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }.id(model.step).scrollDismissesKeyboard(.interactively).accessibilityIdentifier("installer.scroll")
                    .frame(maxWidth: .infinity)
            }
        }.background(MSTheme.background)
        .font(MSTheme.font(16))
        .foregroundStyle(MSTheme.ink)
        .tint(MSTheme.accent)
        .buttonStyle(MSTextButtonStyle())
        .task { await model.restore() }
        .task { await model.observe() }
        .onDisappear { model.detach() }
        .onChange(of: phase) { _, value in if value == .background { model.detach() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard (32...256*1024).contains(count) else { throw InstallerFailure.invalid("Файл ключа должен быть не больше 256 КиБ.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else { throw InstallerFailure.response }
                model.privateKey = text
            } catch { model.error = "Не удалось прочитать приватный ключ. Проверьте формат и размер файла." }
        }
        .confirmationDialog("Остановить установку?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Запросить остановку", role: .destructive) { model.control("cancel") }
        } message: { Text("Сервер остановится на безопасной границе. Данные и уже созданные ресурсы сохранятся.") }
        .confirmationDialog("Удалить доверие к серверу?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Удалить доверие", role: .destructive) { model.forgetTrust() }
        } message: { Text("Затем потребуется заново сравнить отпечаток по независимому источнику.") }
    }
    private func close() {
        model.detach()
        app.installerPresented = false
        dismiss()
    }

    private func wizardHeader(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !wide {
                HStack(spacing: 7) {
                    BrandMark().frame(width: 27, height: 27)
                    (Text("MeetSpace") + Text(".").foregroundColor(MSTheme.accent))
                        .font(MSTheme.font(20, weight: .semibold)).tracking(-0.8)
                }
            }
            HStack {
                Button {
                    if !model.goBack() { close() }
                } label: {
                    Label("Назад", systemImage: "arrow.left").frame(minHeight: 48)
                }
                .accessibilityIdentifier(model.hasPreviousStep ? "installer.back" : "installer.close")
                Spacer()
                if model.hasPreviousStep {
                    IconButton("xmark", label: "Закрыть установщик", action: close)
                        .accessibilityIdentifier("installer.close")
                }
            }
            VStack(spacing: 10) {
                HStack {
                    Text(model.step == .fingerprint ? "Подключение к серверу" : "Подключение сервера")
                    Spacer()
                    Text(model.step == .fingerprint ? "Шаг 2 из 5" : String(format: "%02d / 05", model.stepNumber))
                        .font(MSTheme.font(12, weight: .semibold)).monospacedDigit().foregroundStyle(MSTheme.accent)
                }.font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { n in
                        Capsule().fill(n <= model.stepNumber ? MSTheme.accent : MSTheme.line).frame(height: 4)
                    }
                }.accessibilityHidden(true)
            }.padding(.top, 6)
        }.padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .server:
            heading("СОБСТВЕННАЯ ИНФРАСТРУКТУРА", "Начнём с сервера.", "Нужен отдельный удалённый Linux VPS с публичным IP-адресом.")
            let addressLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
            addressLayout {
                field("IP-адрес или имя VPS", "203.0.113.10", $model.host, "installer.host")
                field("SSH-порт", "22", $model.port, "installer.port").frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 100)
            }
            field("Домен будущего MeetSpace", "meet.example.org", $model.domain, "installer.domain")
            note("Для VPS укажите IP или имя сервера. Для MeetSpace — домен или HTTPS-адрес.")
            action("Проверить ключ сервера", id: "installer.inspect") { model.inspect() }
            note("На этом шаге пароль и приватный ключ не передаются. Сначала подтвердите публичный ключ сервера по независимому источнику.")
        case .fingerprint:
            VStack(alignment: .leading, spacing: 10) {
                Text("Проверка сервера").font(MSTheme.font(28, weight: .semibold, relativeTo: .title)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("Убедитесь, что подключаетесь к нужному серверу.").font(MSTheme.font(16, weight: .semibold))
                if !model.keyChanged { note("При первом подключении необходимо проверить ключ безопасности сервера.") }
            }
            endpoint
            sectionTitle(model.keyChanged ? "Ключ сервера изменился" : "Первое подключение")
            fingerprintCard(title: "SHA-256-хеш публичного ключа сервера")
            note("Сравните этот хеш с тем, который указан в панели управления сервером, или уточните его у администратора.")
            if model.keyChanged {
                Text("Подключение заблокировано. Сначала выясните причину смены ключа.").foregroundStyle(MSTheme.danger)
                Button("Удалить сохранённое доверие…") { confirmForget = true }.buttonStyle(InstallerButtonStyle(primary: false))
            } else {
                consent("Я проверил SHA-256-хеш ключа сервера.", $model.trustConfirmed, id: "installer.trust")
                action("Доверять этому ключу", id: "installer.trustContinue") { model.trust() }.disabled(!model.trustConfirmed)
            }
        case .access:
            heading("ДОСТУП ПО SSH", "Доступ к серверу.", model.ticket == nil ? "Подтвердите доступ для проверки сервера перед установкой." : "Восстановите доступ, чтобы проверить состояние задания.")
            endpoint
            fingerprintCard(title: "Проверенный ключ сервера")
            field("Пользователь SSH", "root", $model.user, "installer.user")
            VStack(alignment: .leading, spacing: 8) {
                fieldTitle("Способ входа")
                HStack(spacing: 4) {
                    authChoice(false, title: "Пароль", icon: "lock")
                    authChoice(true, title: "Приватный ключ", icon: "key")
                }
                .padding(4).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.usePrivateKey {
                Button { importing = true } label: {
                    Label(model.privateKey.isEmpty ? "Выбрать приватный ключ" : "Заменить приватный ключ", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5])) }
                }
                if !model.privateKey.isEmpty { Label("Ключ загружен в память", systemImage: "checkmark.circle"); Button("Удалить ключ") { model.privateKey = "" } }
                secret("Парольная фраза ключа", $model.passphrase, "installer.passphrase")
                note("OpenSSH Ed25519, до 256 КиБ. Файл и парольная фраза не сохраняются.")
            } else { secret("Пароль SSH", $model.password, "installer.password") }
            action(model.ticket == nil ? "Проверить сервер" : "Восстановить наблюдение", id: "installer.authenticate") { model.authenticate() }
            note("Нужны Python 3 и root либо sudo без запроса пароля. Проверка не устанавливает программы.")
            if model.ticket != nil { Button("Проверить задание и получить план") { model.refreshMissingPlan() }.buttonStyle(InstallerButtonStyle(primary: false)) }
        case .preflight:
            heading("ПЕРЕД УСТАНОВКОЙ", "Диагностика VPS.", "Ознакомьтесь с результатами проверки сервера.")
            endpoint
            action("Подготовить план установки", id: "installer.optionsNext") { model.step = .options }
            note("План установки повторно проверит ресурсы, DNS, порты и существующие данные. Firewall и внешнюю доступность портов проверьте в панели VPS.")
            sectionCard {
                sectionTitle("Проверка сервера")
                ForEach(diagnostics, id: \.0) { row in
                    Divider()
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            fieldTitle(row.0)
                            note(row.1)
                        }
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(MSTheme.muted)
                    }
                }
            }
        case .options:
            heading("ПАРАМЕТРЫ УСТАНОВКИ", "Подготовим пространство.", "Выберите способ установки и параметры сервера. Сначала покажем план изменений.")
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Способ установки")
                installMode("images", title: "Готовые образы", subtitle: "Загрузить опубликованный пакет для вашего VPS.", icon: "arrow.down.to.line")
                installMode("source", title: "Сборка на сервере", subtitle: "Получить исходный код и собрать образы на VPS.", icon: "server.rack")
            }
            sectionCard {
                sectionTitle("Адрес сервера")
                field("Домен MeetSpace", "meet.example.org", $model.options.domain, "installer.installDomain")
                field("Публичный IPv4 VPS", "203.0.113.10", $model.options.publicIpv4, "installer.ipv4")
            }
            sectionCard {
                sectionTitle("HTTPS-сертификат")
                Label("Let's Encrypt", systemImage: "checkmark.shield")
                note("Сертификат для домена MeetSpace будет выпущен и продлён автоматически.")
                field("Email для сертификата (необязательно)", "admin@example.org", $model.options.acmeEmail, "installer.acmeEmail")
            }
            sectionCard {
                sectionTitle("Административная панель")
                field("Логин администратора", "admin", $model.options.admin.username, "installer.adminUser")
                intField("HTTPS-порт админки", $model.options.admin.httpsPort)
                note("Пароль администратора задаётся после проверки плана.")
            }
            sectionCard {
                sectionTitle("Отправка email")
                Toggle("Настроить отправку почты SMTP", isOn: $model.smtpEnabled).toggleStyle(AccountSwitchStyle())
                if model.smtpEnabled {
                    Divider()
                    field("Сервер SMTP", "smtp.example.org", $model.smtp.host, "installer.smtpHost")
                    intField("Порт SMTP", $model.smtp.port)
                    Picker("Защита соединения", selection: $model.smtp.tlsMode) {
                        Text("STARTTLS").tag("starttls")
                        Text("TLS").tag("tls")
                    }.pickerStyle(.segmented)
                    field("Email отправителя", "meet@example.org", $model.smtp.from, "installer.smtpFrom")
                    field("Логин SMTP", "meet@example.org", $model.smtp.username, "installer.smtpUser")
                } else { note("Почту можно подключить позже на сервере.") }
            }
            action("Получить план без установки", id: "installer.getPlan") { model.requestPlan() }
        case .plan:
            heading("04 / ПЛАН ИЗМЕНЕНИЙ", "Всё под вашим контролем.", "Проверьте параметры и подтвердите изменения на VPS.")
            if let plan = model.plan {
                sectionCard {
                    sectionTitle("План установки")
                    planDetail("Домен", plan.options.domain)
                    planDetail("Способ установки", plan.options.imageMode == "images" ? "Готовые образы" : "Сборка на сервере")
                    planDetail("Конфигурация", "\(plan.architecture) · \(plan.resourceProfile)")
                    planDetail("Версия", plan.version)
                    planDetail("Commit", plan.commit)
                    planDetail("SHA-256", plan.hash)
                    Text("Действует до \(plan.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(MSTheme.font(14)).foregroundStyle(MSTheme.muted)
                }
                sectionCard {
                    sectionTitle("Доступ к административной панели")
                    secret("Пароль администратора", $model.adminPassword, "installer.adminPassword")
                    secret("Повторите пароль", $model.adminRepeat, "installer.adminRepeat")
                    note("От 8 до 128 символов. Сохраните пароль в своём менеджере паролей.")
                    if plan.options.smtp != nil { secret("Пароль SMTP", $model.smtpPassword, "installer.smtpPassword") }
                }
                sectionCard {
                    sectionTitle("Подтверждения")
                    if plan.requiresDocker { consent("Разрешаю установку Docker, Compose и Buildx", $model.dockerConfirmed, id: "installer.confirmDocker") }
                    consent("Принимаю условия Let's Encrypt", $model.acmeConfirmed, id: "installer.confirmACME")
                    Link("Условия Let's Encrypt", destination: URL(string: "https://letsencrypt.org/repository/")!)
                    consent("Я проверил план и разрешаю изменения на VPS", $model.planConfirmed, id: "installer.confirmPlan")
                }
                action("Установить MeetSpace", id: "installer.apply") { model.apply() }.disabled(!model.canApply)
                Button("Получить новый план") { model.requestPlan() }
            }
        case .progress:
            heading("УСТАНОВКА MEETSPACE", model.stale ? "Проверим состояние." : "Ваше пространство создаётся.", "Закрытие приложения не останавливает задание на сервере.")
            if let ticket = model.ticket { Text("Задание: \(ticket.jobID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            sectionCard {
                sectionTitle(model.stale ? "Последнее известное состояние" : "Этапы установки")
                if let status = model.status {
                    ProgressView(value: Double(status.completed.count), total: Double(installerPhases.count))
                    note("Подтверждено этапов: \(status.completed.count) из \(installerPhases.count)")
                }
                ForEach(Array(zip(installerPhases, phaseNames).enumerated()), id: \.offset) { index, entry in
                    let done = model.status?.completed.contains(entry.0) == true
                    let current = model.status?.phase == entry.0
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(done ? MSTheme.success.opacity(0.12) : current ? MSTheme.accentSoft : MSTheme.surfaceSecondary)
                            if done { Image(systemName: "checkmark") }
                            else { Text("\(index + 1)").monospacedDigit() }
                        }.frame(width: 32, height: 32).accessibilityHidden(true)
                        Text(entry.1)
                    }.font(MSTheme.font(15, weight: current ? .semibold : .regular))
                        .foregroundStyle(done ? MSTheme.success : current ? MSTheme.accent : MSTheme.muted)
                }
            }
            if let status = model.status {
                Text("Состояние: \(status.state)")
                if let code = status.errorCode { Text(code).foregroundStyle(MSTheme.danger) }
                sectionCard {
                    DisclosureGroup("Журнал установки") { ForEach(status.events, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) } }
                }
            }
            if model.stale || model.status == nil {
                action("Подключиться снова", id: "installer.reconnect") { model.reconnect() }
                Button("Проверить задание и получить план") { model.refreshMissingPlan() }.buttonStyle(InstallerButtonStyle(primary: false))
            }
            else {
                Button("Обновить состояние") { model.control("status") }.buttonStyle(InstallerButtonStyle(primary: false))
                if model.status?.state == "needs_recovery" || model.status?.state == "cancelled" { action("Продолжить установку", id: "installer.resume") { model.control("resume") } }
                else if model.status?.terminal == false { Button("Остановить установку", role: .destructive) { confirmStop = true } }
            }
        case .complete:
            Image(systemName: "checkmark").font(.system(size: 32, weight: .medium)).foregroundStyle(MSTheme.success)
                .frame(width: 72, height: 72).background(MSTheme.success.opacity(0.12), in: Circle()).accessibilityHidden(true)
            heading("ГОТОВО К ОБЩЕНИЮ", "Пространство готово.", "Установка на сервере завершена.")
            sectionCard {
                fieldTitle("Адрес вашего пространства")
                Text(model.serverURL).font(MSTheme.font(20, weight: .semibold)).textSelection(.enabled)
                ShareLink(item: model.serverURL) { Label("Поделиться адресом", systemImage: "square.and.arrow.up") }
            }
            if let options = model.ticket?.plan.options {
                sectionCard {
                    sectionTitle("Администрирование")
                    note("Логин: \(options.admin.username)")
                    Link("Открыть админку", destination: URL(string: "https://\(options.domain):\(options.admin.httpsPort)")!)
                        .buttonStyle(InstallerButtonStyle(primary: false))
                }
            }
            action("Перейти ко входу", id: "installer.finish") {
                let url = model.serverURL
                Task { await model.forgetCompleted(); app.installerPresented = false; app.show(.connect); app.checkServer(url) }
            }
        }
    }
    private var endpoint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Адрес сервера: \(model.host)").font(.system(.body, design: .monospaced))
            note("SSH-порт: \(model.port)")
        }
    }
    private func fingerprintCard(title: String) -> some View {
        sectionCard {
            sectionTitle(title)
            if let key = model.key {
                if let type = key.openSSH.split(separator: " ").first { note("Тип ключа: \(type)") }
                Text(key.fingerprint).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(MSTheme.line) }
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(MSTheme.font(18, weight: .semibold, relativeTo: .headline)).accessibilityAddTraits(.isHeader)
    }
    private func heading(_ step: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step).font(MSTheme.font(12, weight: .semibold, relativeTo: .caption))
                .tracking(1.2).lineSpacing(kickerLeading).padding(.vertical, kickerLeading / 2)
                .foregroundStyle(MSTheme.muted)
            Text(title).font(MSTheme.font(28, weight: .semibold, relativeTo: .title)).tracking(-0.8)
                .padding(.bottom, 2).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(MSTheme.font(16)).lineSpacing(subtitleLeading)
                .padding(.vertical, subtitleLeading / 2).foregroundStyle(MSTheme.muted)
        }.fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(MSTheme.font(14, relativeTo: .callout)).lineSpacing(noteLeading)
            .padding(.vertical, noteLeading / 2).foregroundStyle(MSTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(InstallerButtonStyle(primary: true)).accessibilityIdentifier(id)
    }
    private func fieldTitle(_ title: String) -> some View {
        Text(title).font(MSTheme.font(14, weight: .medium))
    }
    private func planDetail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            note(label)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func authChoice(_ key: Bool, title: String, icon: String) -> some View {
        let selected = model.usePrivateKey == key
        return Button { model.usePrivateKey = key } label: {
            Label(title, systemImage: icon).font(MSTheme.font(14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                .background(selected ? MSTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func installMode(_ value: String, title: String, subtitle: String, icon: String) -> some View {
        let selected = model.options.imageMode == value
        return Button { model.options.imageMode = value } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 36, height: 36)
                    .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                    .background(selected ? MSTheme.surface : MSTheme.background, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    fieldTitle(title)
                    note(subtitle)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
            }
            .multilineTextAlignment(.leading).padding(16).frame(maxWidth: .infinity, minHeight: 104)
            .background(selected ? MSTheme.accentSoft : MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? MSTheme.accent : MSTheme.line) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func consent(_ title: String, _ isOn: Binding<Bool>, id: String) -> some View {
        Toggle(title, isOn: isOn).toggleStyle(InstallerCheckboxStyle()).accessibilityIdentifier(id)
    }
    private func inputLabel(_ label: String) -> some View {
        Text(label).font(MSTheme.font(14)).lineSpacing(labelLeading).padding(.vertical, labelLeading / 2)
    }
    private func inputPrompt(_ hint: String) -> Text {
        Text(hint).foregroundStyle(MSTheme.muted)
    }
    private func field(_ label: String, _ hint: String, _ binding: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inputLabel(label)
            TextField(label, text: binding, prompt: inputPrompt(hint)).msURLInput().modifier(InstallerInputStyle())
                .accessibilityLabel(label).accessibilityIdentifier(id)
        }
    }
    private func intField(_ label: String, _ binding: Binding<Int>) -> some View { field(label, "", Binding(get: { String(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0) ?? 0 }), "installer." + label) }
    private func secret(_ label: String, _ binding: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inputLabel(label)
            SecureField(label, text: binding, prompt: inputPrompt(label))
                .modifier(InstallerInputStyle()).accessibilityIdentifier(id)
        }
    }
    private var phaseNames: [String] { ["Docker, Compose и Buildx", "Проверка исходников", "Подготовка образов", "Конфигурация и секреты", "База, очередь и хранилище", "Резервная копия", "Миграции БД", "HTTPS и сертификат", "Запуск MeetSpace", "Проверка готовности"] }
    private var diagnostics: [(String, String)] {
        let facts = model.facts
        let system = "\(facts["distro"] ?? "unknown") \(facts["distro_version"] ?? "")"
        var rows: [(String, String)] = [("Операционная система", system)]
        let fields: [(String, String)] = [
            ("Архитектура", "arch"), ("Процессор", "cpu"), ("Оперативная память, КиБ", "ram_kib"),
            ("Свободный диск, КиБ", "disk_kib"), ("Права пользователя", "sudo"),
            ("Docker", "docker"), ("Доступ к Docker daemon", "docker_access"),
            ("Docker Compose", "compose"), ("Существующая установка", "existing_paths")
        ]
        for (title, key) in fields { rows.append((title, facts[key] ?? "unknown")) }
        let portsKnown = facts["ports_known"] == "yes"
        for port in [80, 443, 3478, 5349, 50010] {
            let value = portsKnown ? facts["tcp_\(port)"] ?? "unknown" : "unknown"
            rows.append(("TCP \(port)", value))
        }
        for port in [3478, 50010] {
            let value = portsKnown ? facts["udp_\(port)"] ?? "unknown" : "unknown"
            rows.append(("UDP \(port)", value))
        }
        let relay = portsKnown ? "Занятых портов: \(facts["udp_relay_busy"] ?? "unknown")" : "unknown"
        rows.append(("UDP 49160–49259", relay))
        rows.append(("DNS", facts["dns_domain"] ?? "unknown"))
        rows.append(("TLS", "Будет проверен при установке HTTPS"))
        rows.append(("Firewall", facts["firewall"] ?? "unknown"))
        return rows
    }
}

private struct InstallerInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(MSTheme.font(16))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line).allowsHitTesting(false) }
    }
}

private struct InstallerButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(MSTheme.font(15, weight: .semibold))
            .multilineTextAlignment(.center).padding(.vertical, 12).padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(primary ? MSTheme.brandAccent : MSTheme.surface)
                    .shadow(color: primary && enabled ? MSTheme.brandAccent.opacity(0.16) : .clear, radius: 4, y: 3)
            }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(primary ? Color.clear : MSTheme.line) }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

private struct InstallerCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isOn ? MSTheme.accent : MSTheme.surface)
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(configuration.isOn ? MSTheme.accent : MSTheme.muted) }
                    .overlay {
                        if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(MSTheme.surface) }
                    }.frame(width: 22, height: 22)
                configuration.label.font(MSTheme.font(14)).lineSpacing(3).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
