# Этап 03: авторизация, чаты и файлы

Дата: 2026-11-05. Реализация по `03_AUTH_CHATS_FILES.md` в репозитории
`janickiy/meetspace_ios_mobile`, указанном пользователем. Backend не изменён.
Этап 04 не выполнялся.

## Источники

| Источник | Коммит | Что использовано |
| --- | --- | --- |
| backend `janickiy/meet-space` | `0bd1248a2411842515af4e02f1e95821616748fb` | Auth/session cookies, conversations, messages/attachments, user WebSocket |
| Android `janickiy/meet-space-android` | `b8f289983e60671d415a128734c2e5bb6e93a29d` | До 5 аккаунтов на сервере, изоляция сессий, сценарии переписки |
| Макеты `janickiy/mobile_maket` | `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3` | `onboarding.js`, `chat-refresh.js`, `groups.js`, палитра и типографика |

У backend со времени аудита изменился только README; runtime-код совпадает с
зафиксированным аудитом `56a0b07`. Исходные checkout этапа 01 сохранены.
Макеты присутствуют: прежняя оговорка задания о пустом `mobile_maket` не применяется.
Inter, цвета и общие компоненты переиспользованы из этапа 02.

## Реализовано

- Регистрация отдельно от входа, login/logout/refresh/restore. Аккаунты доступны
  из профиля и формы входа; до 5 на каждом HTTPS-origin.
- Личные чаты и группы: список, поиск/фильтры, unread, история по курсору,
  отправка, ответы, редактирование/удаление собственных сообщений, поиск сообщений.
- Группы: создание, название/описание, выбор/добавление/удаление участников, роли,
  передача владения, выход и удаление. Сервер остаётся источником прав.
- User WebSocket с одноразовым ticket, backoff/jitter, deduplication,
  остановкой в background и REST-сверкой после новой подписки.
- Нативный fileImporter, security-scoped/coordinated чтение, отдельная копия
  перед upload; init → binary PUT → finalize, прогресс, отмена и повтор.
  Download проверяет размер/SHA-256; сохранение/передача через системный ShareLink.
- До 5 файлов по 1…10 MiB; имя до 180 Unicode scalar, запрет traversal,
  разделителей/управляющих символов; MIME map из 124 расширений backend.

Реальные аккаунты и демо разделены. Встречи в аккаунте не подменяются демо-данными.

## Архитектура и совместимость

`AppDependencies` инъецирует account index, HTTP/socket factories, Keychain и
configuration store. `IdentityModel` сериализует изменения identity.
У каждого аккаунта новые `AuthenticatedClient` и `MessagingModel` с неизменяемыми
origin/account. Переключение останавливает предыдущий workspace; его ответы
не могут изменить новый. Временные файлы разделены по server/account, исключены
из backup и очищаются при смене/выходе. На iOS используется `completeFileProtection`.

Keychain хранит bearer и cookie; UserDefaults — только настройки и публичную
метаинформацию аккаунтов. Пароли очищаются после входа/ухода с формы.
Исходники не логируют запросы, tickets, signed URLs или credentials.

Refresh single-flight; HTTP 401 допускает один refresh и один повтор. Повторный 401
завершает выбранную сессию. 403/offline не удаляют другие credentials.
Logout отменяет и дожидается refresh-записи, затем удаляет Keychain-запись.
Offline logout не выдаёт локальное удаление за подтверждённый сервером отзыв.

Cookie `meetrix_account_<uuid>` / `meetrix_session` передаётся только в auth
выбранного аккаунта; refresh/logout используют lowercase `userId`.
URLSession cookie jar отключён. Обычный REST использует bearer; signed object-store
download получает отдельный transport без cookie/bearer. Перенаправления запрещены.
Production transport требует HTTPS/WSS с системной TLS-проверкой, ATS exceptions нет.

