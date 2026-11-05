# Этап 02: соответствие интерфейса

Источник — `mobile_maket@04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`,
`meetspace-refresh-20261016/preview.html` и актуальная цепочка CSS/JS.
Проверенные ссылки и исходная матрица: [SCREEN_MATRIX](SCREEN_MATRIX.md).
Макеты существуют; отсутствие макетов не используется как причина пропустить UI.

**Реализована основа, а не полное визуальное и функциональное равенство прототипу.**
Глобальная палитра, Inter, три вкладки, карточки, вложенные разделы и широкая компоновка
перенесены. Иконки используются системные SF Symbols; HTML-иконки не заявлены как
пиксельно идентичные. Нативные поля, picker, navigation bar и календарь отличаются
от web-прототипа. Сверка реальных iOS-скриншотов BLOCKED без Xcode.

`UI` означает существующий SwiftUI-экран. `Каркас` означает нейтральное обозначение
недоступного сценария, а не утверждение о выполненной установке/звонке.

| ID макета | Источник JS | SwiftUI | Реализовано / остаётся |
| --- | --- | --- | --- |
| `welcome` | onboarding | `OnboardingView`, `WelcomeView` | UI: две серверные опции, demo link, hero, боковая панель. Hero упрощён; точное совпадение декоративной композиции не заявлено |
| `connect` | onboarding | `ConnectView` | UI + реальный GET /version, ошибки URL/TLS/сети/redirect, cancel; приглашения по ссылке не разбираются |
| `login` | onboarding | `AuthenticationView` | UI email/password/server, переход к регистрации. Submit отключён до этапа auth; reset-password отсутствует в API |
| `register` | onboarding | `AuthenticationView` | UI имя/email/password/confirmation. Submit отключён; серверная валидация будет подключена с auth |
| `meetings` | meetings, workspace-refresh | `MeetingsView` | UI, status tabs, локальный поиск, карточки, детали, новые/планируемые встречи. Не все фильтры и модальные состояния прототипа перенесены |
| `messages` | screens, chat-refresh | `MessagesView` | UI списка, поиск по fixture-именам, двухколоночный режим; actions/group management/scopes будут расширены |
| `settings` | account-settings, notifications, accounts | `ProfileView`, `SettingsDetailView` | UI разделов; тема реально сохраняется. AV, notifications, профиль и account CRUD не подключены |
| `thread` | chat-refresh, groups | `ThreadView` | UI bubbles, composer, переход к preview звонка. Отправка, reply/edit/delete/pins/files не реализованы |
| `calendar` | screens, meetings | `CalendarScreen` | Нативный выбор даты и переход к планированию; timeline/OAuth не подключены. Нативный picker — визуальное отличие |
| `recordings` | recordings-refresh | `LibraryView` | UI списка и поиска fixture-записей. Нет серверной пагинации, grid/filter/sort и удаления |
| `recording` | recordings-refresh | `LibraryView` | UI обложки/метаданных, явное отсутствие медиа. Transcript/AI недоступны по аудиту |
| `folders` | folders-refresh | `LibraryView` | UI списка личных папок чатов/встреч. Это не файловые каталоги; server CRUD, подбор элементов и detail ещё не подключены |
| `prejoin` | screens, call-meeting | `CallPreviewView` | UI предварительного просмотра с выключенными устройствами; не запрашивает permissions, не подключает комнату |
| `call` | call-meeting | `CallPreviewView` | UI participant tiles и недоступных AV controls. Чат встречи, роли, admission и запись не реализованы |
| `personal-call` | personal-call | `CallPreviewView` | UI аватара и controls, закрытие preview. Incoming/outgoing/connected lifecycle не реализован |
| `deploy` | onboarding | `DeploymentPlaceholder` | Каркас; SSH credentials не запрашиваются. Формы и SSH нужны на соответствующем этапе |
| `fingerprint` | onboarding | `DeploymentPlaceholder` | Каркас; вымышленных отпечатков и trust-success нет |
| `preflight` | onboarding | `DeploymentPlaceholder` | Каркас; серверные проверки не имитируются |
| `install` | onboarding | `DeploymentPlaceholder` | Каркас; процесс/логи установки не имитируются |
| `complete` | onboarding | `DeploymentPlaceholder` | Каркас; успех развёртывания не заявляется |
| `install-error` | onboarding | `DeploymentPlaceholder` | Каркас; реальная SSH-ошибка ещё не подключена |

К экранам preview/каркасам есть доступ через Профиль → Каталог экранов.
Демо fixtures взяты из прототипа; набор сокращён. Использование fixture-участника
или организатора не даёт реальных прав. Баннер демо сохраняется при переходах.

## Состояния, темы, шрифты

Общие loading/empty/error/offline реализованы нейтрально с текущими токенами и
доступны через Профиль → Состояния интерфейса. Для этих состояний в исходниках нет
полного утверждённого набора нативных макетов: точная visual parity BLOCKED.

Палитра соответствует конечному `workspace-refresh.css`, радиусы карточек 14–16 pt,
кнопок 12 pt. Text styles масштабируются через `Font.custom(... relativeTo:)`.
Нативные Inter-Regular/SemiBold взяты из Android на audited commit; лицензия OFL
сохранена рядом. [Происхождение и SHA-256](evidence/stage02/resource-manifest.json).
Это снимает вопрос native font assets из отчёта этапа 01, но не заменяет iOS visual QA.

191 строка вынесена в `ru.lproj/Localizable.strings`; базовая локаль — русский.
В доступных макетах нет утверждённого английского комплекта. EN **BLOCKED для
продуктового утверждения**; английская локализация не заявляется. Инфраструктура
позволяет добавить `en.lproj` без переписывания экранов. Текущий RU fallback осознанный.

## Фактическая визуальная проверка

`FoundationPreviewRenderer` создаёт NSHostingView с теми же SwiftUI-компонентами.
Проверены welcome 390×844 и 1194×834, meetings 390×844 и 834×1194 (dark),
messages 1194×834 (dark), profile 390×844 с запрошенным accessibility3.
Размеры в points; PNG на этом хосте имеют backing scale 2.

Это macOS-рендеры компонентов без iOS safe areas, статус-бара и полного root navigation.
macOS не подтверждает реальное масштабирование Dynamic Type iOS. ImageRenderer был
заменён на NSHostingView, поскольку пропускал ScrollView/TextField; пустые первые
рендеры не используются как доказательство. Скрипт доступен для повторения;
репрезентативные изображения сохранены в `evidence/stage02/previews/`.

До закрытия visual acceptance нужны iPhone/iPad screenshots light/dark, портрет/landscape,
Split View, большие шрифты, VoiceOver и сверка каждого недостающего состояния.
Наличие доступного макета и отсутствие реализованного состояния явно отражены выше;
пиксельное соответствие 21 экрана не заявляется.
