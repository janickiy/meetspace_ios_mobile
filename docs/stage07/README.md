# Этап 07 — календарь, записи, папки и настройки

Реализация от 2026-11-06 использует существующий backend без изменений. Реальные
контракты, Android и доступные макеты сверены с текущими main refs. Вход в новые
экраны доступен из профиля; календарь, записи и папки также открываются из встреч.
Этап 8 не запускался. SSH-установка остаётся отключённой функцией с планом.

## Реализовано

- **Календарь:** создание запланированной встречи, изменение времени/длительности,
  отмена владельцем, day selection, week/month/list, выбор IANA timezone. Сервер
  хранит UTC instant; выбранный пояс и вид сохраняются отдельно для каждого
  сервера/аккаунта. Учтены DST, полуоткрытые границы периода, независимая пагинация
  upcoming/active/past, частичная недоступность feed и неопределённый результат POST.
- **Записи:** общий каталог, режимы из server capabilities, статусы, карточка,
  начало/остановка из панели встречи, удаление по правам с подтверждением. Файл
  передаётся AVPlayer или системному экспорту после полной загрузки и проверки.
  Права проверяются до и после загрузки. Signed URL не сохраняется, account
  credentials не передаются storage; redirects/HTTP запрещены. Лимит 512 MiB,
  запись на диск порциями 64 KiB, отмена и очистка при закрытии аккаунта.
- **Папки:** создание, переименование, порядок вверх/вниз/по алфавиту, фильтры,
  поиск, страницы кандидатов/содержимого, добавление и удаление ссылок, открытие
  чата/встречи. Удаление папки не вызывает удаление контента.
- **Настройки:** изменение имени, пять серверных notification preferences,
  просмотр push-устройств, capabilities и integration providers. Существующие
  темы, несколько аккаунтов и permission flow APNs сохранены. Окончательные права
  проверяет сервер, новые модели очищаются при logout/switch/expiry.

Контракты и точные ограничения: [календарь](CALENDAR_CONTRACT.md),
[записи](RECORDINGS_CONTRACT.md), [папки](FOLDERS_CONTRACT.md),
[настройки/SSH](SETTINGS_SSH_CONTRACT.md).

## Проверки и критерии

| Критерий | Результат и граница |
| --- | --- |
| Корректность времени календаря | PASS — недели DST 167/169 часов, leap month, границы UTC; реальный API проверен в 3 timezone |
| Создание/перенос/отмена и права | PASS — настоящий backend, чужие изменения запрещены, отменённая встреча не переносится |
| Папка не удаляет контент | PASS — после удаления папки доступны встреча, чат и сообщение; чужие папки изолированы |
| Настройки сохраняются | PASS — профиль/preferences после нового login; timezone/view отдельно по аккаунтам/серверам |
| Права и lifecycle записей | PASS — настоящий API starting/stopping/catalogue, 403/409; unit tests URL/metadata/hash/отмена/отзыв прав |
| Полный Swift package на host | PASS — 159 выполнено, 4 opt-in SKIP, всего 163 |
| Xcode Release | PASS — CI на commit `4075edf`, BUILD SUCCEEDED |
| iPhone/iPad hosted и UI | PASS — по 29/29 на каждом симуляторе: 7 hosted + 22 UI, без пропусков |
| Настоящий recorder worker → готовый AAC и signed download | PASS — audio_only, настоящие состояния до ready, размер/hash, FFmpeg decode, запрет доступа постороннего и исключённого участника |
| Native AVPlayer с файлом настоящего worker | PASS — на обоих симуляторах проверены playable, audio track, duration и продвижение playback time; UI открывает тот же AAC по SHA-256 |
| Физические iPhone/iPad, long playback, background/lock, Files export | NOT_RUN — требуется подписанная установка и тестовый HTTPS deployment |
| SSH-установка | DISABLED / PLAN ONLY — локальный flag false, установка не выполнялась и не считается готовой |
| Проверка интерфейса | PASS в описанном объёме — 26 снимков iPhone/iPad. Доступные макеты использованы с перечисленными iOS-адаптациями; полная пиксельная идентичность не заявляется |

