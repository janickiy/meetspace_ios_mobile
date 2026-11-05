# Реестр рисков и блокировок

Дата: 2026-11-05. Регистр относится к началу нативной реализации, а не к заключению
о безопасности всей платформы. P1 — может нарушить основной сценарий/изоляцию,
P2 — ограничение функции или полноты проверки. Статус относится к конкретному
объёму: PASS статического аудита не равен готовности к выпуску.

| ID | Приоритет / статус | Подтверждённый риск | Действие и критерий закрытия |
| --- | --- | --- | --- |
| R01 | P1 / BLOCKED для AI | Дизайн и Android содержат старые transcript/AI операции; сервер удалил их [removal][B-speech-removal] | Исключить из текущей iOS parity либо отдельно согласовать backend-предложение; не отправлять отсутствующие routes |
| R02 | P1 / BLOCKED для push | `platform=ios` разрешён, generic gateway `push/send` не доказывает APNs [service][B-integration-service], [provider][B-providers] | Получить/проверить контракт шлюза, topic/environment/token handling и доставку на реальный iPhone/iPad |
| R03 | P1 / BLOCKED для фонового звонка | `call.updated` доставляется в подключённый WS; подтверждённого VoIP payload/token lifecycle нет [calls][B-calls-service] | Согласовать PushKit/APNs flow и CallKit, проверить locked/background/terminated, revoke и accept на двух устройствах |
| R04 | P1 / BLOCKED для broadcast | SFU поддерживает screen sources, нативного ReplayKit proof нет [media DTO][B-media-model] | Broadcast Upload Extension + прототип CMSampleBuffer→WebRTC, stop/revoke/moderation, real-device test; новый endpoint заранее не требуется |
| R05 | P1 / OPEN до реализации | Ошибочное хранение refreshToken вместо cookie, утечка между origin/account [sessions][B-sessions], [Android jar][A-cookies] | Keychain, отдельные cookie contexts, single-flight refresh, generation checks; тесты смены аккаунта/late reply/redirect/logout |
| R06 | P1 / OPEN до реализации | UI может дать owner/co_host/admin неверные права; старт записи разрешён обычному admitted account [policy][B-moderation], [record policy][B-record-policy] | Матрица ролей + negative API tests; co_host не получает stop/delete по названию роли, guest не получает запись |
| R07 | P1 / OPEN до реализации | Reconnect не имеет replay; потерянные события и устаревшая media session [hub][B-hub], [user WS][B-user-ws] | REST resync, ID/version merge, новый ticket/peer, запрет replay старого origin/account; тесты разрывов |
| R08 | P1 / OPEN до реализации | `media.joined` не включает relay/expiry, хотя internal DTO их имеет [controller][B-media] | Обязательно GET webrtc/config, сохранить relay policy и TTL; TURN-only испытание без прямой связи |
| R09 | P1 / BLOCKED для полной проверки | Нет выделенного test server с аккаунтами/ролями и Apple device/test configuration | На тестовой установке зафиксировать version, миграции, TLS/WSS/TURN/SFU/S3 и выполнить device matrix без production-мутирования |
| R10 | P2 / BLOCKED частично | Макет библиотеки обещает фильтры/поиск; API подтверждает только cursor/limit [library][B-record-library] | Либо честно ограничить поиск загруженным набором, либо отдельно согласовать серверное расширение; не заявлять полный поиск |
| R11 | P2 / BLOCKED для message reactions | Есть reaction во встрече, нет message reaction route [routes][B-reaction-route] | Убрать/пометить действие недоступным после согласования визуала; отдельное предложение API при необходимости |
| R12 | P2 / BLOCKED частично по дизайну | Есть 21 HTML-экран, но нет полного iOS permission/error/CallKit/Split View/Dynamic Type набора [gallery][D-gallery] | Дополнить конкретные состояния SCREEN_MATRIX; не заявлять pixel parity до визуальных тестов |
| R13 | P2 / BLOCKED для поставки шрифта | Только WOFF2 Inter; native font + license в инвентаре не найдены [CSS][D-base-css] | Получить/проверить TTF/OTF и лицензию; не подменять шрифт без решения |
| R14 | P2 / OPEN | Старый handoff даёт синий accent, актуальный каскад — другой [tokens][D-tokens] | Брать текущий preview cascade, фиксировать компонентные размеры/цвета в snapshot baseline |
| R15 | P2 / BLOCKED для внешнего календаря | Есть серверный OAuth, iOS return URI и EventKit-сценарий не подтверждены [handler][B-integration-handler] | Определить native callback/ASWebAuthenticationSession и allowed redirect; проверить end-to-end без нового вымышленного API |
| R16 | P1 / BLOCKED для SSH delivery | Android JSch/installer проверяет host key/release signature; iOS аналога нет [SSH][A-ssh], [bundle][A-installer] | Выбрать транспорт, сохранить strict pinning и signature/hash checks, испытать plan/status/resume на тестовом хосте |
| R17 | P2 / BLOCKED для Android test run | `./gradlew` завершился до сборки: Java Runtime отсутствует | Настроить JDK/SDK и повторить указанные unit tests; это среда, не доказанный дефект Android |
| R18 | P2 / BLOCKED для iOS build | Активен CommandLineTools, xcodebuild требует Xcode; iOS проекта на этапе 01 нет | Полный Xcode + iOS SDK/signing/device до сборки приложения; Swift CLI не подтверждает iOS readiness |
| R19 | P1 / OPEN до реализации | Signed URL временный/внешний; Bearer нельзя пересылать в storage host [cards][B-record-card], [Android access][A-record-access] | Разделить authenticated API и credential-free download, проверить URL/redirect/expiry и отзыв доступа |
| R20 | P2 / OPEN | README/backend docs устаревают: guest TTL в коде 3 часа, в persistent auth doc час [users][B-users], [doc][B-persistent-doc] | Использовать expiresIn и pinned source, сравнивать контракт при обновлении commit |
| R21 | P2 / BLOCKED для auth extensions | Нет reset password, смены email/password [routes][B-platform] | Не обещать эти действия; расширение только отдельным согласованным предложением |
| R22 | P2 / OPEN | Старые QA JSON и verify.mjs не покрывают весь текущий макет [verify][D-verify] | Создать полноценную актуальную матрицу в этапе UI; не принимать исторический отчёт за текущий PASS |

