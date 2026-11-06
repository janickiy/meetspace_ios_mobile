# Этап 05 — прямые звонки, CallKit и уведомления

Реализация от 2026-11-06 использует существующий backend без изменений. Это результат
этапа разработки, а не подтверждение production-готовности звонков и Apple push.
Фактическая доставка APNs/VoIP и проверка на физических устройствах остаются BLOCKED.

## Поведение приложения

Из личного чата доступны аудио- и видеозвонки через две отдельные кнопки по 44 pt.
Это iOS-адаптация выбора типа звонка: в макете показана одна кнопка телефона.
При крупных accessibility-шрифтах действия переносятся в отдельный ряд. Один процесс содержит один CallKit
provider; каждому аккаунту создаётся отдельный координатор с новым clientId.
При входящем звонке user WebSocket инициирует REST-сверку и системный входящий экран.
Приём, отклонение, отмена и завершение используют существующие calls endpoints.
Повтор создания после неизвестного сетевого результата сохраняет clientRequestId.
Отмена во время незавершённого запроса сохраняется до его разрешения: поздний
ответ сервера не запускает CallKit или медиа; звонок отменяется либо завершается.
При неподтверждённой отмене доступна повторная проверка с безопасным повтором команды.
Состояние другого устройства отображается без доступа к его микрофону и камере.
В call DTO нет поля типа аудио/видео: входящий вызов первоначально заявляется как
аудиозвонок, камера включается только по локальному действию пользователя.

Принятый звонок подключается к закрытой direct_call SFU-комнате. Перед каждым
подключением проверяется accepted и владение clientId, затем используется разрешённый
self-participant endpoint и ticket с тем же clientId. Обычные meeting GET/join/leave
для этой комнаты не вызываются. CallKit action answer завершается после media.ready
и RTC connected; активацией аудиосессии управляет CallKit. При уходе в фон камера
выключается, активное аудио остаётся под системным управлением. При потере подтверждения
heartbeat локальное медиа выключается раньше серверного 45-секундного lease.
Смена аккаунта сначала закрывает звонок и медиа, затем старую сессию.

Экран использует опубликованные personal-call.css и previews макета: тёмная сцена,
аватар/видео собеседника, локальное превью, заголовок, таймер и управление.
Сворачивание возвращает предыдущий экран: для исходящего это открытый чат, для
входящего переписка собеседника автоматически не открывается. Добавлены серверные состояния входящего/отклонённого/пропущенного звонка,
неизвестного результата и ответа на другом устройстве. Демонстрация экрана из макета
не заявляется: вместо неё доступен выбор динамика; нативный screen sharing — отдельный этап.
Размеры кнопок адаптированы к iOS accessibility. Полная пиксельная идентичность не заявляется.

Обычные APNs включаются явно в профиле. Journal в отдельном Keychain item хранит
origin/userID/deviceID и SHA256 отпечаток, без delivery token. Регистрация и отзыв
сериализованы, сначала сохраняется намерение, затем receipt. Logout/switch отключает
OS-регистрацию и удаляет известные deviceID перед закрытием авторизованного клиента.
Неизвестный POST или неподтверждённый отзыв блокирует новые регистрации для всех
аккаунтов до очистки. Journal сохраняется после удаления аккаунта; повторный вход
на тот же сервер позволяет повторить отзыв. Приложение не удаляет другие устройства. При возвращении из Settings разрешение
перепроверяется без нового запроса; отзыв разрешения отключает локальную регистрацию
и запускает удаление своей привязки. Повторное разрешение не включает её автоматически.

PushKit реализован отдельным нативным adapter. Он не регистрируется в production,
пока нет проверенного серверного VoIP контракта. Resolver и отдельный registrar
требуются через DI; данные пуша нельзя интерпретировать по придуманным ключам.
Передача в CallKit синхронная, completion вызывается один раз. Обычные уведомления
не превращаются в VoIP-вызов, их URL не открывает произвольный сервер/аккаунт.

## Основные файлы

