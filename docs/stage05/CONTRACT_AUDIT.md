# Этап 05 — аудит прямых звонков и push

Дата проверки: 2026-11-06. Проверены исходники backend, Android и макетов; backend не изменялся.
Перед выполнением runtime harness проверяет точный HEAD и чистоту tracked-файлов backend.

| Источник | Проверенный commit |
| --- | --- |
| [meet-space](https://github.com/janickiy/meet-space/tree/0bd1248a2411842515af4e02f1e95821616748fb) | `0bd1248a2411842515af4e02f1e95821616748fb` |
| [meet-space-android](https://github.com/janickiy/meet-space-android/tree/b8f289983e60671d415a128734c2e5bb6e93a29d) | `b8f289983e60671d415a128734c2e5bb6e93a29d` |
| [mobile_maket](https://github.com/janickiy/mobile_maket/tree/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3) | `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3` |

## REST звонков

Все маршруты ниже относятся к `/api/v1`, требуют Bearer обычного аккаунта; guest не допускается.
UUID запроса должен быть ненулевым и записан строчными буквами в канонической форме.
`clientId` — UUID, а не произвольная строка устройства.

| Метод и путь | Запрос / ответ |
| --- | --- |
| `POST /calls` | `{targetUserId, clientRequestId, clientId}`; `201` при создании, `200` при повторе; `{status:"success", item:Call}` |
| `GET /calls/active` | `{status:"success", item:Call|null}` |
| `GET /calls/{id}` | `{status:"success", item:Call}` только для caller/callee |
| `POST /calls/{id}/accept` | `{clientId}` |
| `POST /calls/{id}/decline` | `{}` разрешено; отдельное устройство не требуется |
| `POST /calls/{id}/cancel` | `{clientId}`; владелец исходящего звонка |
| `POST /calls/{id}/end` | `{clientId}`; один из двух владельцев media |
| `POST /calls/{id}/heartbeat` | `{clientId}`; продлевает lease только своей стороны |

Действия возвращают `{status:"success", item:Call}`. Если звонок истёк до применения действия,
сервер может вернуть `200` с терминальным состоянием вместо запрошенного перехода.
Лимиты: создание 15/мин, чтение 90/мин, каждое действие 60/мин на аккаунт.

Источники: [HTTP routes:28–47](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/transport/http/call_routes.go#L28),
[валидация и envelopes:30–125](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/app/calls/handler.go#L30).

`Call` содержит `id`, `conversationId`, nullable `conferenceId`, `callerUserId`, `calleeUserId`,
`callerClientId`, nullable `acceptedByClientId`, `status`, `version:Int64`, `createdAt`, `expiresAt`,
nullable `acceptedAt`/`endedAt`, `caller`/`callee` (`id`, `displayName`) и `durationSec:Int64`.
Допустимые состояния: `ringing`, `accepted`, `declined`, `cancelled`, `missed`, `ended`.
`clientRequestId` и lease deadlines не выдаются клиенту.
[DTO и таймауты:13–40](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/calls/call.go#L13).

## Гонки устройств, WS и media

- Один активный звонок на аккаунт. Создание блокирует обе строки пользователей в устойчивом порядке;
  повтор `(caller, clientRequestId)` возвращает тот же звонок только при совпадении target/client.
  Занятый участник и повтор ключа с другими параметрами дают `409`.
- Принятие блокирует строку звонка. Первое устройство callee становится `acceptedByClientId`;
  повтор на нём идемпотентен, конкурентное другое устройство получает `409`.
  Пока звонок ещё `ringing`, отклонить может любое устройство callee.
- Ring timeout — 45 секунд. После принятия **обе** стороны должны обновлять свои 45-секундные leases.
  Heartbeat не увеличивает `version` и не публикует WS событие. Sweeper работает каждые 5 секунд;
  GET/action также выполняют проверку истечения. Старый `expiresAt` относится к ringing,
  он не означает окончание принятого звонка.
- User WS публикует `call.updated` с `data:{call:Call}` и пустым `conferenceId`, а также
  `conversation.updated` с `{conversationId,type:"direct"}`. События направляются обоим аккаунтам,
  включая дополнительные устройства. Нужны REST resync при reconnect и периодическое чтение:
  pubsub не является гарантированным журналом доставки.
- Accept создаёт скрытую conference `kind=direct_call`, две joined/admitted membership.
  SFU ticket/connection требует `accepted`, живые leases обеих сторон и точный client UUID владельца.
  `GET /conferences/{id}/participants/me` доступен через прямое чтение membership.
  Обычные meeting GET/list/join/leave не дают открыть эту скрытую комнату.
- End завершает комнату, переводит участников в left, сбрасывает media flags, повышает policy version,
  освобождает slots и обновляет call-history сообщение в direct conversation.

Источники: [транзакции и переходы:130–386](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/postgres/call_repository.go#L130),
[WS/resync:135–148](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/calls/service.go#L135),
[expiry worker:245](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/calls/service.go#L245),
[media authorization:68–105](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/postgres/session_repository.go#L68),
[self membership:98](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/conferences/product.go#L98),
[meeting filter:362](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/postgres/conference_repository.go#L362).

## Существующий push API и ограничения

| Маршрут | Фактический контракт |
| --- | --- |
| `GET /integrations/capabilities` | Bare JSON: `email`, `push`, `calendar`, `calendarOAuthConfigured`, `mockConnectAllowed` |
| `GET /notifications/devices` | `{items:[Device]}`; включает revoked/disabled, максимум 100 строк по `created_at,id` |
| `POST /notifications/devices` | Только `{platform:"ios",token}`; `201 {item:Device}` |
| `DELETE /notifications/devices/{deviceId}` | `204`; только устройство текущего аккаунта |
| `GET/PUT /notifications/preferences` | Bare JSON из пяти Bool: `invitation`, `reminder`, `recording`, `email`, `push` |

Backend принимает платформы `ios`, `android`, `web`; длина token 8…8192 байт.
Device возвращает `id`, `platform`, `provider`, `createdAt`, `updatedAt` и необязательные
`revokedAt`/`disabledAt`; token, его fingerprint и userID в ответе отсутствуют.
При регистрации Go value может возвращать нулевые timestamps, поэтому они не служат доказательством свежести.
Push preference по умолчанию выключена. Режим `noop` не разрешает регистрацию; `mock` и `http`
обозначают режим generic gateway, а не проверенную доставку на платформу.

**У одного token могут одновременно существовать привязки разных аккаунтов.** ID вычисляется
из `userID + providerMode + SHA256(token)`, а лимит/блокировка записи действуют лишь внутри аккаунта.
Ротация token создаёт другой ID и автоматически не отзывает старый.
Лимит — 100 активных устройств аккаунта. GET возвращает первые 100 всех записей, поэтому накопившиеся
revoked-записи могут скрыть активные из выдачи. iOS cleanup не полагается на этот список.

iOS хранит глобальный журнал этой установки отдельно от AccountIndex: origin/userID, собственные device IDs,
локальное согласие и SHA256 от отправляемой hex-строки APNs token. Сам token остаётся в RAM.
Перед POST сохраняется pending intent, затем полученный ID; logout/switch сначала отключает OS registration,
дожидается текущего POST и отзывает только собственные ID. Неподтверждённый POST/revoke сохраняет журнал
и блокирует любые новые регистрации, в том числе другого origin/account. После удаления аккаунта нужен
повторный вход в прежнюю область для cleanup. Неизвестный ID восстанавливается только тем же свежим
OS token и при неизменном `http` provider mode; с другим token безопасного автоматического восстановления
нет. Удаление всех устройств аккаунта не применяется.

Источники: [routes:59–66](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/transport/http/integration_routes.go#L59),
[device registration:510–527](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/integrations/service.go#L510),
[list/limit/revoke:89–144](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/postgres/integration_repository.go#L89),
[DTO:71–96](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/integrations/integration.go#L71).

## Что отсутствует на сервере

В проверенном backend нет native APNs/FCM отправителя, VoIP token kind, APNs topic/environment,
CallKit UUID payload или push job на изменение direct call. Calls service публикует только user WS.
Generic gateway получает `{idempotencyKey,token,title,body,url}` на `/push/send`; существующая доставка
обслуживает conference notifications. `push == "http"` не подтверждает APNs, тем более PushKit.

Существующая конфигурация: `PUSH_PROVIDER_MODE`, `PUSH_PROVIDER_ENDPOINT`, `PUSH_PROVIDER_TOKEN`,
`PROVIDER_TOKEN_ENCRYPTION_KEY`. Это серверные значения, они не входят в приложение или evidence.
Новые контракты для APNs/VoIP требуют отдельного согласованного изменения backend.
Входящий CallKit из foreground/user WS можно реализовать сейчас; пробуждение terminated приложения
реальным VoIP push остаётся **BLOCKED** до серверной реализации, подписания и проверки на физическом устройстве.

Источники: [gateway modes:111–135](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/providers/integrations.go#L111),
[PushMessage:172–178](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/integrations/integration.go#L172),
[delivery:875–924](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/integrations/service.go#L875),
[configuration:63–110](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/config/product.go#L63).

## Android и макеты

Android подтверждает те же REST/DTO, пустое тело decline, account-scoped repository,
версии, heartbeat и отдельный client UUID. `DirectCallViewModel` прямо указывает, что transient
client IDs не восстанавливаются после смерти процесса. Android `PushController` использует FCM
только при наличии конфигурации, явного согласия и server `push == "http"`; это не добавляет APNs к backend.

Источники Android: [DirectCallsApi.kt:19–74](https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/DirectCallsApi.kt#L19),
[DirectCallViewModel.kt:19](https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/DirectCallViewModel.kt#L19),
[PushController.kt:24–73](https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/app/src/main/java/com/meetspace/app/PushController.kt#L24).

`mobile_maket` существует и содержит `meetspace-refresh-20261016/personal-call.js`, `personal-call.css`,
`notifications.js/css`, assets Inter и previews. Personal call prototype реализует состояния
`calling`/`connected`, баннер возврата в звонок, таймер, mic/camera/end; UI и сеть имитируются.
Это источник оформления in-app экрана, а системный CallKit интерфейс управляется iOS.
Аудит наличия макетов не означает полного pixel parity, проверки всех размеров или VoiceOver.

Источники макетов: [personal-call.js](https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/personal-call.js),
[personal-call.css](https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/personal-call.css),
[README:33–35](https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/README.md#L33).

## Граница runtime доказательства

`scripts/run_calls_contract.py` поднимает disposable pinned API/SFU, PostgreSQL, Redis, RabbitMQ,
MinIO и синтетический HTTP push gateway. `actualBackendDirectCallsDevicesAndPrivateSFU` проверяет
реальные REST, user WS, конкурирующий accept, owner ticket, `media.join`, скрытую direct room,
terminal/history, таймауты и account-scoped device API. Все credentials остаются внутри fixture;
production HTTPS/WSS transport не ослабляется. Stage 04 RTP доказательство остаётся отдельным.

Синтетический gateway не связывается с Apple/Google. Успех runtime не подтверждает APNs delivery,
PushKit wakeup, CallKit lock-screen UI, native camera/audio, Bluetooth, background/terminated поведение
или доставку на физическом iPhone/iPad. Результаты конкретного запуска фиксируются в отчёте этапа.
