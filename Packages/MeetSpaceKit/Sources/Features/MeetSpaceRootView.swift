import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

public struct MeetSpaceRootView: View {
    @Bindable private var model: AppModel
    @State private var restored: Bool = false
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            if model.isDemo { WorkspaceView(model: model) }
            else { OnboardingView(model: model) }
        }
        .font(MSTheme.font()).foregroundStyle(MSTheme.ink).tint(MSTheme.accent)
        .buttonStyle(MSTextButtonStyle())
        .preferredColorScheme(colorScheme)
        .background(MSTheme.background)
        .task {
            guard !restored else { return }
            restored = true; await model.restore()
        }
        .alert(tr("MeetSpace"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(tr("Понятно"), role: .cancel) { model.notice = nil }
        } message: { Text(tr(model.notice ?? "")) }
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
            let wide = proxy.size.width >= 800 && !typeSize.isAccessibilitySize
            HStack(spacing: 0) {
                if wide { OnboardingAside().frame(maxWidth: .infinity, maxHeight: .infinity) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 10) {
                            BrandMark().frame(width: 32, height: 34)
                            Text("MeetSpace").font(MSTheme.font(21, weight: .semibold))
                            Spacer()
                            if model.onboarding != .welcome {
                                IconButton("xmark", label: "На главную") { model.show(.welcome) }
                            }
                        }
                        .padding(.bottom, wide ? 30 : 12)
                        switch model.onboarding {
                        case .welcome: WelcomeView(model: model, showArtwork: !wide)
                        case .connect: ConnectView(model: model)
                        case .login: AuthenticationView(model: model, registration: false)
                        case .register: AuthenticationView(model: model, registration: true)
                        }
                    }.padding(wide ? 44 : 24).frame(maxWidth: 510)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(MSTheme.surface)
            }.background(MSTheme.background)
        }
    }
}

private struct WelcomeView: View {
    @Bindable var model: AppModel
    let showArtwork: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(tr("ЕДИНОЕ ПРОСТРАНСТВО")).font(MSTheme.font(10, weight: .semibold, relativeTo: .caption)).tracking(2).foregroundStyle(MSTheme.accent)
            Text(tr("Команда ближе.\nИдей больше.")).font(MSTheme.font(34, weight: .semibold, relativeTo: .largeTitle)).tracking(-1.1).fixedSize(horizontal: false, vertical: true)
            Text(tr("MeetSpace — единое пространство для встреч и общения.")).foregroundStyle(MSTheme.muted)
            if showArtwork && !typeSize.isAccessibilitySize { WelcomeArtwork().frame(height: 155).padding(.vertical, 4) }
            connectionChoice("Подключиться к серверу", subtitle: "У меня уже есть адрес MeetSpace", icon: "network", primary: true) { model.show(.connect) }
                .accessibilityIdentifier("connectServer")
            connectionChoice("Развернуть свой сервер", subtitle: "Создать пространство на своём VPS", icon: "server.rack", primary: false) {
                model.enterDemo(); model.navigate(.deploy)
            }
            HStack {
                feature("video", "Встречи"); Spacer(); feature("bubble.left", "Сообщения"); Spacer(); feature("lock.shield", "Ваш сервер")
            }.padding(.top, 6)
            Button(tr("Посмотреть интерфейс")) { model.enterDemo() }
                .font(MSTheme.font(13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("openDemo")
        }
    }
    private func connectionChoice(_ title: String, subtitle: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(title)).font(MSTheme.font(14, weight: .semibold))
                    Text(tr(subtitle)).font(MSTheme.font(11, relativeTo: .caption)).opacity(0.8)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0); Image(systemName: "arrow.right")
            }.padding(16).frame(maxWidth: .infinity, minHeight: 66)
                .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
                .background(primary ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(primary ? Color.clear : MSTheme.line))
        }.buttonStyle(.plain)
    }
    private func feature(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(MSTheme.accent)
            Text(tr(title)).font(MSTheme.font(10, relativeTo: .caption)).foregroundStyle(MSTheme.muted)
        }.accessibilityElement(children: .combine)
    }
}