## APNs / VoIP: что является серверной зависимостью

Подтверждено: регистрация/отзыв устройств, preferences, inbox, generic push adapter.
Не подтверждено: договорённость о normal/VoIP tokens, APNs topic/push-type/environment,
состав payload звонка, срок актуальности вызова, дедупликация, отзыв и обработка ошибок APNs.
В generic PushMessage есть `idempotencyKey,token,title,body,url`; это ещё не VoIP call schema.
[DTO][B-integration-model]

Нужно проверить существующий внешний шлюз; при его отсутствии изменение backend/gateway
оформляется отдельным предложением. В данном этапе сервер не менялся и gateway не создавался.
Ключи APNs остаются на provider server. На устройстве нужны соответствующие entitlements.
[Apple: APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns),
[Apple: notification provider](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server).

PushKit предназначен для входящих VoIP-звонков; для выбранной CallKit-интеграции нужно
своевременно сообщать входящий вызов системе. Обычный inbox push не считать заменой
этого сценария. [Apple: VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

## ReplayKit: граница зависимости

ReplayKit предоставляет screen/audio sample buffers через broadcast extension.
SFU уже принимает `video/screen` и `audio/screen`, но соответствие форматов, кодека,
тайминга, audio routing и ограничений жизненного цикла ещё не проверено.
На текущих данных это прежде всего клиентский прототип и инфраструктурная проверка,
а не основание автоматически вводить новый backend endpoint.
[Apple: RPBroadcastSampleHandler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler),
[SFU sources][B-media-model].

## PASS / FAIL / BLOCKED и переход между этапами

- **PASS аудита:** пять обязательных документов созданы; источники pinned;
  макеты инвентаризированы; функции связаны с кодом или явно BLOCKED;
  backend не изменялся; секреты отсутствуют в файлах результата.
- **FAIL:** вымышленный endpoint/event/право, ложное утверждение об успешном тесте,
  ссылка на неверный исходник, секрет в diff или скрытая backend-правка.
  При таком результате исправить этап 01 до перехода дальше.
- **BLOCKED:** отсутствующие контракты/дизайн/окружение/device evidence.
  Это не успешный тест и не подтверждённый баг; область блокировки указана по строкам.

Завершение документального аудита не снимает R01–R22 автоматически.
Независимая архитектура имеет подтверждённую основу; полный parity и выпуск приложения
пока не имеют PASS. Следующий этап в этой работе не начинался.

<!-- pinned-source-links -->
[A-cookies]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/SessionCookieJar.kt
[A-installer]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/InstallerProtocol.kt
[A-record-access]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ScopedRecordingAccess.kt
[A-ssh]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/ssh/src/main/kotlin/com/meetspace/core/ssh/JschSshTransport.kt
[B-calls-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/calls/service.go
[B-hub]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/realtime/hub.go
[B-integration-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/integrations/handler.go
[B-integration-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/integrations/integration.go
[B-integration-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/integrations/service.go
[B-media]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/media/controller.go
[B-media-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/media/media.go
[B-moderation]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/moderation.go
[B-persistent-doc]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/docs/PERSISTENT_AUTH.md
[B-platform]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/platform_routes.go
[B-providers]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/providers/integrations.go
[B-reaction-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/engagement_routes.go
[B-record-card]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/records/dto.go
[B-record-library]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/recordings/library.go
[B-record-policy]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/postgres/conference_recording_repository.go
[B-sessions]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/sessions.go
[B-speech-removal]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/docs/operations/speech-removal-upgrade.md
[B-user-ws]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/websocket/user_handler.go
[B-users]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/users/user.go
[D-base-css]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/app.css
[D-gallery]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/gallery.js
[D-tokens]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/workspace-refresh.css
[D-verify]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/verify.mjs