Четыре пропуска обычного suite — opt-in реальные backend-прогоны этапов 3, 4, 5 и 7.
Тест этапа 7 выполнен отдельно: **1 PASS, 0 SKIP**, 80 HTTP-запросов к одноразовому
backend. Подтверждены logout четырёх сессий и отсутствие созданных контейнеров/сетей
после очистки. [Подробности, команда и evidence](RUNTIME_CONTRACT.md).

Отдельно прошёл [полный серверный pipeline аудиозаписи](RECORDING_PIPELINE.md):
настоящие SFU, recorder/FFmpeg и S3, готовый AAC, проверка signed download и прав.
[Локальный Swift suite](evidence/host-results.txt) содержит отдельные результаты модулей.

## Воспроизведение

Локальный host имеет Command Line Tools SDK 26.4, без Xcode. Выполнены:

```sh
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_foundation.py
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
git diff --check
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
python3 scripts/run_features_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage07-features-02
python3 scripts/run_recording_pipeline.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage07-recording-pipeline-01
```

Статические проверки прошли: воспроизводимость Xcode project, локализации, модули,
ресурсы/TLS, 120 source hashes, 124 design files, 156 route/group declarations.
Проверка сигнатур credentials в изменённых текстах прошла; она не является полной
сертификацией отсутствия секретов. Runtime runner требует Docker, Go и pinned backend;
output должен быть новым пустым каталогом. Production данные не затрагиваются.

CI выполняет:

```sh
swift test --package-path Packages/MeetSpaceKit
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/ci_simulators.py --family iPhone
python3 scripts/ci_simulators.py --family iPad
```

## Ограничения приёмки

`recordingModes` само по себе не подтверждает работоспособность recorder/FFmpeg worker.
Отдельный одноразовый стенд этапа проверил настоящий audio_only pipeline с Opus
silence от Pion и готовым AAC, включая signed download и доступ. Такой вход не
является записью физического микрофона. Продуктовый HTTPS deployment, composite/
screen_focus video, ready/partial_ready с реальным устройством и Files export ещё
требуют приёмки. Нужно сверить звук/изображение/длительность, повторить после отзыва
membership и при потере сети, проверить большие файлы, нехватку места,
сворачивание/блокировку и logout во время загрузки на iPhone/iPad.

После начала локального проигрывания мгновенный удалённый отзыв прав не обещается.
Экспортированную пользователем копию нельзя удалить из чужого приложения. Временные
артефакты защищены и удаляются при закрытии модели, остаток после аварии — при
следующем открытии downloader этого аккаунта. Очистка best-effort: ошибки файловой
системы не отображаются, гарантии удаления при I/O failure нет. Системный звук
ReplayKit не обещается.

UI suite использует DEBUG API/media fixtures. Системное предложение сохранить
фиктивный пароль отклоняется; хранение credentials в Passwords и OS AutoFill
требуют отдельной проверки обычной сборки и не входят в этот UI suite.

Список устройств — push-привязки, не список login-сессий. Смена email/пароля и
SSH deployment этим этапом не реализованы. Уточнение этапа 8: серверный
`DELETE /auth/me` уже существовал в использованном backend; его подключение
в iOS добавлено в [этапе 8](../stage08/ACCOUNT_DELETION.md). Нет автоматически
включаемого SSH при ответе сервера. Состояние ReplayKit/VoIP device blockers этапов
5–6 этим этапом не изменяется.

[Список изменённых файлов](CHANGED_FILES.md) включает исходники, тесты, скрипты и
контракты. [История CI-попыток](evidence/ci-attempts.json) сохраняет обнаруженные
ошибки и причины исправлений. Итоговый [CI run](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42220964006)
прошёл на source commit `4075edf78b92fb991a341ba057fbf2aaac63bc23`.
[Receipt](evidence/ci-run.json) содержит результаты всех jobs и проверенные SHA-256
скачанных ZIP-артефактов; [manifest](evidence/screenshots.json) — 26 PNG без редактирования.
[Визуальный отчёт и галерея](VISUAL_REVIEW.md) описывают условия, адаптации и границы
проверки. После этого source commit добавлены только отчёты/evidence; код и тесты
соответствуют успешному запуску. Финальный коммит документации использует `[skip ci]`.
