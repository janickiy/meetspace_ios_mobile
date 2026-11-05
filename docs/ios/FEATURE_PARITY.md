# Соответствие функций backend, Android и будущего iOS

Дата: 2026-11-05. Коммиты и контрольные суммы — [манифест](evidence/source-manifest.json).
В этом этапе нет реализации iOS. «CONFIRMED» означает подтверждённый исходниками
контракт, «PARTIAL» — подтверждённую часть с конкретными пробелами,
«BLOCKED» — отсутствие необходимого контракта/материалов/проверки.
Ни одна строка не означает PASS сквозного сценария на устройстве.

## Матрица функций

| ID / функция | Backend | Android — найденная реализация | Решение для iOS / статус |
| --- | --- | --- | --- |
| F01 Свой сервер и приглашение | `/version`, invite lookup, auth | [ServerOrigin][A-origin], [MeetSpaceApi][A-api] | CONFIRMED: HTTPS origin, сервер вводит пользователь, проверка версии/контрактов |
| F02 Регистрация, login, logout, refresh | [Auth routes][B-platform], [sessions][B-sessions] | [API][A-api], [repository][A-repository], [cookie jar][A-cookies] | CONFIRMED: Keychain + изоляция cookie; register не выдаёт токен |
| F03 Несколько аккаунтов | Cookie account list/switch и независимые сессии [accounts][B-accounts] | Origin/account scoped repository; отмена старых операций | CONFIRMED: отдельные credentials/cache/socket scopes, переключение очищает прежний контекст |
| F04 Профиль, аватар, удаление | PATCH/DELETE me, avatar/content [routes][B-avatar-routes] | API + UI/AvatarEditorViewModel | CONFIRMED; password/email change и восстановление пароля BLOCKED |
| F05 Список/создание/история встреч | [platform routes][B-platform], [timeline][B-timeline] | [MeetingsApi][A-meetings], MeetingsViewModel | CONFIRMED: состояния сервера и cursor/offset не смешивать |
| F06 Планирование/приглашения | schedule + invitations [routes][B-invitations] | MeetingsApi, календарный UI | CONFIRMED для API; email delivery зависит от установки |
| F07 Гость, waiting room, admission, moderation | [guest][B-guest], [policy][B-moderation] | MeetingsApi, GuestMeetingUi, ParticipantManagement | CONFIRMED: guest scope, TTL из ответа, owner/co_host/participant различаются |
| F08 Личные и групповые чаты | Conversations + shared message routes [personal][B-personal], [chat][B-chat] | [MessagingApi][A-messaging], [repository][A-repository] | CONFIRMED: create/group members/roles/avatar, reply/edit/delete/read, персональное hide/clear |
| F09 Поиск, контекст, pins, файлы | [search][B-personal-search], [chat actions][B-chat-actions], [assets][B-personal-assets] | MessagingApi, MeetingChatApi, scoped user events | CONFIRMED; message reactions BLOCKED; offline queue — локальная функция, серверная идемпотентность есть |
| F10 Папки | [folder routes][B-folders] | MessagingApi/repository, folder UI | CONFIRMED: порядок, кандидаты и доступ к содержимому |
| F11 Видеовстреча, звук, камера | Conference WS + [media controller][B-media] | [CallEngine][A-engine], [CallProtocol][A-protocol], [CallAudio][A-audio] | PARTIAL: wire contract подтверждён, iOS WebRTC SDK/AVAudioSession/device test ещё не выбраны/не выполнены |
| F12 Личный звонок | [calls][B-calls], call.updated, direct-call room | [DirectCallsApi][A-calls], DirectCallViewModel + общий media engine | PARTIAL: foreground contract подтверждён; APNs/VoIP/CallKit wake-up BLOCKED |
| F13 Демонстрация экрана | SFU sources video/screen и audio/screen [model][B-media-model] | MediaProjection + [ScreenShareService][A-screen-share] | PARTIAL: медиаконтракт есть; ReplayKit extension/device proof BLOCKED |
| F14 Запись, библиотека, воспроизведение, файлы | [record routes][B-records], [library][B-record-library] | [RecordingsApi][A-records], [scoped access][A-record-access], player/files UI | CONFIRMED для modes/lifecycle/URL; PARTIAL для поиска библиотеки и платформенного плеера |
| F15 Календари | Timeline/schedule; OAuth connection/mapping [integration routes][B-integration-routes] | CalendarDashboard; наличие экрана не доказывает полный внешний OAuth flow | PARTIAL: календарь встреч подтверждён; iOS OAuth return/EventKit sync BLOCKED до отдельного сценария |
| F16 Inbox, notification preferences, push | Inbox/SSE/device registry + generic provider [integration service][B-integration-service] | [PushController][A-push], FCM при конфигурации; capability gating | PARTIAL: inbox/preferences CONFIRMED; APNs delivery BLOCKED; FCM не заменяет Apple provider |
| F17 SSH/preflight/установка | Это SSH/installer, не MeetSpace REST | [SSH transport][A-ssh], [preflight][A-preflight], [installer protocol][A-installer] | PARTIAL: Android protocol изучен; iOS SSH engine, bundled release verification и resume/device tests BLOCKED |
| F18 Темы, AV-настройки, звук уведомлений | В основном локальные preferences; REST только notification categories/channels | app settings, media device settings, [design][D-settings] | PARTIAL: интерфейс имеется, платформенные различия требуют реализации и измерений |
| F19 Transcript/AI/live captions/semantic search/analytics | Удалены [migration note][B-speech-removal], capability DTO без этих флагов | Остались API-методы [records][A-records], UI защищён capability flags [VM][A-record-vm] | BLOCKED: не копировать старые endpoints, не показывать demo-AI как результат сервера |
| F20 Реакции во встрече | [conference reactions][B-reaction-route] → reaction.created | Call panels/engine | CONFIRMED для встречи; это не реакции на сообщения F09 |
| F21 Административная сводка | GET admin/summary + isAdmin [routes][B-cap-routes] | Наличие глобального admin capability в user DTO | PARTIAL: read-only API есть, отдельного полного мобильного admin-макета нет |
| F22 Сброс пароля, смена email/пароля | Нет маршрутов в auth registration | Не считать любой settings UI подтверждением API | BLOCKED до согласованного серверного контракта |
| F23 Глобальный текстовый поиск | [search route][B-search-route] | Поиск отдельных доменов в data/UI | CONFIRMED для существующего HTTP; отдельная полнота UX iOS не проверена |

