# Этап 06 — фактический контракт демонстрации экрана

Проверено 2026-11-06 по исходникам и `git ls-remote HEAD refs/heads/main`.
Backend не изменялся; tracked-файлы checkout чистые. Документ описывает существующий контракт,
а не новый серверный API. Физическая проверка ReplayKit и измерения производительности отдельны от SFU probe.

| Источник | Проверенный HEAD/main |
| --- | --- |
| [Backend](https://github.com/janickiy/meet-space/tree/0bd1248a2411842515af4e02f1e95821616748fb) | `0bd1248a2411842515af4e02f1e95821616748fb` |
| [Android](https://github.com/janickiy/meet-space-android/tree/b8f289983e60671d415a128734c2e5bb6e93a29d) | `b8f289983e60671d415a128734c2e5bb6e93a29d` |
| [Макеты](https://github.com/janickiy/mobile_maket/tree/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3) | `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3` |

## Запуск, остановка и wire format

Команд `screen.start`/`screen.stop` и отдельного REST endpoint запуска экрана в этом backend нет.
Экран — дополнительная публикация в обычном `media.offer` текущего авторизованного WebRTC peer.
Существующие ticket, `media.join`, ICE, `media.answer` и `media.ready` сохраняются.
Все UUID команд должны быть каноническими, ненулевыми и в нижнем регистре.

```json
{
  "mediaPeerId": "11111111-1111-4111-8111-111111111111",
  "negotiationId": "22222222-2222-4222-8222-222222222222",
  "sdp": "<generated offer>",
  "publications": [
    {"mid": "0", "source": "microphone", "trackId": "microphone-generation"},
    {"mid": "1", "source": "camera", "trackId": "camera-generation"},
    {"mid": "2", "source": "video/screen", "trackId": "screen-generation"}
  ]
}
```

Это `data` конверта версии 1 с `id`, `type:"media.offer"`, `conferenceId`, `timestamp`.
Список отражает **все** активные исходящие источники этого offer. Единственные source literals:
`microphone`, `camera`, `video/screen`, `audio/screen`; aliases отсутствуют.
Screen video требует video m-line с направлением `sendonly` или `sendrecv` и поддержкой VP8.
Screen audio требует отдельную audio m-line с Opus и одновременно заявленный `video/screen`.
Наличие серверного audio-контракта не доказывает возможность или реализацию системного аудио на iOS.

Остановка: немедленно прекратить локальный захват/передачу, убрать screen publication, перевести
его m-line в `recvonly`/`inactive`, отправить новый offer; после применения answer отправить `media.ready`
с тем же negotiationId. Существует также `media.unpublish {mediaPeerId,trackId}`, где trackId —
**серверный ID** из `media.published`, а не capture generation. Отключение `track.isEnabled` без изменения
публикации не освобождает резерв демонстрации.

Источники: [sources и DTO](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/media/media.go#L65),
[строгая валидация команд](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/media/controller.go#L526),
[SDP/publication validation](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/peer.go#L677).

## Владение, конкуренция, поколения

- SFU резервирует screen slot **по mediaPeerId**, а не по аккаунту или participantId, атомарно под mutex комнаты.
  По умолчанию `MEDIA_MAX_SCREEN_SHARERS=1`; конфигурация допускает 1–4. Два подключения одного участника
  конкурируют так же, как разные участники. Клиент не получает отдельного API предварительного резерва.
- Проверка policy и screen reservation выполняется до `SetRemoteDescription`. Если слот занят,
  correlated `error` с `code:"screen_sharing_conflict"` и `replyTo` исходного offer возвращается без
  изменения прежних publications/SDP состояния сервера. Web откатывает локальный offer, удаляет screen
  sources и повторяет offer с прежними микрофоном/камерой. Захват не должен автоматически повторяться.
- `publications[].trackId` — необязательный opaque capture-generation ID, максимум 128 байт,
  без CR/LF/NUL. Сервер **не сравнивает** его с SDP `msid` или `TrackRemote.ID`.
  После `media.unpublish`/окончания screen source тот же MID и прежняя generation остаются suspended;
  новый непустой generation ID или промежуточный offer без этого source снимает suspension.
  Клиент обязан отдельно отсечь кадры старого ReplayKit/IPC поколения: RTP сам по себе не содержит эту границу.
- Лимит `4 * maxPeers` применяется ко **всем** SDP media sections, включая rejected/stopped.
  Постоянное добавление нового transceiver при каждом старте исчерпает бюджет. Переиспользование screen slot
  с новой publication generation соответствует контракту. По умолчанию maxPeers=10, а клиент должен
  использовать фактическое значение `media.joined` и свои более строгие поддерживаемые пределы.
- Максимум публикаций — 4, audio sources — 2, video sources — 2; source и MID уникальны.
  SDP не больше 128 KiB. Размеры/FPS из конфигурации worker — рекомендации захвата, не измерение устройства.

Источники: [atomic reservation](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/policy.go#L144),
[offer/generation sequencing](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/peer.go#L359),
[web conflict rollback](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/frontend/src/media.ts#L1405),
[defaults](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/config/media.go#L77).

## Policy, presence и очистка

| Условие | Реальное поведение |
| --- | --- |
| `screenBlocked` или `cameraBlocked` | Video/screen запрещён; текущий screen slot и tracks снимаются |
| `microphoneBlocked` | Video/screen остаётся допустимым; microphone и audio/screen запрещены |
| `kicked` | Все источники запрещены, все media peers участника закрываются |
| `screen` unblocked | Разрешает новый явный запуск; не восстанавливает capture или presence автоматически |
| Удаление video/screen | Удаляет связанный audio/screen; освобождает reservation |
| Физический WS disconnect | Controller удаляет привязанный peer и отправляет worker leave; очистка ограничена этим connection |
| Peer leave/transport failure/room shutdown | SFU detach удаляет peer, reservation и принадлежащие tracks/subscriptions |

Модерация: `POST /api/v1/conferences/{id}/participants/{participantId}/moderation`
с `{ "action":"screen", "blocked":true }` или `camera`. В активной конференции owner может
модерировать другого участника, кроме owner; co_host может применить `screen`, `mute`, `kick`
только к обычному participant. `camera` доступно owner. Самомодерация запрещена.
Событие `media.policy` содержит `{mediaPeerId,policy:{version,microphoneBlocked,cameraBlocked,screenBlocked,kicked}}`.
Монотонная version должна применяться независимо от порядка roster/policy событий.

Presence: `PUT /api/v1/conferences/{id}/participants/me/media` с
`{connectionId,sequence,microphoneEnabled,cameraEnabled,screenSharing}`. Сервер проверяет принадлежность
живого connection, возрастающую sequence и policy. Эта запись **не резервирует** screen slot и не доказывает
наличие RTP. Presence агрегируется по активным подключениям участника; для состояния реально получаемого
экрана нужен `media.tracks`, для своей опубликованной дорожки — `media.published`.
Сервер генерирует track ID и `streamId = mediaPeerId + "-screen"` для screen sources;
входной SDP publisher streamId отдельно не ограничен этим суффиксом.

После `media.answer` forwarding на новые subscriber SSRC открывается лишь после соответствующего
`media.ready`. Если ready не пришёл, peer закрывает negotiation watchdog (по умолчанию 15 секунд).
Удаление source формирует `media.unpublished` издателю и `media.tracks`/`media.renegotiate` подписчикам.
Завершение конференции/звонка и отзыв membership используют существующий lifecycle доступа.

Источники: [policy](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/media/media.go#L113),
[немедленный отзыв источников](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/policy.go#L28),
[REST routes](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/transport/http/platform_routes.go#L80),
[роли](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/domain/conferences/moderation.go#L40),
[presence](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/postgres/moderation_repository.go#L195),
[track activation](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/tracks.go#L171),
[screen retirement](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/tracks.go#L442),
[disconnect](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/usecase/media/controller.go#L463),
[SFU detach](https://github.com/janickiy/meet-space/blob/0bd1248a2411842515af4e02f1e95821616748fb/internal/infrastructure/sfu/manager.go#L450).

## iOS scope и изолированная runtime-проверка

На входе этапа 6 существующая iOS сигнализация уже распознаёт remote `video/screen` и проверяет
серверный streamId, а session связывает screen video с participant. Недостающая исходящая часть:
Broadcast Upload Extension, app-group IPC, ограниченная очередь кадров в памяти, orientation/timestamps,
отдельный screen sender/generation, policy/conflict cleanup, presence и пользовательский start/stop.
Extension не должна получать аккаунтные bearer/refresh tokens или открывать параллельный SFU peer:
publication принадлежит текущему авторизованному connection основного приложения.
После завершения broadcast/сессии или смены аккаунта кадры прежнего поколения недопустимы.

Новые файлы теста: [runner](../../scripts/run_replaykit_contract.py) и
[synthetic Pion probe](../../scripts/fixtures/screen_probe.go). Они не изменяют прежние harness этапов 4/5.
Runner проверяет pin/чистоту backend, поднимает disposable Docker API/SFU/зависимости и удаляет только свои
контейнеры/сеть. Credentials остаются в памяти/приватном временном окружении и не копируются в evidence.

```sh
python3 scripts/run_replaykit_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage06-contract-01
```

**Runtime PASS, 2026-11-06:** screen VP8 + camera/Opus, single-presenter conflict, десять start/stop generations,
screen/camera moderation, повторный явный запуск и abrupt WS disconnect. Получены две SFU PeerConnection
без failures и 703 forwarded packets. Финальные `roomsActive`, `mediaPeersActive`, `tracksPublished`
и `subscriptions` равны нулю; directConnections=2, relayConnections=0.
Сохранены [вывод сценариев](evidence/runtime/screen-probe.log),
[нулевой снимок SFU](evidence/runtime/sfu-cleanup.json) и
[runtime receipt с pin, image IDs и SHA256 runner/probe](evidence/runtime/runtime.json).
Хэши исходников receipt сверены с текущими файлами. Приватные API/container logs и binaries в репозиторий не копируются.

Для ожидаемо отклоняемого offer probe не применяет local description: используемый Pion v4.2.12
не поддерживает переход локального rollback. Это проверяет атомарность серверного отказа и сохранение
соединения, но не доказывает rollback нативного iOS SDK. RTP содержит синтетический payload;
декодированная картинка, ReplayKit за пределами приложения, Web/Android interoperability,
system audio, реальные FPS/CPU/RAM, TURN/смена сети и физическое завершение capture этим тестом не доказаны.
