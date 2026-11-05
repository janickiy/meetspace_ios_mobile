# Подтверждённые контракты HTTP API

Дата: 2026-11-05, Europe/Moscow. Backend: `56a0b0721806f7db5ad4e658c856ddfe8ebd6acd`.
Android: `b8f289983e60671d415a128734c2e5bb6e93a29d`.
Все ссылки ниже закреплены за этими коммитами. Проверка статическая и модульная;
доступность конкретного развёрнутого сервера не проверялась.

## Правила чтения

Все относительные пути таблиц имеют префикс `/api/v1`. `:id` — параметр маршрута,
а не буквальная часть URL. Перечисления в фигурных скобках обозначают несколько
**проверенных** маршрутов; клиент должен подставлять только перечисленные значения.
`CONFIRMED` означает наличие кода контракта; это не результат сквозного теста iOS.

Основной источник — регистрация маршрутов, DTO, обработчики, проверки доступа и
[подключение зависимостей API][B-api-wiring], [product wiring][B-product-wiring].
README и старые API-документы вторичны. Дизайн не является контрактом API.

## Транспорт, ошибки, совместимость

- Выбранный пользователем адрес — HTTPS origin. Сохранять порт и границу origin;
  отклонять userinfo, query, fragment и произвольный path. Это клиентская политика,
  подтверждённая [Android ServerOrigin][A-origin], а не новая функция backend.
- Для приватных REST-запросов нужен `Authorization: Bearer <accessToken>`.
  Cookies нужны для auth-сессии; они не заменяют Bearer на остальных маршрутах.
- В запросах JSON использовать `Content-Type: application/json`. Общий binder
  ограничивает тело 32 KiB, отвергает неизвестные поля и второе JSON-значение.
  Бинарные upload-обработчики имеют отдельные ограничения. [Обработка HTTP][B-errors]
- Ошибка обычно `{status:"failed",message:...}`. Неверный JSON — 400;
  неверные значения — 422; неавторизован — 401; запрещено — 403;
  отсутствует — 404; конфликт — 409; лимит — 429; недоступность — 503;
  тайм-аут — 504. В отдельных транспортных отказах возможны другое тело или
  пустой ответ; нельзя требовать один JSON-конверт для всех HTTP-ошибок.
- Успешные ответы неоднородны: `user`, `item`, `items`, голый объект, 204.
  Не создавать универсальный decoder, требующий `status` у каждого ответа.
- UUID кодировать как отдельные path segments. `sequence` сообщений приходит
  **JSON-строкой**, `version` — числом; курсоры считать непрозрачными.
  Даты — RFC3339 с часовым поясом; nullable и отсутствующее поле различаются.
- Новые неизвестные поля ответа можно игнорировать; неизвестное состояние не
  должно включать действия с правами. Отсутствующий capability не считать `true`.
- Повторы мутаций допустимы только по подтверждённому контракту идемпотентности.
  Refresh объединять в одну операцию, после 401 повторять запрос не более одного раза.
  Для Swift это проектное требование, проверенное поведение Android — [repository][A-repository].
- TLS — системная проверка. Секреты сессии для iOS хранить в Keychain, разделяя
  origin/account; не пересылать их при redirect на другой origin. Подписанные S3 URL
  могут вести на другой HTTPS-хост: запрос к ним выполняется без Bearer и auth-cookie.

## Сервер и возможности

| Метод и путь | Доступ / ответ | Вывод |
| --- | --- | --- |
| `GET /version` (без `/api/v1`) | Публично; `version,commit,buildTime` | Подтверждён в [operations][B-operations]; не проверка всех функций |
| `GET /health`, `/health/live`, `/health/ready` (без `/api/v1`) | Служебные health-маршруты | Не заменяют login и capability check |
| `GET /capabilities` | Bearer; `status,capabilities,buildVersion` | Текущий `capabilities` содержит `recordingModes`, без AI-флагов [DTO][B-capabilities] |
| `GET /admin/summary` | Bearer + глобальный `isAdmin` | Read-only сводка; не право администрировать чужую встречу [маршруты][B-cap-routes] |
| `GET /integrations/capabilities` | Bearer; голый объект `email,push,calendar,calendarOAuthConfigured,mockConnectAllowed` | Проверять фактические `noop/mock/http` и настройки [handler][B-integration-handler] |
| `POST /client-errors` | Телеметрия, зависит от серверной конфигурации | Служебный, не пользовательская функция [маршрут][B-telemetry] |

