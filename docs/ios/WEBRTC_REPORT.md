# Этап 04: WebRTC, SFU и видеоконференции

Дата: 2026-11-05. Реализация по `04_WEBRTC.md` в репозитории
`janickiy/meetspace_ios_mobile`, указанном пользователем. Backend не изменён.
Этап 05 не выполнялся.

Итоговый iOS source commit: **PENDING**. Проверки GitHub Actions для итогового
коммита: **PENDING**. Ниже зафиксированы уже выполненные локальные проверки;
их результаты не заменяют итоговую проверку сборки и устройства.

## Источники и библиотека

| Источник | Зафиксированная версия | Использование |
| --- | --- | --- |
| backend `janickiy/meet-space` | `0bd1248a2411842515af4e02f1e95821616748fb` | REST, WS tickets, `media.*`, Pion SFU, права и гости |
| Android `janickiy/meet-space-android` | `b8f289983e60671d415a128734c2e5bb6e93a29d` | Последовательность сигнализации, публикации, состояния устройств |
| Макеты `janickiy/mobile_maket` | `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3` | Экран встречи, участники, чат, палитра и Inter |
| WebRTC Swift Package | `stasel/WebRTC`, exact `156.0.0` | Нативный PeerConnection, захват и renderer |
| WebRTC upstream | `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d`, `branch-heads/8078` | Исходная версия опубликованного binary artifact |

Backend runtime-код совпадает с исходным аудитом `56a0b07`; между pins изменён
README. Проверенный backend checkout остался чистым. Макеты существуют, поэтому
оговорка исходного задания о пустом репозитории к этой реализации не применяется.

SHA-256 загруженного `WebRTC-M156.xcframework.zip`:
`43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46`.
Лицензия WebRTC BSD-3-Clause, LICENSE/PATENTS/distribution LICENSE включены
в ресурсы модуля. У дистрибьютора есть device arm64 и simulator arm64/x86_64 slices.
Хэш, privacy manifest и ограничения лицензирования записаны в
[манифесте библиотеки](evidence/stage04/webrtc-library.json).
Полные transitive third-party notices требуют отдельной проверки перед App Store.

## Реализованные компоненты

- `ConferenceRepository`: список/создание/статусы, приглашения, join/leave,
  участники/self, admission, moderation, media state, реакции, tickets,
  ICE configuration, сообщения/поиск/read state.
- `ConferenceInviteGateway`: публичное приглашение и guest join/resume.
  Гостевой bearer находится только в памяти и ограничен своим HTTPS-origin
  и conference ID; guest не использует account refresh/cookie.
- `ConferenceSignaling`: bounded envelopes и typed payloads, одноразовый
  WS ticket, subprotocol `go-recorder.v1`, проверка room/peer/request scope.
- `MeetSpaceMedia`: Unified Plan PeerConnection, Opus/VP8, STUN/TURN,
  камера/микрофон, переключение камеры, renderer, AVAudioSession voiceChat,
  Bluetooth route, interruptions и NWPathMonitor.
- `ConferenceSession` и `ConferenceWorkspace`: согласование offer/answer/ready,
  сериализация renegotiation, track catalog, media policy, reconnect,
  фон/возврат, локальное освобождение ресурсов.
- SwiftUI встреча использует отдельное состояние реальной конференции;
  тестовые media/socket doubles предназначены для проверок и превью.

Основные новые файлы находятся в
`Packages/MeetSpaceKit/Sources/{Core/Conference,API/ConferenceRepository,Realtime/ConferenceSignaling,Features/ConferenceSession,Features/ConferenceWorkspace}.swift`
и `Packages/MeetSpaceKit/Sources/Media/`.
Контрактные проверки находятся в `Packages/MeetSpaceKit/Tests/IntegrationTests/`;
настоящий SFU запускается через `scripts/run_webrtc_contract.py`,
его синтетический клиент — `scripts/fixtures/sfu_probe.go`.

## Контракт и права

Используется текущий SFU-протокол `media.*`. Старые `webrtc.*` события
относятся к другому механизму relay и не подменяют SFU.

1. REST join создаёт/активирует membership; владелец новой встречи сначала
   имеет статус `left`. Для конференции и membership нужны отдельные переходы.