private struct OnboardingAside: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { BrandMark().frame(width: 36, height: 38); Text("MeetSpace").font(MSTheme.font(22, weight: .semibold)) }
            Spacer(minLength: 20)
            Text(tr("БЛИЖЕ К КОМАНДЕ.")).font(MSTheme.font(11, weight: .semibold)).tracking(2).foregroundStyle(MSTheme.accent)
            Text(tr("Быть на одной\nволне.")).font(MSTheme.font(46, weight: .semibold, relativeTo: .largeTitle)).tracking(-1.5)
            Text(tr("Встречи, сообщения и идеи — в вашем пространстве.")).foregroundStyle(MSTheme.muted)
            WelcomeArtwork().frame(height: 240)
            Spacer(minLength: 20)
            Label(tr("Ваше пространство. Ваши правила."), systemImage: "lock.shield").font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }.padding(44).background(MSTheme.accentSoft)
    }
}

private struct WelcomeArtwork: View {
    var body: some View {
        ZStack {
            Ellipse().stroke(MSTheme.accent.opacity(0.16), lineWidth: 1).rotationEffect(.degrees(-16)).padding(.horizontal, 4)
            HStack(spacing: 8) {
                VStack(spacing: 14) {
                    HStack { Avatar("АК", size: 48); Avatar("МИ", size: 48) }
                    HStack(spacing: 18) {
                        Image(systemName: "video.fill"); Image(systemName: "mic.fill")
                        Image(systemName: "phone.down.fill").foregroundStyle(MSTheme.danger)
                    }.font(.system(size: 13))
                }.padding(20).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 18)).rotationEffect(.degrees(-5))
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(MSTheme.accent)
                    Text(tr("Хорошие идеи\nначинаются здесь.")).font(MSTheme.font(11, weight: .semibold))
                }.padding(14).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 14)).rotationEffect(.degrees(5))
            }
        }.accessibilityHidden(true)
    }
}

private struct ConnectView: View {
    @Bindable var model: AppModel
    @State private var address: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeading(step: "01 / ПОДКЛЮЧЕНИЕ", title: "Где ваша\nкоманда?", subtitle: "Введите адрес сервера MeetSpace. Его можно узнать у администратора команды.")
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Адрес сервера")).font(MSTheme.font(12, weight: .semibold))
                TextField("https://meet.example.com", text: $address).msURLInput()
                    .textFieldStyle(.plain).padding(14).background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(tr("Адрес сервера")).accessibilityIdentifier("serverURL")
                    .onSubmit { model.checkServer(address) }
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
                Button(tr("Перейти ко входу")) { Task { await model.continueToLogin() } }.buttonStyle(MSButtonStyle())
            } else {
                Button(tr("Проверить адрес")) { model.checkServer(address) }.buttonStyle(MSButtonStyle())
                    .disabled(model.probeState == .loading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("checkServer")
            }
            Button(tr("Назад")) { model.show(.welcome) }.frame(minHeight: 44)
        }.onAppear { if address.isEmpty { address = model.configuration.server?.url.absoluteString ?? "" } }
    }
}

private extension AppModel.ConnectionError {
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
    // Ephemeral view state only. No authentication operation is wired in stage 02.
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmation: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeading(step: "02 / ВХОД В ПРОСТРАНСТВО", title: registration ? "Создайте аккаунт." : "С возвращением.", subtitle: "Ваша команда уже здесь.")
            HStack {
                Label(model.configuration.server?.displayName ?? "MeetSpace", systemImage: "checkmark.shield")
                Spacer(); Button(tr("Изменить")) { model.show(.connect) }
            }.font(MSTheme.font(12)).msCard(padding: 12)
            if registration { field("Имя") { TextField(tr("Имя"), text: $name) } }
            field("Электронная почта") { TextField("name@example.com", text: $email).msEmailInput().textContentType(.emailAddress) }
            field("Пароль") { SecureField(tr("Пароль"), text: $password) }
            if registration { field("Повторите пароль") { SecureField(tr("Повторите пароль"), text: $confirmation) } }
            Label(tr("Вход и регистрация появятся на следующем этапе. Данные формы не отправляются."), systemImage: "info.circle")
                .font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Button(tr(registration ? "Зарегистрироваться" : "Войти")) {}.buttonStyle(MSButtonStyle()).disabled(true)
            Button(tr(registration ? "У меня уже есть аккаунт" : "Создать аккаунт")) { model.show(registration ? .login : .register) }.frame(minHeight: 44)
        }.onDisappear { password = ""; confirmation = "" }
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