`/metrics`, `/operations/drain` — операционные маршруты [источник][B-operations];
мобильному клиенту не нужны. `/internal/media/*` — закрытый межсерверный протокол,
его ключи и адреса в приложение не передаются.

## Auth и профиль

Все маршруты ниже CONFIRMED: [регистрация маршрутов][B-platform],
[handler][B-auth], [DTO и валидация][B-users], [cookies][B-sessions], [accounts][B-accounts].

| Метод и путь | Запрос / ответ | Условия |
| --- | --- | --- |
| `POST /auth/register` | `{email,password,displayName?}` → 201 `{status,user}` | Регистрация **не выдаёт сессию**, после неё нужен login |
| `POST /auth/login` | `{email,password}` → 200 `{status,accessToken,tokenType,expiresIn,user}` + Set-Cookie | `tokenType=Bearer`; в постоянной сессии `expiresIn=3600` |
| `POST /auth/refresh` | Cookie; пустое тело, `{}` либо `{userId}` → LoginResponse | **Нет JSON refreshToken** |
| `POST /auth/session` | Bearer старого действующего JWT → LoginResponse + cookies | Миграция в persistent session; не для гостя |
| `POST /auth/accounts/list` | Cookies → `{status,items}` | Только подтверждённые cookie-аккаунты; не поиск пользователей |
| `POST /auth/accounts/switch` | Cookies + `{userId}` → LoginResponse | Проверяет принадлежность cookie выбранному аккаунту |
| `POST /auth/logout` | В persistent-режиме cookie, необязательный Bearer и `{userId?}` → `{status}` | Идемпотентный отзыв выбранной сессии; legacy-режим требует Bearer |
| `GET /auth/me` | Bearer → `{status,user}` | `id,email,displayName,isAdmin,createdAt,updatedAt,avatarVersion?`, возможен guest scope |
| `PATCH /auth/me` | `{displayName}` → `{status,user}` | Не API смены email/пароля |
| `DELETE /auth/me` | `{password}` → `{status}` | Удаление своего аккаунта; общая история имеет отдельную серверную политику |
| `PUT /auth/me/avatar` | JPEG/PNG binary → профиль | Отдельная валидация размера и содержимого |
| `DELETE /auth/me/avatar` | Удаление своего аватара | Account-only |
| `GET /users/:id/avatar/content` | Авторизованный JPEG | `avatarVersion` помогает инвалидировать кэш [avatar routes][B-avatar-routes] |

Пароль регистрации: 8–128 символов; `displayName` нормализуется, 1–100 Unicode-символов,
без управляющих символов. Не переносить более широкие пределы Android DTO в серверную валидацию.

Секрет сессии передаётся как `meetrix_session` и `meetrix_account_<UUID>`:
host-only, HttpOnly, Path `/api/v1/auth`, SameSite=Lax, Secure вне local/dev/debug.
Срок cookie — 400 дней, серверная сессия не истекает по простому тайм-ауту простоя.
Logout отзывает JWT с `sid`. Cookie-операции проверяют Origin и Fetch Metadata;
нативный запрос без этих браузерных заголовков допустим. [Реализация][B-sessions]

В Android cookie jar изолирован по origin и сохраняет `meetrix_session` отдельно для
аккаунта; переключение может выполняться локально с восстановлением нужной cookie,
а не через browser account API. iOS следует сохранить эту изоляцию и отмену старых
операций при смене аккаунта. [Cookie jar][A-cookies], [repository][A-repository]

## Встречи, участники, приглашения

Маршруты [platform][B-platform], [guest][B-guest-route], [invitations][B-invitations];
модели [conference][B-conference], [timeline][B-timeline].