2. `POST /conferences/{id}/ws-ticket` выдаёт одноразовый ticket;
   подключение использует `/conferences/{id}/ws?ticket=…`.
   Access token не помещается в WS URL.
3. `conference.state` даёт connection ID и roster. Затем `media.join`
   возвращает mediaPeerId, maxPeers, worker ICE, capture limits и policy.
4. Клиент создаёт offer с публикациями, применяет answer, затем отправляет
   `media.ready`. SFU не пересылает RTP до ready.
5. `media.tracks`/`media.renegotiate` требуют нового offer без параллельных
   negotiation. ICE использует явный `candidate: null` для завершения.
6. Новый WS/peer получает новые IDs; REST media state использует sequence
   своей connection. UUID wire-строки отправляются lowercase.

Backend допускает maxPeers 2…32, default 10; предел не зашит как 16 участников.
Поддерживаемые SFU кодеки — Opus 48 kHz stereo и VP8. Публикация simulcast
и других кодеков этим этапом не добавляется. Дорожки экрана могут приниматься;
публикация экрана iOS не входит в этап 04.

Запрет камеры/микрофона требует убрать публикацию и отправляющее направление
transceiver. Одного `track.enabled = false` недостаточно: SFU отклоняет
запрещённую публикацию. Снятие запрета не включает устройство без действия
пользователя. После reconnect/background capture также остаётся выключенным.

Owner может управлять разрешёнными действиями над другим участником;
co_host — только mute/screen/kick над обычным participant. Самоуправление
и moderation owner запрещены. UI не заменяет серверную авторизацию.
Фактическая роль нового guest — `participant`; guest scope определяется
JWT/user `guestConferenceId`, а не выдуманной ролью `guest`.
Действительное приглашение допускает немедленный вход через waiting room.
Admission не навязывается локально в обход фактического ответа API.

`GET /webrtc/config` предоставляет iceTransportPolicy и expiry временного TURN.
`media.joined` предоставляет ICE конкретного worker; API controller не
прокидывает туда policy/expiry. Эти поля нужно учитывать раздельно.

## Проверки и их границы

| Критерий | Статус | Фактическое доказательство / граница |
| --- | --- | --- |
| REST конференций, guest scope, роли | PASS | Swift-клиент против настоящего pinned API: create/start/join, guest, 403 moderation, leave/rejoin/finish |
| Чат конференции и реакции | PASS | Настоящий API: idempotency, reply/edit/search/read/delete, guest message, допустимые реакции |
| Контракты и модель соединения | PASS для проверенного снимка | 20 filtered tests: роли/scope, framing/ICE, ready gate, таймауты, moderation при permission, background и cleanup |
| SFU offer/answer/ready и RTP | PASS для синтетических клиентов | Два Pion клиента, двусторонние Opus/VP8 RTP, три цикла; по две negotiation на peer в каждом цикле |
| Серверное соблюдение media policy | PASS | Публикация камеры после блокировки модератором отклонена настоящим SFU |
| SFU cleanup | PASS | После закрытия rooms/peers/tracks/subscriptions = 0, peer failures = 0 |
| Нативный WebRTC binary | PASS в host probe | 10 create/offer/close циклов M156, SDP msid/track IDs, Opus/VP8, закрытый peer отклоняет offer |
| Полный native adapter typecheck | PASS для проверенного снимка | Mac Catalyst slice M156 и Apple UIKit/AVFoundation headers; это не runtime iOS test |
| Lifecycle review и workspace regressions | PASS для проверенных сценариев | Замечания исправлены; 7 дополнительных тестов задержанных leave/join, повторного dismiss/create, scheduled owner invitation и guest callback после restore |
| Release iOS build, iPhone/iPad UI в CI | PENDING | Workflow итогового source commit ещё не подтверждён |
| iOS ↔ Web/Android двусторонние аудио/видео | BLOCKED для device acceptance | Нужны физические устройства, signing и доступный HTTPS/WSS deployment |
| Камера, микрофон, Bluetooth, interruption, Wi-Fi↔LTE | BLOCKED для device acceptance | Host probe и synthetic RTP не проверяют физический захват/маршрутизацию |
| TURN relay / production TLS | BLOCKED для deployment acceptance | Проверенный harness использовал direct Docker network; relayConnections = 0 |
| Полное соответствие макетам и VoiceOver | PENDING/BLOCKED | Нативные снимки итогового UI и ручная доступность ещё не приняты |