| Область | Файлы |
| --- | --- |
| Модели и контракт | `Sources/Core/DirectCall.swift`, `PushRegistration.swift`; `Sources/API/DirectCallsRepository.swift`, `NotificationDeviceRepository.swift` |
| Системные адаптеры | `Sources/Calling/SystemCalling.swift`, `NativeSystemCalling.swift`, `SystemCallEventHub.swift`, `NormalPushNotifications.swift`, `NativeNormalPushNotifications.swift`, `VoIPPushNotifications.swift`, `NativeVoIPPushNotifications.swift` |
| Жизненный цикл | `Sources/Features/DirectCallCoordinator.swift`, `PushRegistrationModel.swift`, `IdentityModel.swift`, `MessagingModel.swift`; `Sources/Storage/PushRegistrationStore.swift` |
| SFU/аудио | `Sources/Features/ConferenceSession.swift`; `Sources/Media/CallAudioSessionBridge.swift`, `NativeConferenceMediaEngine.swift`, `ConferenceMediaEngine.swift` |
| SwiftUI | `DirectCallView.swift`, `LiveMessagesView.swift`, `LiveProfileView.swift`, `MeetSpaceRootView.swift`, `ConferenceWorkspace.swift` в `Sources/Features` |
| Запуск и capabilities | `App/MeetSpaceAppDelegate.swift`, `MeetSpaceApp.swift`, `Info.plist`, `MeetSpace.entitlements`, генератор Xcode-проекта |
| Проверки | `Tests/IntegrationTests/*Call*Tests.swift`, `*Notification*Tests.swift`, `PushRegistrationLifecycleTests.swift`, hosted `CallAudioIntegrationTests.swift`, UI `FoundationUITests.swift`, `scripts/run_calls_contract.py` |

Пути `Sources` и `Tests/IntegrationTests` относятся к `Packages/MeetSpaceKit`.
Полный перечень изменений относительно этапа 4 — [changed-files.txt](evidence/changed-files.txt).

## Границы приёмки

| Критерий | Статус |
| --- | --- |
| Аудит фактического API, Android и опубликованных макетов | PASS — [контракт](CONTRACT_AUDIT.md) |
| Автоматические проверки модели, lifecycle, владения устройством и push journal | PASS — 121 тест Swift-пакета, включая регрессии прошлых этапов; 3 opt-in проверки с внешним backend пропущены в обычном запуске |
| Реальные calls REST/user WS/private SFU/device registration на одноразовом backend | PASS — 1 контрактный тест, 48.468 с; [результат](evidence/runtime-tests.txt), [хеши исходников](evidence/runtime-sources.json) |
| Компиляция native CallKit/PushKit/APNs adapters | PASS — Debug simulator tests и Release iOS Simulator build; подпись и системная доставка этим не подтверждаются |
| iPhone/iPad UI и hosted native tests | PASS — по 19/19: 15 UI и 4 hosted теста на каждом семействе; UI использует doubles |
| Входящий CallKit из настоящего APNs/VoIP в background/terminated | BLOCKED — отсутствуют серверный VoIP payload/token contract, APNs deployment и подписанные физические устройства |
| Реальные микрофон, камера, Bluetooth, lockscreen, interruption, iOS ↔ Android/Web | NOT_RUN на устройствах; симулятор это не заменяет |
| Ключи Apple на клиенте, изменение backend, использование VoIP для обычных уведомлений | Не выполнялись |

[Настройка и отдельное предложение серверных изменений](CALLKIT_APNS_SETUP.md)
содержит условия снятия блокеров и полную матрицу физических проверок. Следующий
этап не запускался. Нельзя отмечать весь этап production PASS по simulator-тестам.

## Зафиксированный результат CI

