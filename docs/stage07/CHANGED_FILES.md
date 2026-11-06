# Этап 07 — изменённые файлы

Инвентарь на 2026-11-06 относительно завершённого этапа 6:
`a9786fbba7b94708a9e7369cc752e3ac18024a52`. Учтены коммиты этапа 7 и текущее
рабочее дерево, включая новые файлы до их добавления в Git. `A` — новый файл
относительно этой базы, `M` — изменённый. Наличие файла теста не означает его PASS:
фактические результаты и границы проверки находятся в [отчёте этапа](README.md).

## Календарь и сохранение выбранного вида

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [Core/Calendar.swift](../../Packages/MeetSpaceKit/Sources/Core/Calendar.swift) | Периоды, timezone, представления календаря и параметры планирования |
| A | [API/CalendarRepository.swift](../../Packages/MeetSpaceKit/Sources/API/CalendarRepository.swift) | Фактические API ленты, создания, переноса и отмены |
| A | [Features/CalendarModel.swift](../../Packages/MeetSpaceKit/Sources/Features/CalendarModel.swift) | Три вида ленты, пагинация, права и lifecycle запросов |
| A | [Features/LiveCalendarView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveCalendarView.swift) | Week/month/list, формы, выбор timezone, адаптация iPhone/iPad |
| A | [Storage/CalendarPreferencesStore.swift](../../Packages/MeetSpaceKit/Sources/Storage/CalendarPreferencesStore.swift) | Сохранение timezone и вида отдельно для сервера и аккаунта |

## Записи и локальное воспроизведение

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [Core/Recording.swift](../../Packages/MeetSpaceKit/Sources/Core/Recording.swift) | Режимы, статусы, карточки и проверка метаданных файлов |
| A | [API/RecordingsRepository.swift](../../Packages/MeetSpaceKit/Sources/API/RecordingsRepository.swift) | Каталог, карточка, start/stop/delete, повторная проверка прав |
| A | [API/RecordingDownloads.swift](../../Packages/MeetSpaceKit/Sources/API/RecordingDownloads.swift) | Отдельный HTTPS download без account credentials, потоковая запись, проверка файла и очистка |
| A | [Features/RecordingsModel.swift](../../Packages/MeetSpaceKit/Sources/Features/RecordingsModel.swift) | Каталог, фильтры, операции и отмена account-scoped transfer |
| A | [Features/LiveRecordingsView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveRecordingsView.swift) | Библиотека, карточка, AVPlayer и системный экспорт локального файла |
| A | [Features/ConferenceRecordingSheet.swift](../../Packages/MeetSpaceKit/Sources/Features/ConferenceRecordingSheet.swift) | Управление записью из активной встречи |
| M | [Features/LiveConferenceView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveConferenceView.swift) | Кнопка и панель записи в звонке |
| M | [Features/ConferencePresentation.swift](../../Packages/MeetSpaceKit/Sources/Features/ConferencePresentation.swift) | Передача account-scoped модели записей в экран звонка |

## Личные папки

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [Core/Folder.swift](../../Packages/MeetSpaceKit/Sources/Core/Folder.swift) | Папки, ссылки на контент, ограничения имён и страниц |
| A | [API/FoldersRepository.swift](../../Packages/MeetSpaceKit/Sources/API/FoldersRepository.swift) | CRUD, полный порядок, содержимое и кандидаты без удаления встреч/чатов |
| A | [Features/FoldersModel.swift](../../Packages/MeetSpaceKit/Sources/Features/FoldersModel.swift) | Сортировка, поиск, страницы, выбранная папка и защита от поздних ответов |
| A | [Features/LiveFoldersView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveFoldersView.swift) | Адаптивная сетка, создание/переименование, ссылки и подтверждение удаления |