PASS относится только к указанному сценарию. Синтетические RTP payloads служат
проверке передачи пакетов; они не подтверждают декодированное качество
звука/изображения, физический захват или взаимодействие настоящего iOS клиента
с Web/Android.

В успешно завершившемся полном прогоне SFU переслал 1286 RTP packets,
11277 bytes, без dropped packets. После проверки:
`roomsActive=0`, `mediaPeersActive=0`, `tracksPublished=0`,
`subscriptions=0`, `peerConnectionTotal=7`,
`peerConnectionFailures=0`, `directConnections=6`, `relayConnections=0`.
Первый медиасеанс длился более шести секунд, то есть дольше WS pong deadline 4s.
Контейнеры, volumes и network этого запуска удалены.

[Нативный host probe](evidence/stage04/native-peer-host-probe.txt) сохранён
в репозитории. Локальные журналы полного REST/SFU прогона:
`/tmp/meetspace-stage04-contract-03/{contract.log,sfu-probe.log,sfu-cleanup.json,runtime.json}`.
Локальные unit results:
`/tmp/meetspace-stage04-conference-unit.log`.
Последующие полные host tests: `/tmp/meetspace-stage04-full-tests.log`.
Workspace regressions после последних исправлений:
`/tmp/meetspace-stage04-workspace-tests.log` — 7 tests, 0 failures, 0.059s.
Перенос итоговых очищенных evidence в `docs/ios/evidence/stage04/`: **PENDING**.
Private service logs не предназначены для публикации.

## Фактические команды

На этом host установлены Command Line Tools, полного Xcode нет:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  --filter '^IntegrationTests\.conference'
python3 scripts/run_webrtc_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage04-contract-03
git diff --check
```

Первый запуск: 20 tests, 0 failures, 0.080s. Настоящий Swift REST contract:
1 test, 0 failures, 0.294s; затем PASS policy probe и три SFU media cycles.
Эти числа описывают указанные журналы, а не ещё не выполненный итоговый CI.

Дополнительно с теми же SDK/plugin аргументами выполнен filter
`IntegrationTests\.(conferenceWorkspace|conferenceGuestLate)`.
Проверены два последовательных dismiss при задержанном REST leave, запрет
создания поверх действующего звонка, компенсационный leave после закрытия
workspace во время join, запрет позднего start после закрытия, запуск owner
по scheduled invite, неподтверждённый выход и поздний guest POST после restore.
Если сервер не подтвердил выход, локальная камера/микрофон уже закрыты;
busy заканчивается, показывается ошибка, повторное использование этого workspace
остаётся запрещено. Поздний успешный callback после deadline не снимает запрет.

Harness проверяет точный backend pin и отсутствие изменений его tracked sources.
Собирает unmodified API/media-worker и отдельный test-only Go/Pion клиент,
запускает свои Postgres/Redis/MinIO/RabbitMQ/API/SFU в отдельной Docker network.
На host доступны только случайные loopback ports. Секреты/временные аккаунты
создаются для этого запуска; bearer tokens хранятся в памяти. Ни данные
пользовательских сервисов, ни production credentials не используются.

На другом host сначала нужен образ MinIO из pinned backend:

```sh
docker build -f /path/to/backend/dockers/minio/Dockerfile \
  -t go-recorder-minio:local /path/to/backend
python3 scripts/run_webrtc_contract.py --backend /path/to/backend
```

Опция `--skip-swift` запускает только SFU probe и явно помечает Swift contract
SKIPPED. Для опубликованного полного результата эта опция не использовалась.
Тестовый HTTP/WS loopback adapter не входит в приложение. Production transport
требует HTTPS/WSS с системной TLS-проверкой; ATS bypass не добавлялся.

## Оставшаяся приёмка

Перед окончательным утверждением этапа нужны итоговые source SHA и CI run,
нативные iPhone/iPad снимки,
физические iOS ↔ Web/Android media tests и relay/network/interruption matrix.
Устройство должно подтвердить отсутствие активных capture sessions после
повторных join/leave. Серверные нулевые метрики и host PeerConnection cleanup
сами по себе этого не доказывают.

Запись, push, CallKit, screen broadcast extension и App Store distribution
не заявляются результатом этапа 04.
