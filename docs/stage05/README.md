# Этап 05 — прямые звонки, CallKit и уведомления

Реализация от 2026-11-06 использует существующий backend без изменений. Это результат
этапа разработки, а не подтверждение production-готовности звонков и Apple push.
Фактическая доставка APNs/VoIP и проверка на физических устройствах остаются BLOCKED.

## Поведение приложения

Из личного чата доступны аудио- и видеозвонки. Один процесс содержит один CallKit
provider; каждому аккаунту создаётся отдельный координатор с новым clientId.
При входящем звонке user WebSocket инициирует REST-сверку и системный входящий экран.
Приём, отклонение, отмена и завершение используют существующие calls endpoints.
Повтор создания после неизвестного сетевого результата сохраняет clientRequestId.
Состояние другого устройства отображается без доступа к его микрофону и камере.

Принятый звонок подключается к закрытой direct_call SFU-комнате. Перед каждым
подключением проверяется accepted и владение clientId, затем используется разрешённый
self-participant endpoint и ticket с тем же clientId. Обычные meeting GET/join/leave
для этой комнаты не вызываются. CallKit action answer завершается после media.ready
и RTC connected; активацией аудиосессии управляет CallKit. При уходе в фон камера
выключается, активное аудио остаётся под системным управлением. При потере подтверждения
heartbeat локальное медиа выключается раньше серверного 45-секундного lease.
Смена аккаунта сначала закрывает звонок и медиа, затем старую сессию.

Экран использует опубликованные personal-call.css и previews макета: тёмная сцена,
аватар/видео собеседника, локальное превью, заголовок, таймер, управление и возврат
в чат. Добавлены серверные состояния входящего/отклонённого/пропущенного звонка,
неизвестного результата и ответа на другом устройстве. Демонстрация экрана из макета
не заявляется: вместо неё доступен выбор динамика; нативный screen sharing — отдельный этап.
Размеры кнопок адаптированы к iOS accessibility. Полная пиксельная идентичность не заявляется.

Обычные APNs включаются явно в профиле. Journal в отдельном Keychain item хранит
origin/userID/deviceID и SHA256 отпечаток, без delivery token. Регистрация и отзыв
сериализованы, сначала сохраняется намерение, затем receipt. Logout/switch отключает
OS-регистрацию и удаляет известные deviceID перед закрытием авторизованного клиента.
Неизвестный POST или неподтверждённый отзыв блокирует новые регистрации для всех
аккаунтов до очистки. Journal сохраняется после удаления аккаунта; повторный вход
на тот же сервер позволяет повторить отзыв. Приложение не удаляет другие устройства.

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

## Границы приёмки

| Критерий | Статус |
| --- | --- |
| Аудит фактического API, Android и опубликованных макетов | PASS — [контракт](CONTRACT_AUDIT.md) |
| Автоматические проверки модели, lifecycle, владения устройством и push journal | Результаты и точный проверенный commit фиксируются в итоговом evidence |
| Реальные calls REST/user WS/private SFU/device registration на одноразовом backend | Прогон выполнен; окончательное evidence фиксируется после проверки итогового кода |
| Native CallKit/PushKit/APNs adapters и iPhone/iPad UI | Сборка и simulator smoke фиксируются в итоговом evidence; doubles не доказывают системную доставку |
| Входящий CallKit из настоящего APNs/VoIP в background/terminated | BLOCKED — отсутствуют серверный VoIP payload/token contract, APNs deployment и подписанные физические устройства |
| Реальные микрофон, камера, Bluetooth, lockscreen, interruption, iOS ↔ Android/Web | NOT_RUN на устройствах; симулятор это не заменяет |
| Ключи Apple на клиенте, изменение backend, использование VoIP для обычных уведомлений | Не выполнялись |

[Настройка и отдельное предложение серверных изменений](CALLKIT_APNS_SETUP.md)
содержит условия снятия блокеров и полную матрицу физических проверок. Следующий
этап не запускался. Нельзя отмечать весь этап production PASS по simulator-тестам.
