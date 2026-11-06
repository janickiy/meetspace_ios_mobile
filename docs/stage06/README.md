# Этап 06 — демонстрация экрана ReplayKit

Реализация от 2026-11-06 использует существующие API/SFU без изменений backend.
Broadcast Upload Extension, передача кадров в приложение, screen track и интерфейс
реализованы. Приёмка настоящей трансляции iOS → Web/Android и измерения на физических
iPhone/iPad остаются **BLOCKED/NOT_RUN**; тесты ниже их не заменяют.

## Поведение

В конференции и принятом личном звонке доступно действие «Показать экран». Приложение
готовит одноразовую сессию и показывает настоящий `RPSystemBroadcastPickerView`.
Пользователь сам нажимает системную кнопку и подтверждает трансляцию. Обхода picker
через поиск внутренних кнопок или искусственный tap нет. Отмена в приложении и
90-секундный предел ожидания отзывают подготовленную сессию.

Расширение `BroadcastUpload.appex` получает видеобуферы ReplayKit, ограничивает
обработку 10 FPS и 1280×720 в любой ориентации (либо меньшими серверными пределами).
NV12 масштабируется до преобразования в BGRA; восемь EXIF-ориентаций приводятся к
прямому изображению. Системный и микрофонный звук расширения игнорируется. Обычный
микрофон конференции/CallKit остаётся отдельным источником.

Кадры идут по локальному `AF_UNIX` socket в App Group. На диске остаются только
краткоживущий descriptor с nonce/UUID, socket и lock-файл: пиксели, токены аккаунта,
SDP, SFU tickets и адрес сервера туда не записываются. Расширение не линкует WebRTC
и не получает credentials. В приложении один новейший кадр ожидает обработки;
записи в socket ограничены deadline, при частичной передаче с ошибкой соединение
закрывается. При остановке старые UUID и tasks отзываются до дальнейшей обработки.

Передача идёт через существующий `media.offer`, source `video/screen` и отдельный
screen transceiver. Новый старт получает новый publication generation UUID, без
наращивания числа SDP-секций. «Вы демонстрируете экран» появляется только после
кадра и `media.ready` ACK. Остановка выключает локальный sender сразу; повторный
старт ждёт подтверждения удаления публикации или закрытия peer. Конфликт
`screen_sharing_conflict` откатывает предложение и выключает только экран, сохраняя
микрофон/камеру разговора. Запрет screen **или camera** организатором также запрещает
screen video. В интерфейсе используется консервативный режим одного демонстрирующего;
серверный лимит проверяется независимо.

При выходе из приложения камера отключается. Встреча сохраняет соединение на время
подготовленной/идущей демонстрации, но выключает микрофон; личный звонок сохраняет
аудио под CallKit. ReplayKit не гарантирует работу основного процесса в фоне:
если его heartbeat прекращается, расширение завершает трансляцию. После потери
сети, выхода, смены аккаунта, запрета или завершения звонка автоматического нового
захвата нет. Pause снимает screen publication; resume действующей системной
трансляции проходит повторное согласование и снова может получить конфликт.

Удалённый screen отображается с сохранением полного кадра, без зеркалирования,
выше участников встречи; в личном звонке имеет приоритет перед камерой. Локальная
трансляция обозначается баннером с остановкой. Основа интерфейса взята из фактических
макетов; системный picker и состояния ошибки/паузы/конфликта — iOS-адаптация.
Полная пиксельная идентичность не заявляется.

## Фактические проверки

| Проверка | Результат |
| --- | --- |
| Контракты backend, Android, опубликованные макеты | PASS — [аудит](CONTRACT_AUDIT.md), upstream commits не изменились относительно этапа 5 |
| Swift package на локальном host | PASS — 132 пройдено, 3 opt-in SKIP; всего 135 |
| AF_UNIX IPC | PASS — кадр/lease, pause/resume, stop/restart, единственный владелец, отзыв до запуска extension, истечение heartbeat |
| Преобразование кадров | PASS — фактические CoreVideo/vImage: 8 EXIF-ориентаций, NV12 video/full range, масштабирование и bounds |
| Coordinator | PASS — consent + frame + ACK, stop во время pending offer, старые кадры, conflict без потери разговора, policy и background/leave |
| Extension API safety | PASS — Swift 6 typecheck против Catalyst Apple SDK 26.4 с `-application-extension`; это не iOS build и не device test |
| Одноразовый backend/SFU | PASS — два Pion peer, synthetic VP8/Opus RTP, conflict, 10 start/stop, screen/camera moderation, disconnect и освобождение ресурсов |
| Xcode Release с `BroadcastUpload.appex` | PASS — `BUILD SUCCEEDED`, embedded extension validation прошла |
| iPhone SE (3rd generation), iOS Simulator 26.2 | PASS — 6 hosted + 17 UI = 23, 0 failures / 0 skipped |
| iPad mini (A17 Pro), iOS Simulator 26.2 | PASS — 6 hosted + 17 UI = 23, 0 failures / 0 skipped |
| Подписанный ReplayKit вне приложения, Web/Android показывают экран iOS | BLOCKED — нужны Apple provisioning/App Group, физические устройства и HTTPS/WSS deployment |
| FPS, CPU, RAM, thermal, lock/unlock, low-memory на iPhone/iPad | NOT_RUN — целевые ограничения в коде не являются измерениями |

