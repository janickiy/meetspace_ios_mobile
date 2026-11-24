import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

public struct MeetSpaceRootView: View {
    @Bindable private var model: AppModel
    @State private var restored: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        lifecycleContent
        #if os(iOS)
        .fullScreenCover(isPresented: $model.installerPresented) { InstallerView(app: model).interactiveDismissDisabled().preferredColorScheme(colorScheme) }
        #else
        .sheet(isPresented: $model.installerPresented) { InstallerView(app: model).interactiveDismissDisabled().preferredColorScheme(colorScheme) }
        #endif
        .conferencePresentation(model: model)
        .directCallPresentation(model: model)
        .alert(tr("MeetSpace"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(tr("Понятно"), role: .cancel) { model.notice = nil }
        } message: { Text(tr(model.notice ?? "")) }
    }

    private var lifecycleContent: some View {
        styledContent
        .task {
            guard !restored else { return }
            restored = true; await model.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            // Capture shutdown must never wait for a chat reconnect or HTTP cancellation.
            Task { await model.activeConference?.setForeground(phase != .background) }
            Task { await model.identity.calls?.setForeground(phase != .background) }
            Task { await model.identity.messaging?.setForeground(phase == .active) }
            if phase == .active { Task { await model.identity.notifications.refreshAuthorization() } }
        }
        .onChange(of: model.identity.calls?.isActive, initial: true) { _, active in
            Task { await model.identity.messaging?.setCallActive(active == true) }
        }
        .onChange(of: model.identity.messaging?.account.id) { _, _ in
            model.identityChanged()
            model.showingWorkspaceNotifications = false
            model.meetingsPath = []; model.messagesPath = []; model.profilePath = []
            if let account = model.identity.messaging?.account {
                model.configuration.server = account.server; model.tab = .messages
            } else { model.sessionEnded() }
        }
    }

    private var styledContent: some View {
        Group {
            if model.isDemo || (model.identity.messaging != nil && !model.identity.addingAccount) {
                WorkspaceView(model: model).id(model.identity.messaging?.account.id)
            }
            else { OnboardingView(model: model) }
        }
        .font(MSTheme.font()).foregroundStyle(MSTheme.ink).tint(MSTheme.accent)
        .buttonStyle(MSTextButtonStyle())
        .preferredColorScheme(colorScheme)
        .background(MSTheme.background)
    }

    private var colorScheme: ColorScheme? {
        switch model.configuration.appearance { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760 && !typeSize.isAccessibilitySize
            HStack(spacing: 0) {
                if wide {
                    let sideFraction: CGFloat = proxy.size.width <= 1000 ? 0.83 / 1.83 : 0.5
                    OnboardingAside(windowWidth: proxy.size.width)
                        .frame(width: proxy.size.width * sideFraction)
                }
                form(wide: wide, size: proxy.size)
            }.background(MSTheme.background)
        }
    }