## Настройки, зависимости и переходы

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [Core/Settings.swift](../../Packages/MeetSpaceKit/Sources/Core/Settings.swift) | Подтверждённые server capabilities, проверка имени и выключенный SSH flag |
| A | [API/SettingsRepository.swift](../../Packages/MeetSpaceKit/Sources/API/SettingsRepository.swift) | Профиль, notification preferences, push-привязки и capabilities |
| A | [Features/SettingsModel.swift](../../Packages/MeetSpaceKit/Sources/Features/SettingsModel.swift) | Ленивая загрузка, сохранение, актуальный начальный профиль и account lifecycle |
| A | [Features/AccountSettingsView.swift](../../Packages/MeetSpaceKit/Sources/Features/AccountSettingsView.swift) | Разделы профиля, уведомлений, устройств и сервера на iPhone/iPad |
| M | [Features/LiveProfileView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveProfileView.swift) | Актуальное имя и переходы к настройкам, календарю, записям и папкам |
| M | [Features/AppModel.swift](../../Packages/MeetSpaceKit/Sources/Features/AppModel.swift) | DI хранилища календаря и downloader записей |
| M | [Features/IdentityModel.swift](../../Packages/MeetSpaceKit/Sources/Features/IdentityModel.swift) | Создание/закрытие новых моделей, сохранение профиля в индекс аккаунтов |
| M | [Features/DestinationView.swift](../../Packages/MeetSpaceKit/Sources/Features/DestinationView.swift) | Реальные экраны новых функций в существующей навигации |
| M | [Features/LiveMeetingsView.swift](../../Packages/MeetSpaceKit/Sources/Features/LiveMeetingsView.swift) | Доступ к календарю, записям и папкам из встреч |
| M | [Features/WorkspaceView.swift](../../Packages/MeetSpaceKit/Sources/Features/WorkspaceView.swift) | Связь действий встреч с навигацией приложения |
| M | [Localizable.strings](../../Packages/MeetSpaceKit/Sources/DesignSystem/Resources/ru.lproj/Localizable.strings) | Русские строки новых экранов, состояний и ошибок |

Тема, Keychain-сессии, несколько аккаунтов и регистрация текущего push-устройства
используют существующую реализацию. Отдельная SSH-библиотека или установка сервера
в этап не добавлены; статус и план описаны в [аудите SSH](SETTINGS_SSH_CONTRACT.md).

## Тесты, fixtures и Xcode project

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [CoreTests/CalendarTests.swift](../../Packages/MeetSpaceKit/Tests/CoreTests/CalendarTests.swift) | DST, календарные границы и преобразование instant |
| A | [StorageTests/CalendarPreferencesTests.swift](../../Packages/MeetSpaceKit/Tests/StorageTests/CalendarPreferencesTests.swift) | Сохранение и изоляция timezone/view |
| A | [IntegrationTests/CalendarContractTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/CalendarContractTests.swift) | Wire contracts, страницы, права, отмена и неопределённый create |
| A | [IntegrationTests/FoldersTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/FoldersTests.swift) | CRUD/order, сохранность контента, валидация, guest guard и поздние страницы |
| A | [IntegrationTests/RecordingsTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/RecordingsTests.swift) | Права, статусы, download/hash/MIME/redirect, отзыв доступа и отмена |
| A | [IntegrationTests/SettingsTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/SettingsTests.swift) | Контракты профиля/preferences/capabilities и закрытие модели |
| A | [IntegrationTests/Stage07IdentityTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/Stage07IdentityTests.swift) | Свежий профиль после restore/switch и изоляция одинаковых user ID на разных серверах |
| A | [IntegrationTests/FeaturesLoopbackTests.swift](../../Packages/MeetSpaceKit/Tests/IntegrationTests/FeaturesLoopbackTests.swift) | Opt-in Swift-проверка настоящего backend этапа 7 |
| M | [FoundationUITests.swift](../../Tests/MeetSpaceUITests/FoundationUITests.swift) | Сценарии новых функций и screenshot attachments для iPhone/iPad |
| A | [RecordingPlaybackTests.swift](../../Tests/MeetSpaceTests/RecordingPlaybackTests.swift) | Native AVPlayer: playable/audio track/duration и продвижение времени настоящего AAC-артефакта |
| M | [App/UITestDependencies.swift](../../App/UITestDependencies.swift) | Детерминированные DEBUG API fixtures и инъекция downloader |
| A | [App/UITestRecordingFixture.swift](../../App/UITestRecordingFixture.swift) | Валидный H.264 fixture и AAC-файл настоящего worker для native/UI проверки |
| M | [MeetSpace.xcodeproj/project.pbxproj](../../MeetSpace.xcodeproj/project.pbxproj) | Включение новых app fixtures и hosted теста в Xcode targets |

