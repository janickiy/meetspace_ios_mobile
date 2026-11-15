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
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 800 {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack { BrandMark().frame(width: 36, height: 38); Text("MeetSpace").font(MSTheme.font(22, weight: .semibold)) }
                        Spacer()
                        Text("ВАШЕ ПРОСТРАНСТВО").font(MSTheme.font(11, weight: .semibold)).tracking(2).foregroundStyle(MSTheme.accent)
                        Text("Своя команда.\nСвой сервер.").font(MSTheme.font(42, weight: .semibold, relativeTo: .largeTitle))
                        Text("Встречи и общение на вашей инфраструктуре.").foregroundStyle(MSTheme.muted)
                        Image(systemName: "server.rack").font(.system(size: 86)).foregroundStyle(MSTheme.accent).frame(maxWidth: .infinity).padding(40)
                        Spacer()
                        Label("Ваше пространство. Ваши правила.", systemImage: "lock.shield")
                    }.padding(44).frame(maxWidth: .infinity).background(MSTheme.accentSoft)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack { BrandMark().frame(width: 28, height: 30); Text("MeetSpace").font(MSTheme.font(21, weight: .semibold)); Spacer()
                            Button { model.detach(); app.installerPresented = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Закрыть установщик").accessibilityIdentifier("installer.close")
                        }
                        HStack { Text("Подключение к серверу"); Spacer(); Text("Шаг \(model.stepNumber) из 5") }.font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        HStack(spacing: 6) { ForEach(1...5, id: \.self) { n in Capsule().fill(n <= model.stepNumber ? MSTheme.accent : MSTheme.line).frame(height: 4) } }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(MSTheme.danger).msCard().accessibilityIdentifier("installer.error") }
                        if model.busy {
                            HStack { ProgressView(); Text("Проверяем сервер…") }.frame(maxWidth: .infinity).padding()
                            Button("Отменить проверку") { model.cancelLocalOperation() }.buttonStyle(MSButtonStyle(primary: false))
                        } else { content }
                    }.padding(geometry.size.width >= 800 ? 40 : 24).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.id(model.step).scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity).background(MSTheme.surface)
            }
        }.background(MSTheme.background)
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
    @ViewBuilder private var content: some View {
        switch model.step {
        case .server:
            heading("СОБСТВЕННАЯ ИНФРАСТРУКТУРА", "Начнём с сервера.", "Нужен отдельный удалённый Linux VPS с публичным IP-адресом.")
            HStack(alignment: .top) { field("IP-адрес или имя VPS", "203.0.113.10", $model.host, "installer.host"); field("SSH-порт", "22", $model.port, "installer.port").frame(maxWidth: 110) }
            field("Домен будущего MeetSpace", "meet.example.org", $model.domain, "installer.domain")
            note("Для VPS укажите IP или имя сервера. Для MeetSpace — домен или HTTPS-адрес.")
            action("Проверить ключ сервера", id: "installer.inspect") { model.inspect() }
            note("На этом шаге пароль и приватный ключ не передаются. Сначала подтвердите публичный ключ сервера по независимому источнику.")
        case .fingerprint:
            heading("ПРОВЕРКА СЕРВЕРА", "Проверка сервера", "Убедитесь, что подключаетесь к нужному серверу.")
            endpoint
            VStack(alignment: .leading, spacing: 12) {
                Text(model.keyChanged ? "Ключ сервера изменился" : "Первое подключение").font(MSTheme.font(18, weight: .semibold))
                Text("SHA-256-хеш публичного ключа сервера").foregroundStyle(MSTheme.muted)
                Text(model.key?.fingerprint ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.msCard()
            note("Сравните этот хеш с тем, который указан в панели управления сервером, или уточните его у администратора.")
            if model.keyChanged {
                Text("Подключение заблокировано. Сначала выясните причину смены ключа.").foregroundStyle(MSTheme.danger)
                Button("Удалить сохранённое доверие…") { confirmForget = true }.buttonStyle(MSButtonStyle(primary: false))
            } else {
                Toggle("Я проверил SHA-256-хеш ключа сервера.", isOn: $model.trustConfirmed).accessibilityIdentifier("installer.trust")
                action("Доверять этому ключу", id: "installer.trustContinue") { model.trust() }.disabled(!model.trustConfirmed)
            }
        case .access:
            heading("ДОСТУП SSH", "Подключимся к VPS.", "Данные доступа используются только для текущего подключения и не сохраняются.")
            endpoint
            field("Пользователь SSH", "root", $model.user, "installer.user")
            Picker("Способ входа", selection: $model.usePrivateKey) { Text("Пароль").tag(false); Text("Приватный ключ").tag(true) }.pickerStyle(.segmented)
            if model.usePrivateKey {
                Button(model.privateKey.isEmpty ? "Выбрать приватный ключ" : "Заменить приватный ключ") { importing = true }.buttonStyle(MSButtonStyle(primary: false))
                if !model.privateKey.isEmpty { Label("Ключ загружен в память", systemImage: "checkmark.circle"); Button("Удалить ключ") { model.privateKey = "" } }
                secret("Парольная фраза ключа", $model.passphrase, "installer.passphrase")
                note("OpenSSH Ed25519, до 256 КиБ. Файл и парольная фраза не сохраняются.")
            } else { secret("Пароль SSH", $model.password, "installer.password") }
            action(model.ticket == nil ? "Проверить сервер" : "Восстановить наблюдение", id: "installer.authenticate") { model.authenticate() }
            note("Нужны Python 3 и root либо sudo без запроса пароля. Проверка не устанавливает программы.")
            if model.ticket != nil { Button("Проверить задание и получить план") { model.refreshMissingPlan() }.buttonStyle(MSButtonStyle(primary: false)) }
        case .preflight:
            heading("ДИАГНОСТИКА VPS", "Проверим готовность.", "Результаты получены с сервера. Установка пока не запускалась.")
            ForEach(diagnostics, id: \.0) { row in
                HStack(alignment: .top) { Image(systemName: "info.circle").foregroundStyle(MSTheme.accent); VStack(alignment: .leading) { Text(row.0).font(MSTheme.font(14, weight: .semibold)); Text(row.1).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }; Spacer() }.msCard(padding: 14)
            }
            note("План установки повторно проверит ресурсы, DNS, порты и существующие данные. Firewall и внешнюю доступность портов проверьте в панели VPS.")
            action("Настроить установку", id: "installer.optionsNext") { model.step = .options }
        case .options:
            heading("ПАРАМЕТРЫ УСТАНОВКИ", "Настроим пространство.", "Сначала получим план изменений. Ничего не устанавливается без подтверждения.")
            Picker("Способ установки", selection: $model.options.imageMode) { Text("Готовые образы").tag("images"); Text("Сборка на сервере").tag("source") }.pickerStyle(.segmented)
            field("Домен MeetSpace", "meet.example.org", $model.options.domain, "installer.installDomain")
            field("Публичный IPv4 VPS", "203.0.113.10", $model.options.publicIpv4, "installer.ipv4")
            VStack(alignment: .leading, spacing: 12) {
                Label("HTTPS-сертификат", systemImage: "lock.shield").font(MSTheme.font(17, weight: .semibold))
                Text("Let's Encrypt · автоматическое обновление")
                note("Собственный SSL-сертификат пока не поддерживается серверным установщиком.")
                field("Email для сертификата (необязательно)", "admin@example.org", $model.options.acmeEmail, "installer.acmeEmail")
            }.msCard()
            VStack(alignment: .leading, spacing: 14) {
                Label("Административная панель", systemImage: "person.badge.shield.checkmark").font(MSTheme.font(17, weight: .semibold))
                note("Администратор обязателен. Пароль задаётся после проверки плана.")
                field("Логин администратора", "admin", $model.options.admin.username, "installer.adminUser")
                intField("HTTPS-порт админки", $model.options.admin.httpsPort)
            }.msCard()
            Toggle("Настроить отправку почты SMTP", isOn: $model.smtpEnabled)
            if model.smtpEnabled {
                field("Сервер SMTP", "smtp.example.org", $model.smtp.host, "installer.smtpHost")
                intField("Порт SMTP", $model.smtp.port)
                Picker("Защита соединения", selection: $model.smtp.tlsMode) { Text("STARTTLS").tag("starttls"); Text("TLS").tag("tls") }.pickerStyle(.segmented)
                field("Email отправителя", "meet@example.org", $model.smtp.from, "installer.smtpFrom")
                field("Логин SMTP", "meet@example.org", $model.smtp.username, "installer.smtpUser")
            } else { note("Можно пропустить. Почту можно подключить позже на сервере.") }
            action("Получить план установки", id: "installer.getPlan") { model.requestPlan() }
        case .plan:
            heading("ПЛАН ИЗМЕНЕНИЙ", "Всё готово к установке.", "Проверьте параметры и подтвердите изменения на VPS.")
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 10) {
                    Text(plan.options.domain).font(MSTheme.font(20, weight: .semibold))
                    Text(plan.options.imageMode == "images" ? "Готовые образы" : "Сборка на сервере")
                    Text("\(plan.architecture) · \(plan.resourceProfile)")
                    Text("Версия: \(plan.version)")
                    Text("Commit: \(plan.commit)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("SHA-256: \(plan.hash)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Действует до \(plan.expiresAt.formatted(date: .omitted, time: .shortened))")
                }.msCard()
                secret("Пароль администратора", $model.adminPassword, "installer.adminPassword")
                secret("Повторите пароль", $model.adminRepeat, "installer.adminRepeat")
                note("От 8 до 128 символов. Сохраните пароль в своём менеджере паролей.")
                if plan.options.smtp != nil { secret("Пароль SMTP", $model.smtpPassword, "installer.smtpPassword") }
                if plan.requiresDocker { Toggle("Разрешаю установку Docker, Compose и Buildx", isOn: $model.dockerConfirmed).accessibilityIdentifier("installer.confirmDocker") }
                Toggle("Принимаю условия Let's Encrypt", isOn: $model.acmeConfirmed).accessibilityIdentifier("installer.confirmACME")
                Link("Условия Let's Encrypt", destination: URL(string: "https://letsencrypt.org/repository/")!)
                Toggle("Я проверил план и разрешаю изменения на VPS", isOn: $model.planConfirmed).accessibilityIdentifier("installer.confirmPlan")
                action("Установить MeetSpace", id: "installer.apply") { model.apply() }.disabled(!model.canApply)
                Button("Получить новый план") { model.requestPlan() }
            }
        case .progress:
            heading("УСТАНОВКА MEETSPACE", model.stale ? "Восстановим соединение." : "Создаём пространство.", "Закрытие приложения не останавливает задание на сервере.")
            if let ticket = model.ticket { Text("Задание: \(ticket.jobID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            ProgressView(value: Double(model.status?.completed.count ?? 0), total: 10)
            ForEach(Array(zip(installerPhases, phaseNames)), id: \.0) { phase, name in
                Label(name, systemImage: model.status?.completed.contains(phase) == true ? "checkmark.circle.fill" : "circle").foregroundStyle(model.status?.phase == phase ? MSTheme.accent : MSTheme.muted).padding(.vertical, 3)
            }
            if let status = model.status {
                Text("Состояние: \(status.state)")
                if let code = status.errorCode { Text(code).foregroundStyle(MSTheme.danger) }
                DisclosureGroup("Журнал установки") { ForEach(status.events, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) } }
            }
            if model.stale || model.status == nil {
                action("Подключиться снова", id: "installer.reconnect") { model.reconnect() }
                Button("Проверить задание и получить план") { model.refreshMissingPlan() }.buttonStyle(MSButtonStyle(primary: false))
            }
            else {
                Button("Обновить состояние") { model.control("status") }.buttonStyle(MSButtonStyle(primary: false))
                if model.status?.state == "needs_recovery" || model.status?.state == "cancelled" { action("Продолжить установку", id: "installer.resume") { model.control("resume") } }
                else if model.status?.terminal == false { Button("Остановить установку", role: .destructive) { confirmStop = true } }
            }
        case .complete:
            heading("ПРОСТРАНСТВО ГОТОВО", "Добро пожаловать\nв MeetSpace.", "Готовность подтверждена серверным установщиком.")
            Image(systemName: "checkmark.circle.fill").font(.system(size: 68)).foregroundStyle(MSTheme.success).frame(maxWidth: .infinity)
            Text(model.serverURL).font(MSTheme.font(22, weight: .semibold)).textSelection(.enabled).msCard()
            ShareLink(item: model.serverURL) { Label("Поделиться адресом", systemImage: "square.and.arrow.up") }
            if let options = model.ticket?.plan.options {
                Link("Открыть админку · \(options.admin.username)", destination: URL(string: "https://\(options.domain):\(options.admin.httpsPort)")!)
            }
            action("Перейти ко входу", id: "installer.finish") {
                let url = model.serverURL
                Task { await model.forgetCompleted(); app.installerPresented = false; app.show(.connect); app.checkServer(url) }
            }
        }
    }
    private var endpoint: some View { HStack { Text(model.host).font(MSTheme.font(16, weight: .semibold)); Spacer(); Text("SSH-порт \(model.port)").foregroundStyle(MSTheme.muted) }.msCard() }
    private func heading(_ step: String, _ title: String, _ subtitle: String) -> some View { StepHeading(step: step, title: title, subtitle: subtitle) }
    private func note(_ text: String) -> some View { Text(text).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted).fixedSize(horizontal: false, vertical: true) }
    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View { Button(title, action: perform).buttonStyle(MSButtonStyle()).accessibilityIdentifier(id) }
    private func field(_ label: String, _ hint: String, _ binding: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(MSTheme.font(12, weight: .semibold)); TextField(hint, text: binding).msURLInput().textFieldStyle(.plain).padding(14).background(MSTheme.background, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier(id) }
    }
    private func intField(_ label: String, _ binding: Binding<Int>) -> some View { field(label, "", Binding(get: { String(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0) ?? 0 }), "installer." + label) }
    private func secret(_ label: String, _ binding: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(MSTheme.font(12, weight: .semibold)); SecureField(label, text: binding).textFieldStyle(.plain).padding(14).background(MSTheme.background, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier(id) }
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