| Метод и путь | Основной контракт |
| --- | --- |
| `POST /conferences` | `title,waitingRoomEnabled?,scheduledAt?,plannedDurationMin?`; ответ `item` |
| `GET /conferences` | `limit,offset`; список доступных конференций |
| `GET /conferences/:id` | `item` конференции с серверным состоянием |
| `POST /conferences/:id/{start,finish,cancel}` | Переход жизненного цикла; сервер проверяет полномочия |
| `POST /conferences/:id/join` | Опциональный `inviteCode`; `item` участника; может попасть в ожидание |
| `POST /conferences/:id/leave` | `item` участника после выхода; это не завершение встречи |
| `GET /conferences/:id/participants` | `limit,offset`; видимость списка зависит от допуска/роли |
| `GET /conferences/:id/participants/me` | Свое членство, в том числе waiting/rejected |
| `POST /conferences/:id/participants/:participantId/admission` | `{decision:"admit"\|"reject"}` |
| `PUT /conferences/:id/schedule` | `{scheduledAt,plannedDurationMin?}` |
| `GET /conferences/:id/history` | Конференция, owner, длительность, участники, summary записей, `chatAvailable,chatReadOnly` |
| `GET /me/conferences` | `view=upcoming\|active\|past`, `scope=all\|owned\|participating`, `sort=newest\|oldest`, `status,from,to,cursor,limit`; `items,nextCursor` |
| `GET /conference-invites/:code` | Публичное ограниченное представление; не полная конференция |
| `POST /conference-invites/:code/join` | Bearer зарегистрированного пользователя |
| `POST /conference-invites/:code/guest` | `{displayName}` → гостевой LoginResponse + участник |
| `GET /conferences/:id/invitation-users` | Поиск доступных адресатов приглашения |
| `POST /conferences/:id/invitations` | `{userIds?,emails?}`; серверная обработка приглашений [DTO][B-invitation-model] |
| `PUT /conferences/:id/participants/me/media` | `{connectionId,sequence,microphoneEnabled,cameraEnabled,screenSharing}` |
| `POST /conferences/:id/participants/:participantId/moderation` | `{action,blocked?,role?}`; правила ниже |
| `POST /conferences/:id/reactions` | Реакция **во встрече**, не на сообщение [маршрут][B-reaction-route] |

`scheduledAt` должен быть будущим RFC3339 instant с timezone, длительность 1–1440 минут.
Состояния конференции: `created,scheduled,active,finished,cancelled`.
Гостевой срок в текущем коде — **3 часа**, `expiresIn=10800`;
упоминание часа в [PERSISTENT_AUTH.md][B-persistent-doc] устарело.
Использовать ответ сервера, а не зашитый срок. [Guest TTL][B-users], [выдача][B-guest]

## Права: роли не взаимозаменяемы

| Действие | Подтверждённая политика |
| --- | --- |
| Участие в медиа | `joined` и admitted; waiting/rejected/kicked не дают доступ |
| История | admitted + joined/left; исключённый участник не сохраняет это право |
| Допуск из ожидания | участвующий `owner` или `co_host` |
| Модерация | Owner: mute/camera/screen/kick/role; co_host: mute/screen/kick только обычного participant |
| Изменение роли | Только `co_host` или `participant`; нельзя назначить owner через moderation |
| Защита owner | Нельзя модерировать владельца или самого себя этой командой |
| Начать запись | **Любой допущенный joined зарегистрированный участник** активной обычной встречи; не только owner |
| Остановить запись | Инициатор записи либо owner встречи, с доступом к истории; co_host сам по себе этого права не даёт |
| Удалить запись | Инициатор либо owner, зарегистрированный аккаунт с доступом к истории; запись terminal и без активной recorder lease |
| Глобальный администратор | `/admin/summary`; не автоматически owner всех конференций |
| Личные/групповые чаты, папки, звонки | Зарегистрированные аккаунты; дополнительные проверки членства/владения |

Источники: [admission/history][B-timeline], [moderation][B-moderation],
[проверки записи в транзакции][B-record-policy], [отдельная политика удаления][B-record-delete].
Активную/обрабатываемую запись нельзя удалить по одному лишь праву start/stop.
Гостевые ограничения дополнительно обеспечиваются auth middleware.

## Чаты и файлы

Общий набор регистрируется для `/conferences/:id` и `/conversations/:id`:
[маршруты][B-chat], [подключение personal namespace][B-personal], [DTO][B-chat-model], [handler][B-chat-handler].

| Метод и суффикс к выбранному namespace | Запрос / ответ |
| --- | --- |
| `GET /messages` | `before,limit` → `status,items,nextCursor,unreadCount,lastReadMessageId` |
| `POST /messages` | `{clientRequestId,text,replyTo?,attachmentIds?}` → 201 при создании / 200 при повторе, `item` |
| `PATCH /messages/:messageId` | `{text}` → `item` |
| `DELETE /messages/:messageId` | `item` с состоянием удаления; не физическое исчезновение ID |
| `GET /chat/read` | `item` состояния чтения |
| `PUT /chat/read` | `{messageId}` → `item` |
| `POST /attachments/init` | `{clientRequestId,filename,mimeType,size}` → `item,uploadUrl` |
| `PUT /attachments/:attachmentId/content` | Бинарное тело, не multipart; авторизация сохраняется |
| `POST /attachments/:attachmentId/finalize` | `{}` → `item`; проверка реально загруженных байтов |
| `GET /attachments/:attachmentId/download` | `{status,url,expiresAt}`, затем отдельный HTTPS GET URL |