Publisher отправляет `message.created/updated/deleted` без `chat.`.
`sequence` — JSON-строка, читается как Int64. `MessageTimeline` объединяет REST/WS
по ID/версии, не воскрешая удалённое сообщение старой страницей.
Повтор отправки сохраняет `clientRequestId`. После reconnect загружается свежая
первая страница; более ранние страницы доступны повторной пагинацией. Replay у сервера нет.

Для файлов группы `authenticated: true` допускает только точный путь вложения
текущего чата/origin. Для личного чата signed URL скачивается без API credentials.
Потеря finalize-ответа не приводит к повторному PUT готового вложения.
Download ограничен во время чтения; небольшой файл не обрезает JSON ошибки 401/403.
Незавершённые объекты удаляет сервер по TTL; выдуманный DELETE API не добавлялся.

## Файлы

| Область | Основные файлы |
| --- | --- |
| DTO/валидация/слияние | `Sources/Core/{Account,Messaging,FilePolicy,AppState}.swift` |
| Auth/REST/файлы | `Sources/API/{Authentication,MessagingRepository,RequestTransport}.swift` |
| Хранение | `Sources/Storage/{AccountPreferencesStore,AccountFileStore}.swift`; существующий `KeychainStore.swift` |
| Realtime | `Sources/Realtime/{UserRealtime,RealtimeEndpoint}.swift` |
| Состояние | `Sources/Features/{AppModel,IdentityModel,MessagingModel}.swift` |
| UI | `Sources/Features/{LiveMessagesView,ConversationForms,LiveProfileView,MeetSpaceRootView,WorkspaceView,DestinationView}.swift` |
| Локализация | `Sources/DesignSystem/Resources/ru.lproj/Localizable.strings` |
| Тесты | `Tests/IntegrationTests/{Stage03Tests,SessionWorkspaceTests,TransportBoundaryTests,RealtimeLifecycleTests,LoopbackContractTests}.swift` |
| iOS UI doubles/tests | `App/UITestDependencies.swift`, `Tests/MeetSpaceUITests/FoundationUITests.swift` |
| Повтор реального контракта | `scripts/run_backend_contract.py` |

`Sources/` и `Tests/IntegrationTests/` относятся к `Packages/MeetSpaceKit/`.

## Проверки

| Критерий | Статус | Доказательство / граница |
| --- | --- | --- |
| Register/login/logout/refresh/restore | PASS | Два аккаунта настоящего backend, refresh, новый клиент из сохранённых credentials, отзыв только выбранной сессии |
| Keychain / preferences | PASS для проверенного кода | Hosted Keychain round trip/scoped deletion; индекс не содержит credentials; отсутствие логирования секретов |
| 401 / logout во время refresh | PASS | 12 конкурентных запросов, один refresh; ограниченный retry; задержанная запись завершается до удаления |
| Смена аккаунта/чата | PASS | Запоздалая история не меняет другой чат; старый workspace закрывается; credentials второго аккаунта сохраняются |
| Сообщения / группы / права | PASS | Реальный API: idempotency, reply/edit/search/read/delete, 403 на чужое редактирование, owner transfer/leave/delete |
| Два клиента и reconnect | PASS | WS после pong deadline, разрыв одного клиента, 53 сообщения offline, REST pagination + новый WS, отсутствие дублей |
| Realtime lifecycle | PASS | Новые tickets, backoff, event-ID dedup между соединениями, отсутствие reconnect после finish |
| Файлы | PASS для проверенных сценариев | Реальные direct/group upload/download; повтор ready upload; SHA mismatch, scope escape, cancel до finalize, download limit/progress/cancel |
| Host tests | PASS | 42 прошедших теста; 1 opt-in backend test пропущен обычным запуском и выполнен отдельно |
| Release iOS build | PASS | Generic iOS Simulator, Xcode 16.4, workflow `42029748386` |
| iPhone/iPad UI tests | PASS | На каждой платформе 1 Keychain + 9 UI tests, 0 failures |
| UI по макетам | PASS для основы; BLOCKED для полной приёмки | Palette/Inter/компоненты и сценарии, нативные скриншоты просмотрены; полная pixel parity и ручной VoiceOver не заявляются |
| Устройство / deployment TLS / iCloud | BLOCKED для device acceptance | Нет signing team/устройства и тестового HTTPS deployment |

