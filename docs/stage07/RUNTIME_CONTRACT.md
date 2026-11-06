# Реальная проверка API этапа 7

Дата: 2026-11-06. **PASS**: `actualBackendCalendarFoldersSettingsAndRecordings`,
1 opt-in Swift integration test, 0 failures, 0 skipped, 80 фактических HTTP-запросов
к одноразовому неизменённому backend. Финальный прогон занял 0.645 с внутри теста
(без учёта запуска контейнеров и сборки).

```sh
python3 scripts/run_features_contract.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage07-features-02
```

Runner проверяет pinned backend commit
`0bd1248a2411842515af4e02f1e95821616748fb`, запускает отдельные PostgreSQL, Redis,
MinIO, RabbitMQ и API с новыми credentials/тестовыми аккаунтами и случайными портами,
доступными только через loopback. Production backend/данные не затрагиваются.
Неподписанный HTTP используется исключительно opt-in транспортом теста;
приложение продолжает требовать HTTPS/TLS. Редиректы тестовый адаптер запрещает.

| Группа | Фактический результат |
| --- | --- |
| Календарь | Создание, перенос и отмена; точный UTC instant в запросах месяцев Europe/Moscow, America/New_York, Asia/Kathmandu; чужой перенос запрещён; перенос отменённой встречи возвращает 409; past timeline использует фактический finishedAt |
| Папки | Создание/переименование/порядок/кандидаты/ссылки; 4 запрета доступа другого аккаунта; удаление ссылки и папки сохраняет встречу, чат, сообщение и папки другого пользователя |
| Настройки | Имя профиля и notification preferences сохраняются после нового login; другой аккаунт сохраняет свои значения; настоящий список устройств и capabilities; push provider `noop` |
| Записи | Настоящий пустой/заполненный каталог; `starting` и `stopping`; видимость для допущенного участника; отсутствие доступа постороннего; остановка только владельцем/инициатором; повторный старт 409 |
| Завершение | Logout подтверждён для всех четырёх сессий; после runner осталось 0 созданных контейнеров и 0 сетей |

Исходные выдержки: [results.txt](evidence/runtime/results.txt).
[runtime.json](evidence/runtime/runtime.json) содержит backend commit, Docker image IDs,
точную Swift-команду и SHA-256 runner, API/Core и integration test. Проверялся рабочий
снимок до итогового iOS commit; `iosWorkingTreeDirty` явно это фиксирует.
После прогона отдельно изменён `RecordingDownloads.swift`, который этот тест не
вызывает. Его прежний hash сохранён как часть исходного снимка; остальные записанные
hashes совпали при сверке. Различие и граница покрытия зафиксированы в
[source-review.json](evidence/runtime/source-review.json).
[cleanup.json](evidence/runtime/cleanup.json) подтверждает удаление созданных ресурсов.
Секретные логи API/credentials не добавлены в репозиторий.

Recorder/FFmpeg worker не запускался: **не проверены** создание готового медиафайла,
реальный `ready/partial_ready`, signed download готового серверного артефакта,
AVPlayer и физические устройства. Тест не подменяет эти сценарии синтетическим
`ready`-ответом или прямой записью в БД. Отдельные unit/UI проверки скачивания и
плеера описываются в основном отчёте с их собственными ограничениями.