[GitHub Actions 42156868557](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42156868557)
завершился успешно на исходниках
[`b430f2b4fc0ecde1806966fc4cdfe3d7546f27b4`](https://github.com/janickiy/meetspace_ios_mobile/commit/b430f2b4fc0ecde1806966fc4cdfe3d7546f27b4).
После этого коммита добавлены только отчёт и evidence в `docs/stage05`;
код приложения, тестов, проекта и CI не менялся.

Среда: macOS 15.8.2, Xcode 16.4 (16F6), SDK 18.5; ARM64 Simulator runtime 26.2
(23C54). Устройства: iPhone SE (3rd generation), iPad mini (A17 Pro).
Swift-пакет: 124 зарегистрированных теста, 121 PASS и 3 opt-in SKIP.
Release: `BUILD SUCCEEDED`. На каждом симуляторе: 19 PASS, 0 FAIL, 0 SKIP.
Hosted набор проверяет Keychain, два сценария настоящего WebRTC с выключенным
capture и подготовку прямого звонка до CallKit audio activation.

[CI receipt](evidence/ci-run.json) содержит SHA, jobs, artifact digests и summaries.
Сохранены [package results](evidence/package-results.txt),
[iPhone results](evidence/iPhone-results.txt), [iPad results](evidence/iPad-results.txt),
исходные summaries [iPhone](evidence/iPhone-summary.json) и
[iPad](evidence/iPad-summary.json), а также [локальный Swift run](evidence/host-results.txt).

## Проверенные экраны

Просмотрены все 16 кадров из успешного CI: в этих portrait fixtures нет перекрытий
текста и основных действий. Это не полная проверка landscape, Dynamic Type,
VoiceOver или пиксельного соответствия макету. На компактном iPhone дополнительная
кнопка смены камеры находится ниже первого viewport прокручиваемого экрана звонка.
Надпись «Тестовое видео» обозначает media double, а «Переподключение…» в списке чатов —
состояние QuietSockets fixture, не измерение реального backend.
Происхождение и SHA256 каждого PNG сохранены в [screenshots.json](evidence/screenshots.json).

| Состояние | iPhone | iPad |
| --- | --- | --- |
| Кнопки аудио/видеозвонка в чате | [PNG](evidence/screenshots/iPhone-stage05-chat-call-actions.png) | [PNG](evidence/screenshots/iPad-stage05-chat-call-actions.png) |
| Входящий звонок | [PNG](evidence/screenshots/iPhone-stage05-incoming.png) | [PNG](evidence/screenshots/iPad-stage05-incoming.png) |
| Исходящий звонок | [PNG](evidence/screenshots/iPhone-stage05-outgoing.png) | [PNG](evidence/screenshots/iPad-stage05-outgoing.png) |
| Соединение и управление | [PNG](evidence/screenshots/iPhone-stage05-connected.png) | [PNG](evidence/screenshots/iPad-stage05-connected.png) |
| Свёрнутый баннер | [PNG](evidence/screenshots/iPhone-stage05-minimized.png) | [PNG](evidence/screenshots/iPad-stage05-minimized.png) |
| Завершение | [PNG](evidence/screenshots/iPhone-stage05-ended.png) | [PNG](evidence/screenshots/iPad-stage05-ended.png) |
| Ответ на другом устройстве | [PNG](evidence/screenshots/iPhone-stage05-other-device.png) | [PNG](evidence/screenshots/iPad-stage05-other-device.png) |
| Регистрация обычных уведомлений | [PNG](evidence/screenshots/iPhone-stage05-push-enabled.png) | [PNG](evidence/screenshots/iPad-stage05-push-enabled.png) |

## Команды воспроизведения

Статическая проверка и привязка аудита к checkout исходников:

```sh
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_foundation.py
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
git diff --check
```

Результат финального запуска: PASS воспроизводимости Xcode-проекта и foundation;
аудит сверил 120 source hashes, 124 design files и 156 route/group declarations;
`git diff --check` завершился с кодом 0. Это проверка целостности, не runtime-сертификация.

Локально, с установленными Command Line Tools и SDK 26.4:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Изолированный реальный backend/SFU, четыре тестовых аккаунта, без production-данных:

```sh
python3 scripts/run_calls_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage05-contract-03
```

Нужны Docker, Go, Swift и образы, указанные в runner. Каталог output должен быть
пустым. Одноразовые контейнеры/сеть удаляются в `finally`; локальные приватные логи
и бинарники остаются в output с ограниченными правами. В evidence включены только
безопасные результаты и хеши проверявшихся файлов. Generic HTTP gateway — fixture,
который не обращается к APNs/FCM. Stage 5 проверяет SFU allocation и закрытие
membership, а не RTP: [метрики](evidence/sfu-cleanup.json) показывают 2 созданных
PeerConnection, 0 активных комнат/пиров/tracks/subscriptions и 0 переданных пакетов.
RTP smoke этапа 4 остаётся отдельным результатом.

CI с полным Xcode выполняет:

```sh
swift test --package-path Packages/MeetSpaceKit
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/ci_simulators.py --family iPhone
python3 scripts/ci_simulators.py --family iPad
```

UI-тесты используют DEBUG doubles REST, CallKit, APNs и media. Hosted тесты загружают
настоящий WebRTC binary и проверяют SDP/жизненный цикл с выключенным capture. Ни один
из этих результатов не подтверждает доставку настоящего VoIP push, аппаратный звук
или способность проснуться из terminated на физическом устройстве.