    private func form(wide: Bool, size: CGSize) -> some View {
        let narrowColumns = wide && size.width <= 1000
        let inset: CGFloat = switch size.width {
        case _ where !wide: 24
        case ...1000: 30
        case 1100...: 62
        default: 44
        }
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !wide {
                        HStack(spacing: 9) {
                            BrandMark().frame(width: 27, height: 29)
                            (Text("MeetSpace") + Text(".").foregroundColor(MSTheme.accent)).font(MSTheme.font(21, weight: .semibold))
                            Spacer()
                            if model.onboarding == .welcome {
                                Text("iOS").font(MSTheme.font(8, weight: .semibold)).tracking(1.9).foregroundStyle(MSTheme.muted)
                            } else {
                                IconButton("xmark", label: "На главную", action: closeForm).disabled(model.identity.busy)
                            }
                        }.padding(.bottom, 12)
                    } else {
                        if model.onboarding != .welcome {
                            Button(action: closeForm) {
                                Label(tr("На главную"), systemImage: "arrow.left").frame(minHeight: 44)
                            }.disabled(model.identity.busy)
                        }
                        Spacer(minLength: 0)
                    }
                    Group {
                        switch model.onboarding {
                        case .welcome: WelcomeView(model: model, showArtwork: !wide, compactPhone: size.width <= 375, narrowColumns: narrowColumns)
                        case .connect: ConnectView(model: model, showsBack: !wide)
                        case .login: AuthenticationView(model: model, registration: false)
                        case .register: AuthenticationView(model: model, registration: true)
                        }
                    }.frame(maxWidth: wide ? 418 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    if wide { Spacer(minLength: 0) }
                    if wide || model.onboarding == .welcome { privacyNote }
                }
                .frame(minHeight: wide ? max(0, size.height - 48) : nil)
                .padding(.vertical, 24).padding(.horizontal, inset)
                .frame(maxWidth: wide ? .infinity : 510)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.probeState) { _, state in
                if model.onboarding == .connect && state == .content {
                    scroll.scrollTo(ConnectView.continueID, anchor: .bottom)
                }
            }
        }
        .id(model.onboarding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MSTheme.surface)
    }

    private var privacyNote: some View {
        Label(tr("Ваше общение остаётся в вашем пространстве"), systemImage: "lock")
            .font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
            .frame(maxWidth: .infinity)
    }

    private func closeForm() {
        if model.identity.addingAccount { model.identity.addingAccount = false }
        else { model.show(.welcome) }
    }
}

private struct WelcomeView: View {
    @Bindable var model: AppModel
    let showArtwork: Bool
    let compactPhone: Bool
    let narrowColumns: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var guestForm = false
    private var welcomeTitle: AttributedString {
        var title = AttributedString(tr("Команда ближе.\nИдей больше."))
        if let range = title.range(of: tr("Идей больше.")) { title[range].foregroundColor = MSTheme.accent }
        return title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("ЕДИНОЕ ПРОСТРАНСТВО")).font(MSTheme.font(showArtwork ? 8 : 10, weight: .semibold, relativeTo: .caption))
                .tracking(1.8).foregroundStyle(MSTheme.muted).padding(.bottom, 14)
            Text(welcomeTitle).font(MSTheme.font(showArtwork ? (compactPhone ? 34 : 37) : (narrowColumns ? 38 : 43), weight: .semibold, relativeTo: .largeTitle))
                .tracking(showArtwork ? -1.7 : -1.9).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("welcome.heading").padding(.bottom, 14)
            Text(tr(showArtwork ? "MeetSpace — единое пространство для встреч и общения." : "MeetSpace — единое пространство\nдля встреч и общения."))
                .font(MSTheme.font(showArtwork ? 12 : (narrowColumns ? 13 : 15))).lineSpacing(5).foregroundStyle(MSTheme.muted)
                .padding(.bottom, showArtwork ? 4 : 30)
            if showArtwork && !typeSize.isAccessibilitySize {
                WelcomeArtwork()
                    .frame(height: compactPhone ? 179 : 207)
                    .background(RadialGradient(colors: [MSTheme.accentSoft.opacity(0.6), MSTheme.surface], center: .center, startRadius: 10, endRadius: 155))
                    .padding(.horizontal, -8).padding(.bottom, compactPhone ? 17 : 20)
            }
            VStack(spacing: showArtwork ? 10 : 13) {
                connectionChoice("Подключиться к серверу", subtitle: "У меня уже есть адрес MeetSpace", icon: "link", primary: true) { model.show(.connect) }
                    .accessibilityIdentifier("connectServer")
                connectionChoice("Развернуть свой сервер", subtitle: "Создать пространство на своём VPS", icon: "server.rack", primary: false) {
                    model.installerPresented = true
                }.accessibilityIdentifier("deployServer")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { feature("video", "Встречи"); feature("bubble.left", "Сообщения"); feature("checkmark.shield", "Ваш сервер") }
                VStack(alignment: .leading, spacing: 12) { feature("video", "Встречи"); feature("bubble.left", "Сообщения"); feature("checkmark.shield", "Ваш сервер") }
            }.frame(maxWidth: .infinity).padding(.top, 23).padding(.bottom, 6)
            Button { model.enterDemo() } label: {
                HStack(spacing: 7) { Text(tr("Посмотреть интерфейс")); Image(systemName: "arrow.right") }
                    .font(MSTheme.font(11)).frame(maxWidth: .infinity, minHeight: 44)
            }.contentShape(Rectangle()).accessibilityIdentifier("openDemo")
            Button(tr("Войти как гость")) { guestForm = true }
                .font(MSTheme.font(11)).frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("guestConference")
                .workspaceFormPresentation(isPresented: $guestForm) { GuestConferenceForm(app: model, completed: { guestForm = false }) }
        }
    }
    private func connectionChoice(_ title: String, subtitle: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: showArtwork ? 12 : 14) {
                Image(systemName: icon).font(.system(size: 20)).frame(width: showArtwork ? 35 : 40, height: showArtwork ? 36 : 40)
                    .background(primary ? Color.white.opacity(0.13) : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(title)).font(MSTheme.font(showArtwork || narrowColumns ? 12 : 14, weight: .semibold))
                    Text(tr(subtitle)).font(MSTheme.font(showArtwork || narrowColumns ? 9 : 10.5, relativeTo: .caption))
                        .foregroundStyle(primary ? MSTheme.surface : MSTheme.muted)
                        .accessibilityIdentifier(primary ? "welcome.connectSubtitle" : "welcome.deploySubtitle")
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.system(size: 17)).accessibilityHidden(true)
            }.padding(showArtwork ? 14 : 17).frame(maxWidth: .infinity, minHeight: showArtwork ? (compactPhone ? 74 : 79) : 90)
                .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
                .background(primary ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: showArtwork ? 12 : 14))
                .overlay(RoundedRectangle(cornerRadius: showArtwork ? 12 : 14).stroke(primary ? Color.clear : MSTheme.line))
                .contentShape(Rectangle()).accessibilityElement(children: .combine)
        }.buttonStyle(.plain)
    }
    private func feature(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(MSTheme.muted)
            Text(tr(title)).font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
        }.accessibilityElement(children: .combine)
    }
}