Текст: максимум 4000 Unicode-символов; до 5 вложений по 10 MiB.
Срок незавершённого вложения — 30 минут; download URL — 5 минут.
`clientRequestId` стабилен при повторе одного сообщения; другой payload с тем же ID
не считать новой отправкой. Системные сообщения звонка не редактируются как обычный текст.

Дополнительные подтверждённые операции:

| Область | Методы и пути | Источник / замечание |
| --- | --- | --- |
| Каталог | `GET /users`, `GET /conversations`, `GET /conversations/:id` | [personal][B-personal] |
| Создание чата | `POST /conversations/direct`, `POST /conversations/group` | Разные DTO; не конференция |
| Присутствие peer | `GET /conversations/:id/peer-presence` | Не гарантирует фоновую доступность телефона |
| Личные действия | `PATCH /conversations/:id/preferences`, `POST .../clear-history`, `POST .../hide`, `POST .../read` | Персональное скрытие/очистка не удаляет историю у собеседника |
| Group lifecycle | `PATCH /conversations/:id`, `DELETE /conversations/:id`, `POST .../leave`, `POST .../ownership` | Сервер проверяет group type, членство, роль; передача владения отдельная |
| Group members | `GET/POST /conversations/:id/members`, `DELETE/PATCH .../members/:userId` | Участники и смена ролей |
| Group avatar | `PUT/DELETE /conversations/:id/avatar`, `GET .../avatar/content` | [assets][B-personal-assets] |
| Файл в conversation | `GET /conversations/:id/attachments/:attachmentId/content` | Авторизованное содержимое; отдельный путь от signed download |
| Поиск personal | `GET /conversations/:id/messages/search`, `GET .../messages/:messageId/context` | [search][B-personal-search] |
| Personal pins | `GET /conversations/:id/pins`, `PUT/DELETE .../pins/:messageId` | Не придумывать общий API реакций |
| Conference chat metadata | `GET/PATCH /conferences/:id/chat/info`, `GET .../chat/members` | [actions][B-chat-actions] |
| Conference chat preferences | `GET/PUT /conferences/:id/chat/preferences`, `DELETE .../chat/membership` | Выход из истории чата отличается от leave медиа |
| Conference chat search | `GET /conferences/:id/chat/messages/search`, `GET .../chat/messages/:messageId/context`, `GET .../chat/materials` | Отдельный `/chat` в пути |
| Conference chat pins | `GET /conferences/:id/chat/pins`, `PUT/DELETE .../chat/pins/:messageId` | Не путать с conversation pins |
| Общий поиск | `GET /search` | [маршрут][B-search-route]; текстовый поиск, не подтверждение semantic search |

Реакции на конкретные сообщения в макете — **BLOCKED**: зарегистрирован только
conference reaction endpoint. Локальные черновики не требуют нового backend API.

Ключевые DTO conversations: direct create — `{userId}`; group create —
`{clientRequestId,name,description,memberIds}`; group update — `{name?,description?}`;
add members — `{userIds}`; change member role — `{role}`; transfer ownership — `{userId}`.
Group roles — **owner/admin/member**, в отличие от conference owner/co_host/participant.
Максимум 100 участников. Owner/admin меняют метаданные и добавляют участников;
admin удаляет только member, owner — admin/member. Только owner меняет роли,
передаёт владение и удаляет группу. Owner не может выйти, оставив других участников
без владельца; сначала transfer. [DTO][B-group], [handlers][B-group-handler],
[транзакционные проверки][B-group-policy], [direct create][B-personal-handler]

## Папки

[Все маршруты][B-folders]: `GET/POST /folders`, `PUT /folders/order`,
`GET/PATCH/DELETE /folders/:id`, `GET /folders/:id/items`, `GET /folder-items`,
`PUT/DELETE /folders/:id/items/:kind/:itemId`.
Папки принадлежат аккаунту; доступ к вложенной встрече или чату проверяется отдельно.
Порядок и удаление папки не дают права удалять сам чат/встречу. Direct-call комнаты
не представляются обычными папочными встречами.
Create/rename используют `{name}`, order — `{ids}`. [Folder handler][B-folder-handler]

## Записи

[Маршруты][B-records], [request][B-record-request], [модель][B-record-model],
[карточка файлов][B-record-card], [библиотека][B-record-library].