## Инвентаризация Android-модулей

Модули объявлены в [settings.gradle.kts][A-modules]: `app`, `core:model`,
`core:data`, `core:designsystem`, `core:ssh`, `core:media`.

| Модуль | Ответственность и опорные файлы | Что учитывать в Swift |
| --- | --- | --- |
| `app` | [MeetSpaceApplication][A-app] вручную собирает repositories/media/push; ViewModel и Compose Host для встреч/чатов/записей; permissions, ringtone, encrypted outbox, media services | Отдельный composition root, SwiftUI state на MainActor, зависимости через протоколы; не переносить Activity/Service lifetime напрямую |
| `core:data` | [MeetSpaceApi][A-api], специализированные API, [DefaultFoundationRepository][A-repository], [ServerOrigin][A-origin], [SessionCookieJar][A-cookies], [ScopedUserEvents][A-events], [ScopedCallSignaling][A-signaling], [ScopedRecordingAccess][A-record-access] | Async HTTP transport + actor сессии; single-flight refresh; account generation; bounded responses; отмена I/O; redirect/credential isolation |
| `core:media` | [CallEngine][A-engine] владеет peer/capture/очередями/reconnect, [CallProtocol][A-protocol] валидирует envelope/ICE/tracks и сериализует negotiations; [CallAudio][A-audio] управляет Android audio | Протокол MediaEngine + native implementation; одна SDP-транзакция одновременно; lifecycle и серверная moderation имеют приоритет |
| `core:ssh` | [JschSshTransport][A-ssh] фиксирует host key, strict проверка, тайм-аут/отмена; [InstallerProtocol][A-installer] проверяет RSA signature/hashes/release lock; [SshInstallerRepository][A-ssh-repo] реализует plan/apply/status/resume | Отдельный модуль SSH, не HTTP API; секреты в памяти/Keychain; fingerprint trust, проверка bundle и явная привязка операции к host/port |
| `core:model` | Общие типы User/Meeting/Call/Recording/Failure, account scope | Value types с Sendable, корректные UUID/Int64/null/date; DTO отделить от UI |
| `core:designsystem` | Compose tokens/components | Дизайн-параметры сверять с текущим CSS; не объявлять Compose готовым SwiftUI design system |

В `app`/`core:data` присутствуют условные и совместимые со старыми серверами ветки.
Интерфейс с default `throw UNAVAILABLE` сам по себе не доказывает отсутствие функции:
проверены overrides в DefaultFoundationRepository (например pins/message context).
Наличие API-метода тоже не доказывает актуальность сервера (пример F19).

