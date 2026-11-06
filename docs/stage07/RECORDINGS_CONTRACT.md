# Записи: контракт и реализация iOS

Аудит 2026-11-06. Backend `0bd1248a2411842515af4e02f1e95821616748fb`, Android
`b8f289983e60671d415a128734c2e5bb6e93a29d`, mobile_maket
`04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`. Backend не изменялся.

## Фактический API

| Операция | Маршрут | Правила |
| --- | --- | --- |
| Возможности | `GET /api/v1/capabilities` | `{capabilities:{recordingModes:[...]},buildVersion}`; отсутствие известного режима выключает его запуск |
| Общая библиотека | `GET /api/v1/recordings?limit=30&cursor=...` | `{items:[{conference,recording}],nextCursor}`; ограниченный курсор; 404/501 — несовместимый сервер |
| Записи встречи | `GET /api/v1/conferences/:id/recordings?limit=100&offset=0` | Зарегистрированный участник с `CanReadHistory`, не guest |
| Карточка | `GET /api/v1/conferences/:id/recordings/:rid` | Повторная авторизация, UUID записи/конференции проверяются |
| Начать | `POST /api/v1/conferences/:id/recordings`, `{mode}` | Зарегистрированный `CanParticipate`, встреча active; роль participant допустима; 202 не означает начало захвата |
| Остановить | `POST .../:rid/stop`, `{}` | `CanReadHistory`; owner с ролью owner либо `requestedBy`; 202 не означает готовый файл |
| Удалить | `DELETE .../:rid` | Те же owner/requester + membership, terminal status, нет активной recorder lease; подтверждение в UI |

Источники backend: `internal/transport/http/conference_recording_routes.go`,
`internal/app/recordings/{handler,library}.go`, `internal/app/platform/handler.go`,
`internal/domain/records/{dto,library,models,conference}.go`,
`internal/infrastructure/postgres/{conference_recording_repository,record_deletion,recording_library}.go`.
Android: `core/model/.../RecordingsModels.kt`, `core/data/.../{RecordingsApi,RecordingsRepository,ScopedRecordingAccess}.kt`.

Режимы: composite, audio_only, individual_tracks, screen_focus. Статусы starting,
recording, degraded, stopping, processing (публичное отображение finalizing/uploading),
ready, partial_ready, failed, cancelled. Неизвестные режимы не предлагаются к запуску;
неизвестный статус не считается готовым. Pause/resume записи в API нет, поэтому
нарисованная в макете пауза записи не реализуется как выдуманный вызов.

## Доступ к файлам

Карточка содержит numeric `id` и `uuid`. У файла проверяется `recordId`, UUID,
тип, MIME, положительный размер, SHA-256 (если дан), безопасное имя; неизвестные
типы не экспортируются. Поддержаны final_mp4/video/mp4, final_audio/audio/mp4,
tracks_archive/application/zip и preview_jpg/image/jpeg. Signed URL остаётся внутри
API, не хранится в observable/persistent state и не попадает в текст ошибок.

Перед каждым скачиванием выполняется авторизованный GET карточки. Затем отдельная
ephemeral URLSession читает HTTPS signed URL без bearer, Cookie, credential storage,
дискового URL cache и переходов 3xx. Разрешён внешний HTTPS object-storage origin:
так устроен действующий контракт сервера. HTTP, userinfo, fragment, protocol-relative
и неоднозначные адреса отвергаются. API bearer никогда не передаётся object storage.

Байты пишутся на диск порциями по 64 KiB; проверяются MIME, размер, фактическая длина
и SHA-256 при наличии. Локальный предел **512 MiB** явно обозначен в интерфейсе.
Нет загрузки большого файла целиком в Data. После загрузки API ещё раз проверяет
права и неизменность файла. При отказе локальный файл удаляется. Это проверяет доступ
на момент начала воспроизведения/экспорта, но не обещает мгновенную остановку уже
идущего локального воспроизведения при последующем удалённом отзыве прав.

AVPlayer получает только локальный проверенный файл, проигрывание начинается после
полной загрузки. Есть явная ошибка неподдержанного/повреждённого media; архивы дорожек
только скачиваются. При уходе из экрана/смене аккаунта player закрывается, transfer
отменяется, UUID поколения предотвращает позднее восстановление state. При фоне
player ставится на паузу. Файлы account-scoped, исключены из backup, имеют Complete
file protection на iOS, удаляются при закрытии модели; после аварийного завершения
остаток удаляется при следующем создании downloader для этого аккаунта.

Сохранение пользователем — системный share sheet; экспортированная копия находится
под управлением выбранного приложения/Files и не может быть отозвана MeetSpace.
Системный звук ReplayKit не добавляется обещанием записи сервера.

## UI и границы

Основа: `meetspace-refresh-20261016/recordings-refresh.{js,css}` (compact card library,
search/mode/status filters, player/detail/materials) и `call-meeting.css` (recording
control). Используется существующий MSTheme/Inter. Нет выдуманных участников/preview:
пока preview не загружен авторизованным потоком, карточка показывает нейтральную иконку.
Поиск и фильтры локальные и явно ограничены загруженными страницами; библиотека не
привязана к видимости или жизненному циклу встреч. Срок хранения не зафиксирован как
«7 дней» из примера: приложение сообщает, что он определяется сервером.

Начало/остановка в meeting control обновляет карточки и показывает промежуточные
статусы; открытая панель встречи обновляется каждые 5 секунд. После неопределённого
ответа на start/stop сначала перечитывается состояние, автоматического повтора
команды нет. Backend остаётся окончательной проверкой прав. Гостевой UI не получает
account-scoped RecordingsModel.

Расшифровка/ИИ-итоги, backend recording worker health и готовность конкретного
кодека не выводятся из одного `recordingModes`. Они не заявляются этой реализацией.

## Проверки

Новые `RecordingsTests.swift` проверяют реальные route/payload contracts и capabilities,
границы scope/URL, actual URLSession→disk поток с hash/size/MIME, запрет redirect,
403, отзыв прав после загрузки, отмену при закрытии аккаунта и матрицу owner/requester/
participant/guest. HTTP в этих тестах подменяет URLProtocol/RoutedTransport: это не
проверка production object storage или камеры/сервера записи.

UI/hosted AVPlayer используют отдельный 2-секундный H.264 160×90 fixture без аудио,
созданный через AVAssetWriter: 2972 bytes, SHA-256
`d890abd6474dfc4653d493c660f06bd510575e0cf6914e998ed23b132263bb93`.
Фактические итоговые команды/результаты CI и backend стенда приведены в общем отчёте
этапа 7. Реальное воспроизведение артефакта production SFU recording pipeline и
проверки на физических устройствах требуют отдельного окружения; simulator fixture
не объявляется таким подтверждением.

Документация Apple: [VideoPlayer](https://developer.apple.com/documentation/avkit/videoplayer),
[URLSession.AsyncBytes](https://developer.apple.com/documentation/foundation/urlsession/asyncbytes).