| Метод и путь | Контракт |
| --- | --- |
| `GET /recordings` | `cursor,limit` (по умолчанию 30, максимум 100); `{status,items:[{conference,recording}],nextCursor}` |
| `POST /conferences/:id/recordings` | `{mode?,segmentDurationSec?}` → 202 `{status,item}` |
| `GET /conferences/:id/recordings` | `limit,offset` → `{status,items}` |
| `GET /conferences/:id/recordings/:recordingId` | `{status,item}` с `files[],segments[]` и доступными URL |
| `DELETE /conferences/:id/recordings/:recordingId` | Отдельная авторизованная операция → `{status}` |
| `POST /conferences/:id/recordings/:recordingId/stop` | `{}` → 202 `{status,item}` |

В path используется UUID записи (`uuid`), а числовой `id` и `files[].recordId` —
другие поля. Режимы: `composite,audio_only,individual_tracks,screen_focus`;
показывать пересечение с `recordingModes` сервера. `finalizing/uploading`
публично отображаются как `processing`; учитывать `starting,recording,stopping,
ready,partial_ready,failed,cancelled,degraded`. [Status mapping][B-record-request]

Типы артефактов в Android: `final_mp4`, `final_audio`, `preview_jpg`, `tracks_archive`.
Ссылки временные; перечитать карточку после истечения, не достраивать `/download`,
`/play` или `/share` endpoint. API создания публичной ссылки не подтверждён.
[Android parsing][A-records], [серверная выдача][B-record-service]

В библиотеке подтверждены только `cursor,limit`: поиск/сортировка/период из макета
не являются серверными query-контрактами. Фильтровать загруженные страницы можно
лишь с явным указанием неполноты. Полный серверный поиск по библиотеке — BLOCKED.
Срок хранения «7 дней» в макете не считать неизменным свойством всех установок.

## Уведомления и календари

[Notification routes][B-notifications], [integration routes][B-integration-routes],
[DTO][B-integration-model], [handler][B-integration-handler], [service][B-integration-service].

| Метод и путь | Контракт |
| --- | --- |
| `GET /notifications` | Cursor-пагинация inbox и счётчик непрочитанных |
| `POST /notifications/:notificationId/read` | Прочтение своего уведомления |
| `GET /notifications/events` | SSE с Bearer, без query; подробнее REALTIME_PROTOCOL |
| `GET/PUT /notifications/preferences` | Голый объект `invitation,reminder,recording,email,push` (boolean) |
| `GET /notifications/devices` | `{items}` без токенов устройств |
| `POST /notifications/devices` | `{platform,token}` → 201 `{item}`; platform `web\|ios\|android`, token 8–8192 символа |
| `DELETE /notifications/devices/:deviceId` | Отзыв своего устройства → 204 |
| `GET /integrations/calendars` | `{items}` собственных подключений |
| `POST /integrations/calendars/mock` | Только при разрешённом mockConnect; не реальный календарь |
| `GET /integrations/calendars/:provider/connect` | `{authUrl,state}` |
| `POST /integrations/calendars/:provider/callback` | `{code,state}` → `{item}`; токены провайдера остаются на сервере |
| `DELETE /integrations/calendars/:provider` | Здесь `:provider` фактически **UUID подключения**, 204 |
| `GET /conferences/:id/calendar` | Сопоставления с внешними календарями |

Календарь встреч можно строить по timeline/schedule. Native EventKit sync и iOS
возврат из OAuth не следуют из наличия этих маршрутов: нужен отдельный проверенный
callback flow. Серверные adapters имеют режимы noop/mock/http. [Providers][B-providers]

Регистрация `platform=ios` не доказывает APNs. Push adapter отправляет generic
`push/send` внешнему шлюзу, а не реализует доказанную доставку APNs/VoIP.
В DTO нет APNs topic/environment/push-type и разделения обычного/VoIP token;
их обработку внешним шлюзом нужно подтвердить отдельно, не добавлять поля в JSON
самовольно. Входящие звонки подтверждены через `call.updated`, не через VoIP push.

## Личные звонки и realtime endpoints

[Call routes][B-calls], [модель][B-calls-model], [service][B-calls-service].

- `POST /calls`: `{targetUserId,clientRequestId,clientId}` → 201 / повтор 200 `{status,item}`.
- `GET /calls/active`: `{status,item}` (возможен `null`); `GET /calls/:id` — состояние.
- `POST /calls/:id/{accept,cancel,end,heartbeat}`: `{clientId}`;
  `POST /calls/:id/decline`: `{}`.