`MessagingApi.preferences` учитывает отсутствие старого `summary`; null-поле
не сериализуется. Для текущего backend iOS должен посылать только
`invitation,reminder,recording,email,push`, иначе строгий binder отвергнет запрос.

## Независимые решения для следующего этапа

Это проектные рекомендации, **не существующие серверные возможности и не готовый код**:

1. `App` / `Features` / `Domain` / `Data` / `Media` / `SSH` / `DesignSystem` с DI.
   Swift Concurrency; actor сериализует смену аккаунта/refresh, MainActor — UI.
2. `AccountScope = normalizedOrigin + userID`, generation для асинхронных ответов;
   отдельные Keychain secrets, caches, WS/SSE и outbox. Logout не восстанавливать
   поздним refresh-ответом; network/5xx не трактовать как отзыв credentials.
3. HTTP DTO и WS envelope тестировать по подтверждённым схемам. Не генерировать
   client из устаревшего Postman без сверки route/handler.
4. Media/notifications/broadcast и SSH скрыть за протоколами, чтобы тестировать
   state machine независимо от Apple entitlements и физических устройств.
5. Не включать отсутствующие capabilities. Для BLOCKED-действий показывать
   честное состояние недоступности после согласования визуала, без успешных заглушек.

## Что не переносится автоматически

- Android MediaProjection/foreground service → ReplayKit/Apple lifecycle.
- Android Keystore/cookie jar → Keychain и явно изолированный URLSession.
- FCM/Android ringtone → APNs/PushKit/CallKit и AVAudioSession.
- JSch → отдельный проверенный Swift-совместимый SSH transport.
- CSS пиксели/Android dp → измеренная SwiftUI-адаптация, safe area, Dynamic Type.

Android тесты в этом окружении не запустились из-за отсутствия Java Runtime;
исторические XML/скриншоты не выдаются за свежий прогон.
Результаты backend unit tests и границы проверки — [AUDIT_REPORT.md](AUDIT_REPORT.md).

<!-- pinned-source-links -->
[A-api]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/MeetSpaceApi.kt
[A-app]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/MeetSpaceApplication.kt
[A-audio]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/media/src/main/kotlin/com/meetspace/core/media/CallAudio.kt
[A-calls]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/DirectCallsApi.kt
[A-cookies]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/SessionCookieJar.kt
[A-engine]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/media/src/main/kotlin/com/meetspace/core/media/CallEngine.kt
[A-events]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ScopedUserEvents.kt
[A-installer]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/InstallerProtocol.kt
[A-meetings]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/MeetingsApi.kt
[A-messaging]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/MessagingApi.kt
[A-modules]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/settings.gradle.kts
[A-origin]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ServerOrigin.kt
[A-preflight]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/DefaultSshPreflightRepository.kt
[A-protocol]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/media/src/main/kotlin/com/meetspace/core/media/CallProtocol.kt
[A-push]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/PushController.kt
[A-record-access]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ScopedRecordingAccess.kt
[A-record-vm]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/RecordingsViewModel.kt
[A-records]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/RecordingsApi.kt
[A-repository]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/DefaultFoundationRepository.kt
[A-screen-share]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/ScreenShareService.kt
[A-signaling]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ScopedCallSignaling.kt
[A-ssh]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/JschSshTransport.kt
[A-ssh-repo]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/SshInstallerRepository.kt
[B-accounts]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/accounts.go
[B-avatar-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/profile_avatar_routes.go
[B-calls]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/call_routes.go
[B-cap-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/platform_status_routes.go
[B-chat]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/chat_routes.go
[B-chat-actions]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/chat_actions_routes.go
[B-folders]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/folder_routes.go
[B-guest]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/conferences/guests.go
[B-integration-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/integration_routes.go
[B-integration-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/integrations/service.go
[B-invitations]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/invitation_routes.go
[B-media]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/media/controller.go
[B-media-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/media/media.go
[B-moderation]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/moderation.go
[B-personal]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_routes.go
[B-personal-assets]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_asset_routes.go
[B-personal-search]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_search_routes.go
[B-platform]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/platform_routes.go
[B-reaction-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/engagement_routes.go
[B-record-library]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/recordings/library.go
[B-records]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/conference_recording_routes.go
[B-search-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/search_routes.go
[B-sessions]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/sessions.go
[B-speech-removal]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/docs/operations/speech-removal-upgrade.md
[B-timeline]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/product.go
[D-settings]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/account-settings.js