PASS относится к указанному сценарию, а не ко всем серверам, сетям и устройствам.

### Зафиксированный результат

Проверенный iOS source commit: `3f82abeb438432990eb516d6315b448064c4384d`.
[GitHub Actions: все три jobs успешны](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42029748386).
В последующем evidence-коммите изменены только документация, журналы, скриншоты
и воспроизводимый backend harness; Swift/app/UI test sources совпадают с проверенным коммитом.

- [Манифест исходников и MIME map](evidence/stage03/source-manifest.json).
- [Локальные unit-тесты](evidence/stage03/host-tests.txt).
- [Реальный backend contract](evidence/stage03/backend-contract.txt) и
  [образы контейнеров](evidence/stage03/backend-runtime.json).
- [CI manifest](evidence/stage03/ci-run.json), [package/Release](evidence/stage03/ci-package.txt),
  [iPhone](evidence/stage03/ci-iphone.txt), [iPad](evidence/stage03/ci-ipad.txt).
- [Нативные скриншоты](evidence/stage03/native-previews/): по 5 на каждое семейство —
  ошибка входа, список чатов, переписка, профиль, участники группы.

Устройства CI: iPhone SE (3rd generation) и iPad mini (A17 Pro), iOS/iPadOS 18.5.
Логи Swift Testing считают 43 теста, включая один opt-in пропуск; фактически
прошли 42. Пропущенный в CI тест настоящего backend отдельно прошёл локально.
UI-тесты используют только DEBUG doubles; 401 вводится отдельным launch argument.
Неверный пароль дополнительно проверен на настоящем backend. Скриншоты doubles
не выдаются за подключение симулятора к реальному серверу.

### Фактические команды

Локально Command Line Tools, без полного Xcode:

```sh
swift build --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
python3 scripts/verify_foundation.py
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
git diff --check
python3 scripts/run_backend_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-ios-stage03/accepted-contract
```

Последняя команда собирает неизменённый Go backend для Linux и запускает свои
Postgres, Redis, MinIO, RabbitMQ и API в отдельной Docker network; host ports
публикуются только на loopback. После проверки удаляются только контейнеры,
volumes и network этого запуска. Данные/сервисы пользователя не используются.
Секреты генерируются в памяти и не входят в evidence.

`go-recorder-minio:local` — образ из `dockers/minio/Dockerfile` backend.
На другом компьютере сначала собрать этот образ из pinned checkout:

```sh
docker build -f /path/to/backend/dockers/minio/Dockerfile \
  -t go-recorder-minio:local /path/to/backend
python3 scripts/run_backend_contract.py --backend /path/to/backend
```

Только `LoopbackContractTests.swift` содержит явный тестовый adapter
HTTPS→HTTP / WSS→WS для loopback. Он не входит в приложение.
Проверка подтверждает wire contract, а не TLS production deployment.

В GitHub Actions:

```sh
swift test --package-path Packages/MeetSpaceKit
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/ci_simulators.py --family iPhone
python3 scripts/ci_simulators.py --family iPad
```

## Ограничения

1. История и неотправленные черновики — в памяти. Persistent offline outbox
   после завершения процесса не добавлен.
2. Background останавливает WS; foreground подписывается заново и сверяет REST.
   Push/background delivery относятся к следующим этапам.
3. Отмена upload не удаляет уже принятый сервером объект: действует серверный TTL.
4. Нужны проверки реального iCloud/File Provider, locked-device, VoiceOver,
   landscape/Split View и HTTPS deployment. Симулятор их не заменяет.
5. Формы групп/аккаунтов адаптированы нативно; отсутствующие в прототипе
   iOS picker/error/permission состояния не выдаются за точные копии.
6. Звонки, WebRTC, запись, push, SSH, signing/App Store metadata и production
   readiness не входят в подтверждённый результат этапа.