struct OnboardingAside: View {
    let windowWidth: CGFloat
    var install = false

    private var horizontalInset: CGFloat {
        if install { return min(40, max(24, windowWidth * 0.027)) }
        if windowWidth <= 1000 { return 29 }
        return windowWidth >= 1100 ? 55 : 42
    }

    private var titleSize: CGFloat {
        if install { return min(38, max(30, windowWidth * 0.03)) }
        return windowWidth <= 1000 ? 37 : min(52, windowWidth * 0.038)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                BrandMark().frame(width: 32, height: 34)
                (Text("MeetSpace") + Text(".").foregroundColor(MSTheme.accent)).font(MSTheme.font(24, weight: .semibold))
            }
            Spacer(minLength: 25)
            Text(install ? tr("ВАШ СЕРВЕР. ВАШИ ПРАВИЛА.") : tr("БЛИЖЕ К КОМАНДЕ.")).font(MSTheme.font(10, weight: .semibold)).tracking(1.8).foregroundStyle(MSTheme.muted)
            Text(install ? tr("Своё пространство.\nПолный контроль.") : tr("Быть на одной\nволне.")).font(MSTheme.font(titleSize, weight: .semibold, relativeTo: .largeTitle)).tracking(install ? -1.2 : -1.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(install ? tr("Подключите удалённый сервер, а мы покажем каждый шаг настройки.") : tr("Встречи, сообщения и идеи —\nв одном пространстве."))
                .font(MSTheme.font(install ? 14 : (windowWidth <= 1000 ? 12 : 15))).lineSpacing(5).foregroundStyle(MSTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            WelcomeArtwork().frame(height: windowWidth <= 1000 ? 265 : 285)
                .padding(.horizontal, -24).padding(.top, !install && windowWidth >= 1100 ? 24 : 0)
            Spacer(minLength: 25)
            ViewThatFits(in: .horizontal) {
                HStack { Label(tr("На вашей инфраструктуре"), systemImage: "checkmark.shield"); Spacer(); Text(tr("MeetSpace для iOS")) }
                VStack(alignment: .leading, spacing: 8) { Label(tr("На вашей инфраструктуре"), systemImage: "checkmark.shield"); Text(tr("MeetSpace для iOS")) }
            }.font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
        }.padding(.horizontal, horizontalInset).padding(.vertical, install ? 32 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .background(install ? MSTheme.accentSoft : MSTheme.surfaceSecondary)
            .overlay(alignment: .trailing) { Rectangle().fill(MSTheme.line).frame(width: 1) }
    }
}

/// Native vector reconstruction of onboarding.css orbit/card illustration; no remote images.
private struct WelcomeArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 420, proxy.size.height / 285)
            ZStack {
                Circle().stroke(MSTheme.line, lineWidth: 1).frame(width: 246, height: 246).position(x: 210, y: 148)
                Circle().stroke(MSTheme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 333, height: 333).position(x: 210, y: 148)
                Circle().stroke(MSTheme.line.opacity(0.6), lineWidth: 1).frame(width: 418, height: 418).position(x: 210, y: 148)
                Path { path in path.move(to: CGPoint(x: 30, y: 235)); path.addLine(to: CGPoint(x: 390, y: 70)) }
                    .stroke(MSTheme.accent.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                videoTile.rotationEffect(.degrees(-7)).position(x: 205, y: 135)
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.system(size: 17)).foregroundStyle(MSTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Хорошие идеи")).font(.custom("Inter-Regular", size: 10))
                        Text(tr("начинаются здесь.")).font(.custom("Inter-SemiBold", size: 10))
                    }
                    Text("09:41").font(.custom("Inter-Regular", size: 7)).foregroundStyle(MSTheme.muted).padding(.top, 18)
                }.padding(13).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(MSTheme.line))
                    .rotationEffect(.degrees(4)).position(x: 275, y: 232)
                Image(systemName: "checkmark.shield").font(.system(size: 22)).foregroundStyle(MSTheme.success)
                    .frame(width: 44, height: 44).background(MSTheme.success.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(MSTheme.surface, lineWidth: 4))
                    .rotationEffect(.degrees(-12)).position(x: 65, y: 190)
                Text("✦").font(.system(size: 35)).foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.85)).position(x: 357, y: 48)
            }.frame(width: 420, height: 285).scaleEffect(scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }.clipped().accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Хорошие идеи\nначинаются здесь."))
            .accessibilityIdentifier("welcome.artwork")
    }
    private var videoTile: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                person("АК", fill: Color(red: 0.87, green: 0.86, blue: 0.95), ink: Color(red: 0.36, green: 0.32, blue: 0.58))
                person("МИ", fill: Color(red: 0.84, green: 0.90, blue: 0.94), ink: Color(red: 0.30, green: 0.48, blue: 0.57))
            }.frame(height: 123)
            HStack(spacing: 13) {
                callIcon("video", danger: false); callIcon("mic", danger: false); callIcon("phone.down", danger: true)
            }.frame(height: 30)
        }.padding(5).frame(width: 220, height: 168)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: MSTheme.ink.opacity(0.08), radius: 16, y: 10)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    Circle().fill(MSTheme.success).frame(width: 5, height: 5)
                    Text(tr("Встреча команды")).font(.custom("Inter-Regular", size: 8)).foregroundStyle(MSTheme.muted)
                }.padding(7).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 6)).offset(x: 12, y: -12)
            }
    }
    private func person(_ initials: String, fill: Color, ink: Color) -> some View {
        ZStack(alignment: .bottom) {
            fill
            Ellipse().fill(Color.white.opacity(0.22)).frame(width: 94, height: 90).offset(y: 40)
            Circle().fill(Color.white.opacity(0.22)).frame(width: 42, height: 42).offset(y: -35)
            Text(initials).font(.custom("Inter-SemiBold", size: 30)).tracking(-2).foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func callIcon(_ icon: String, danger: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(danger ? MSTheme.danger : MSTheme.muted)
            .frame(width: 23, height: 23).background(danger ? MSTheme.danger.opacity(0.10) : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ConnectView: View {
    static let continueID = "continueToLogin"
    @Bindable var model: AppModel
    let showsBack: Bool
    @State private var address = ""
    @FocusState private var editingAddress: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(step: "01 / ПОДКЛЮЧЕНИЕ", title: "Где ваша\nкоманда?", subtitle: "Введите адрес сервера MeetSpace. Его можно узнать у администратора команды.")
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Адрес сервера")).font(MSTheme.font(12, weight: .semibold))
                TextField("https://meet.example.com", text: $address).msURLInput()
                    .focused($editingAddress).submitLabel(.go)
                    .textFieldStyle(.plain).padding(14).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(tr("Адрес сервера")).accessibilityIdentifier("serverURL")
                    .onSubmit(checkAddress)
                    .onChange(of: address) { _, _ in model.addressChanged() }
                Label(tr("Защищённое подключение по HTTPS"), systemImage: "lock.shield").font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            if model.probeState == .loading {
                HStack { ProgressView(); Text(tr("Проверяем сервер…")) }.accessibilityIdentifier("serverLoading")
            }
            if let error = model.connectionError {
                Label(tr(error.message), systemImage: error == .offline ? "wifi.slash" : "exclamationmark.circle")
                    .foregroundStyle(MSTheme.danger).font(MSTheme.font(12)).accessibilityIdentifier("serverError")
            }
            if model.probeState == .content {
                Label(tr("Сервер ответил. Можно перейти ко входу."), systemImage: "checkmark.shield")
                    .foregroundStyle(MSTheme.success).accessibilityIdentifier("serverVerified")
                Text(tr("Проверка версии не подтверждает доступность всех функций.")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                Button(tr("Перейти ко входу")) {
                    editingAddress = false
                    Task { await model.continueToLogin() }
                }.buttonStyle(MSButtonStyle()).id(Self.continueID)
            } else {
                Button(tr("Проверить адрес"), action: checkAddress).buttonStyle(MSButtonStyle())
                    .disabled(model.probeState == .loading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("checkServer")
            }
            if showsBack { Button(tr("Назад")) { model.show(.welcome) }.frame(minHeight: 44) }
        }.onAppear { if address.isEmpty { address = model.connectionPrefill?.url.absoluteString ?? "" } }
    }

    private func checkAddress() {
        editingAddress = false
        guard model.probeState != .loading, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.checkServer(address)
    }
}

extension AppModel.ConnectionError {
    var message: String {
        switch self {
        case .invalidURL: "Укажите HTTPS-адрес без логина, пути, параметров и фрагмента."
        case .offline: "Сервер недоступен. Проверьте сеть и адрес."
        case .timeout: "Сервер не ответил вовремя. Повторите проверку."
        case .tls: "Не удалось проверить защищённое соединение. Проверьте сертификат сервера."
        case .redirect: "Сервер перенаправляет запрос. Введите конечный HTTPS-адрес."
        case .incompatible: "Не удалось получить совместимый ответ MeetSpace. Проверьте адрес."
        case .storage: "Не удалось сохранить адрес сервера. Повторите попытку."
        }
    }
}

private struct AuthenticationView: View {
    @Bindable var model: AppModel
    let registration: Bool
    private enum Field: Hashable { case name, email, password, confirmation }
    @FocusState private var focusedField: Field?
    // Passwords live only in the form and the in-flight request.
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmation: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeading(step: "02 / ВХОД В ПРОСТРАНСТВО", title: registration ? "Создайте аккаунт." : "С возвращением.", subtitle: "Ваша команда уже здесь.")
            HStack {
                Label(model.authenticationServer?.displayName ?? "MeetSpace", systemImage: "checkmark.shield")
                Spacer(); Button(tr("Изменить")) { model.show(.connect, server: model.authenticationServer) }
            }.font(MSTheme.font(12)).msCard(padding: 12)
            if registration {
                field("Имя") {
                    TextField(tr("Имя"), text: $name)
                        .focused($focusedField, equals: .name).submitLabel(.next)
                        .onSubmit { focusedField = .email }
                }
            }
            field("Электронная почта") {
                TextField("name@example.com", text: $email).msEmailInput()
                    .textContentType(registration ? .emailAddress : .username)
                    .focused($focusedField, equals: .email).submitLabel(.next)
                    .onSubmit { focusedField = .password }
            }
            field("Пароль") {
                SecureField(tr("Пароль"), text: $password)
                    .textContentType(registration ? .newPassword : .password)
                    .focused($focusedField, equals: .password).submitLabel(registration ? .next : .go)
                    .onSubmit {
                        if registration { focusedField = .confirmation }
                        else { submit() }
                    }
            }
            if registration {
                field("Повторите пароль") {
                    SecureField(tr("Повторите пароль"), text: $confirmation)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmation).submitLabel(.go)
                        .onSubmit(submit)
                }
            }
            if registration { Text(tr("Пароль: от 8 до 128 символов. Имя: до 100 символов.")).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
            if let error = model.identity.error { Text(tr(error)).foregroundStyle(MSTheme.danger).accessibilityIdentifier("authenticationError") }
            if let information = model.identity.information { Text(tr(information)).foregroundStyle(MSTheme.success) }
            if model.identity.busy { ProgressView().accessibilityLabel(tr("Выполняем вход…")) }
            Button(tr(registration ? "Зарегистрироваться" : "Войти"), action: submit)
                .buttonStyle(MSButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier("authenticationSubmit")
            Button(tr(registration ? "У меня уже есть аккаунт" : "Создать аккаунт")) { model.show(registration ? .login : .register) }.frame(minHeight: 44)
            if !registration, !model.identity.index.accounts.isEmpty {
                Menu(tr("Сохранённые аккаунты")) {
                    ForEach(model.identity.index.accounts) { account in
                        Button("\(account.user.name) · \(account.server.displayName)") {
                            Task { await model.identity.switchAccount(account) }
                        }
                    }
                }.frame(minHeight: 44)
            }
        }.disabled(model.identity.busy)
            .onChange(of: focusedField) { _, field in
                if field != nil { model.identity.error = nil }
            }
            .onDisappear { password = ""; confirmation = "" }
    }

    private var canSubmit: Bool {
        !model.identity.busy && !email.isEmpty && !password.isEmpty &&
            (!registration || (confirmation == password && password.unicodeScalars.count >= 8))
    }

    private func submit() {
        guard canSubmit else { return }
        // Capture what was submitted before the keyboard or a screen transition can change the fields.
        Task { [server = model.authenticationServer, email, password, name, confirmation] in
            if registration {
                if await model.identity.register(server: server, email: email, password: password, confirmation: confirmation, name: name) {
                    model.show(.login)
                }
            } else {
                await model.identity.login(server: server, email: email, password: password)
            }
        }
        focusedField = nil
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(label)).font(MSTheme.font(12, weight: .semibold))
            content().textFieldStyle(.plain).padding(14).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel(tr(label))
        }
    }
}

struct StepHeading: View {
    let step: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr(step)).font(MSTheme.font(10, weight: .semibold)).tracking(1.8).foregroundStyle(MSTheme.accent)
            Text(tr(title)).font(MSTheme.font(32, weight: .semibold, relativeTo: .largeTitle)).tracking(-1.1)
            Text(tr(subtitle)).foregroundStyle(MSTheme.muted)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