Runtime evidence: [результаты](evidence/runtime/screen-probe.log),
[происхождение и source hashes](evidence/runtime/runtime.json),
[SFU cleanup](evidence/runtime/sfu-cleanup.json). Проба переслала 703 RTP-пакета;
после очистки активных rooms/peers/tracks/subscriptions — 0. Она не декодирует
изображение, не использует ReplayKit, не проверяет native rollback и не доказывает
показ кадра браузером/Android. Native rollback проверяется отдельным hosted тестом.

## CI и визуальная проверка

Исполняемый код проверен в commit `8d3aea2514f00d2475460a951341f44103378c9d`:
[GitHub Actions run 42193118692](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42193118692).
Все три job завершились успешно. После этого commit добавлены только документация
и evidence. Состав SDK/симуляторов, SHA и artifact digests сохранены в
[ci-run.json](evidence/ci-run.json); выдержки результатов:
[host](evidence/host-results.txt), [package + Release](evidence/package-results.txt),
[iPhone](evidence/iPhone-results.txt), [iPad](evidence/iPad-results.txt).

Hosted тесты используют настоящий WebRTC M156: проверены rollback, повторные
screen generations без роста SDP, ограничения источников, некорректные и старые
кадры. Они не запускают ReplayKit extension и не проверяют захват камеры/микрофона.
UI-тесты используют DEBUG doubles для REST, signaling, media и Broadcast controller;
это проверка интерфейса и lifecycle приложения, а не системного согласия на захват.

Проверены 10 скриншотов двух устройств: активный показ, остановка, конфликт в личном
звонке, управление звонком и чат с клавиатурой. Баннеры и ошибки читаемы, основные
действия доступны; чат не перекрывается клавиатурой. На маленьком iPhone дополнительные
действия личного звонка находятся в прокручиваемой области. Пиксельное соответствие
всех состояний макетам и Dynamic Type для нового picker отдельно не подтверждены.
Происхождение и SHA-256 каждого изображения: [screenshots.json](evidence/screenshots.json).

| Состояние | iPhone | iPad |
| --- | --- | --- |
| Идёт демонстрация (fixture) | [скриншот](evidence/screenshots/iPhone-stage06-meeting-sharing.png) | [скриншот](evidence/screenshots/iPad-stage06-meeting-sharing.png) |
| Остановлена, доступен новый запуск | [скриншот](evidence/screenshots/iPhone-stage06-meeting-stopped.png) | [скриншот](evidence/screenshots/iPad-stage06-meeting-stopped.png) |
| Конфликт, разговор сохранён | [скриншот](evidence/screenshots/iPhone-stage06-direct-conflict.png) | [скриншот](evidence/screenshots/iPad-stage06-direct-conflict.png) |
| Управление личным звонком | [скриншот](evidence/screenshots/iPhone-stage06-direct-controls.png) | [скриншот](evidence/screenshots/iPad-stage06-direct-controls.png) |
| Чат и клавиатура | [скриншот](evidence/screenshots/iPhone-stage06-meeting-chat.png) | [скриншот](evidence/screenshots/iPad-stage06-meeting-chat.png) |

## Файлы и воспроизведение

Основные изменения: `BroadcastExtension/`, новый модуль `Sources/Broadcast`,
`ConferenceSession`, `ScreenShareControls`, `LiveConferenceView`, `DirectCallView`,
DI workspace/identity, `NativeConferenceMediaEngine`/`NativePeer`, Xcode generator,
entitlements/Info/privacy manifests и проверки Broadcast/Session/native/UI.
`Sources` относится к `Packages/MeetSpaceKit`.
Полный список добавленных/изменённых файлов относительно этапа 5:
[CHANGED_FILES.md](CHANGED_FILES.md).

```sh
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_foundation.py
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
git diff --check
```

Финальный локальный запуск этих проверок прошёл; аудит сверил 120 source hashes,
124 design files и 156 route/group declarations. Локально установлен CLT, без Xcode:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Команды CI с Xcode 16.4 / iOS SDK 18.5 (тестовые runtime 26.2):

```sh
swift test --package-path Packages/MeetSpaceKit
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/ci_simulators.py --family iPhone
python3 scripts/ci_simulators.py --family iPad
```

Настоящий изолированный backend/SFU (нужны Docker, Go, pinned checkout backend;
output должен быть новым каталогом):

```sh
python3 scripts/run_replaykit_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage06-contract-01
```

Runner удаляет одноразовые контейнеры/сеть, не меняет backend и production-данные.
Настройка подписи и конкретные условия device-приёмки —
[DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md). Этап 7 не запускался.