- `POST /ws-ticket`, `GET /ws`; `POST /conferences/:id/ws-ticket`,
  `GET /conferences/:id/ws`; `GET /webrtc/config` — [conference WS][B-ws], [user WS][B-user-ws].
  Форматы билетов и событий вынесены в [REALTIME_PROTOCOL.md](REALTIME_PROTOCOL.md).

## Явно отсутствующие или неподтверждённые контракты

| Функция | Статус | Основание |
| --- | --- | --- |
| Расшифровка, live captions, AI summary, semantic search, meeting analytics | BLOCKED | Удалены из текущего backend; миграция 000037 [removal][B-speech-removal] |
| Message emoji reactions | BLOCKED | В HTTP registration нет маршрута реакции на message ID |
| Смена пароля / reset password / смена email | BLOCKED | Нет маршрутов в проверенном auth registry |
| APNs и VoIP wake-up | BLOCKED | Есть generic gateway, нет подтверждённого Apple delivery contract |
| Полный поиск/фильтры библиотеки записей | BLOCKED | LibraryQuery принимает cursor/limit |
| iOS broadcast extension | BLOCKED до прототипа | SFU screen sources есть; ReplayKit интеграция ещё не реализована |

Пустые ответы, отсутствующие API и demo-данные не подменяются успешными операциями.
Новые серверные возможности могут быть только отдельным согласованным предложением.

<!-- pinned-source-links -->
[A-cookies]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/SessionCookieJar.kt
[A-origin]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/ServerOrigin.kt
[A-records]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/RecordingsApi.kt
[A-repository]: https://github.com/janickiy/meet-space-android/blob/b8f289983e60671d415a128734c2e5bb6e93a29d/core/data/src/main/kotlin/com/meetspace/core/data/DefaultFoundationRepository.kt
[B-accounts]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/accounts.go
[B-api-wiring]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/api.go
[B-auth]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/handler.go
[B-avatar-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/profile_avatar_routes.go
[B-calls]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/call_routes.go
[B-calls-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/calls/call.go
[B-calls-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/calls/service.go
[B-cap-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/platform_status_routes.go
[B-capabilities]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/platform/platform.go
[B-chat]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/chat_routes.go
[B-chat-actions]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/chat_actions_routes.go
[B-chat-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/chat/handler.go
[B-chat-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/chat/chat.go
[B-conference]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/conference.go
[B-errors]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/httpresponse/response.go
[B-folder-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/folders/handler.go
[B-folders]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/folder_routes.go
[B-group]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/personal/groups.go
[B-group-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/personal/group_handler.go
[B-group-policy]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/postgres/group_repository.go
[B-guest]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/conferences/guests.go
[B-guest-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/guest_routes.go
[B-integration-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/integrations/handler.go
[B-integration-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/integrations/integration.go
[B-integration-routes]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/integration_routes.go
[B-integration-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/integrations/service.go
[B-invitation-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/invitations.go
[B-invitations]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/invitation_routes.go
[B-moderation]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/moderation.go
[B-notifications]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/notification_routes.go
[B-operations]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/operations/runtime.go
[B-persistent-doc]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/docs/PERSISTENT_AUTH.md
[B-personal]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_routes.go
[B-personal-assets]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_asset_routes.go
[B-personal-handler]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/personal/handler.go
[B-personal-search]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/personal_search_routes.go
[B-platform]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/platform_routes.go
[B-product-wiring]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/product.go
[B-providers]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/providers/integrations.go
[B-reaction-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/engagement_routes.go
[B-record-card]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/records/dto.go
[B-record-delete]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/postgres/record_deletion.go
[B-record-library]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/recordings/library.go
[B-record-model]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/records/models.go
[B-record-policy]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/infrastructure/postgres/conference_recording_repository.go
[B-record-request]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/records/conference.go
[B-record-service]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/usecase/recordings/service.go
[B-records]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/conference_recording_routes.go
[B-search-route]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/search_routes.go
[B-sessions]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/app/auth/sessions.go
[B-speech-removal]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/docs/operations/speech-removal-upgrade.md
[B-telemetry]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/http/telemetry_routes.go
[B-timeline]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/conferences/product.go
[B-user-ws]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/websocket/user_handler.go
[B-users]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/domain/users/user.go
[B-ws]: https://github.com/janickiy/meet-space/blob/56a0b0721806f7db5ad4e658c856ddfe8ebd6acd/internal/transport/websocket/handler.go