## Воспроизводимые стенды

| Статус | Файл | Назначение |
| --- | --- | --- |
| A | [scripts/run_features_contract.py](../../scripts/run_features_contract.py) | Одноразовый backend, opt-in Swift contract run, evidence и cleanup |
| A | [scripts/run_recording_pipeline.py](../../scripts/run_recording_pipeline.py) | Настоящие API/SFU/recorder/FFmpeg/S3, ready artifact, signed download и права |
| A | [scripts/fixtures/recording_probe.go](../../scripts/fixtures/recording_probe.go) | Pion WebRTC-источник синтетических Opus-пакетов для recording pipeline |

Runner-скрипты используют закреплённый checkout backend и изолированные временные
сервисы. Они не являются изменениями исходников backend или production deployment.

## Документация

| Статус | Файл | Назначение |
| --- | --- | --- |
| M | [README.md репозитория](../../README.md) | Возможности и ссылка на отчёт этапа 7 |
| A | [README.md этапа](README.md) | Реализация, команды, фактические результаты, ограничения и приёмка |
| A | [CHANGED_FILES.md](CHANGED_FILES.md) | Этот полный инвентарь изменений |
| A | [CALENDAR_CONTRACT.md](CALENDAR_CONTRACT.md) | API, timezone/DST, сохранение, дизайн и границы календаря |
| A | [FOLDERS_CONTRACT.md](FOLDERS_CONTRACT.md) | Права, порядок, пагинация и удаление только связей |
| A | [RECORDINGS_CONTRACT.md](RECORDINGS_CONTRACT.md) | Контракты, безопасная доставка файла, AVPlayer и ограничения |
| A | [SETTINGS_SSH_CONTRACT.md](SETTINGS_SSH_CONTRACT.md) | Настройки, Android core:ssh/install.sh, disabled flag и план SSH |
| A | [RUNTIME_CONTRACT.md](RUNTIME_CONTRACT.md) | Настоящий Swift API run и условия воспроизведения |
| A | [RECORDING_PIPELINE.md](RECORDING_PIPELINE.md) | Настоящая готовая запись и доказательства server pipeline |

## Evidence и ожидаемые итоговые CI-материалы

Уже подготовлены следующие группы новых файлов; их результаты объясняются в
соответствующих отчётах, а не выводятся из наличия артефактов:

| Группа | Файлы и назначение |
| --- | --- |
| Локальный Swift suite | [evidence/host-results.txt](evidence/host-results.txt) — сводка фактического host-прогона |
| Настоящий API contract run | [evidence/runtime/](evidence/runtime/) — `results.txt`, `runtime.json`, `source-review.json`, `cleanup.json` |
| Настоящий recording pipeline | [evidence/recording-pipeline/](evidence/recording-pipeline/) — `runtime.json`, `artifact.json`, `access-denials.json`, `ffprobe.json`, `decode.txt`, `recording-probe.log`, `sfu-cleanup.json`, `cleanup.json` |

После завершения CI ожидается отдельное дополнение evidence: receipt с URL, commit,
jobs и их фактическими outcomes; результаты Swift package и Xcode Release; summary
и результаты hosted/UI тестов для iPhone и iPad; manifest screenshot attachments
и выбранные PNG. Снимки покрывают week/month/list, папки и содержимое, профиль,
уведомления/server flags, библиотеку записей, player/server audio и отказ доступа.
Полные `.xcresult` и диагностика остаются CI artifacts; каждый PNG здесь не перечисляется.

На момент составления этого инвентаря CI PASS и окончательная визуальная приёмка
**не утверждаются**. После получения результатов актуальным источником их статуса
служит [README этапа](README.md) с receipt и результатами screenshot review.

Инвентарь сверяется командами:

```sh
git diff --name-status a9786fbba7b94708a9e7369cc752e3ac18024a52
git ls-files --others --exclude-standard
```
