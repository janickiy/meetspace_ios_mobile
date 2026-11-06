# Этап 08: проверка актуального backend

Дата: 2026-11-06. **PASS — 2 реальных API-теста, 0 skipped, 106 HTTP-запросов
тестов** плюс один readiness `GET /version`. Backend собран без изменений из
`9e6058c31cc07bff0f48d8f7f6a40106c55c4881`. Отдельный detached worktree:
`/tmp/meetspace-stage08-backend`. Checkout этапов 3–7 на `0bd1248a…` не менялся.

## Одноразовый стенд

Runner создаёт собственную Docker-сеть и новые PostgreSQL, Redis, RabbitMQ, MinIO
и API. Порты публикуются только на `127.0.0.1`; пароли/JWT secrets генерируются
заново и передаются через environment, не через аргументы команд или receipt.
Миграции и Go binary берутся из pinned worktree. Аккаунты и данные создают сами
тесты через настоящий API; готовые результаты не внедряются в БД.

```sh
git -C /tmp/meetspace-ios-stage03/backend worktree add --detach \
  /tmp/meetspace-stage08-backend 9e6058c31cc07bff0f48d8f7f6a40106c55c4881
python3 scripts/stage08_backend_contract.py \
  --backend /tmp/meetspace-stage08-backend \
  --output /tmp/meetspace-stage08-api-03
```

Для повторения нужен новый пустой output directory, Docker, Go и Swift toolchain.
Минимальный кешированный MinIO image можно изменить через `--minio-image`.
Runner сам собирает API и запускает Swift filter
`actualBackendCalendarFoldersSettingsAndRecordings|stage08ActualBackendAccountDeletion`.
Полная фактическая команда и image IDs находятся в receipt. Test-only transport
принимает только известный loopback host/случайный port и адаптирует HTTPS URL
на HTTP внутри этого стенда; продуктовая HTTPS/TLS policy не ослаблялась.

## Результаты

| Сценарий | Фактический результат |
| --- | --- |
| Календарь | Создание, перенос и отмена; UTC instant в трёх IANA timezone; чужие изменения запрещены; перенос отменённой встречи — 409. |
| Папки | CRUD, порядок, кандидаты/содержимое, добавление/удаление ссылок; четыре cross-account отказа; удаление папки сохраняет встречу, чат, сообщение и папку другого аккаунта. |
| Настройки | Имя и notification preferences сохраняются после нового login; другой аккаунт не меняется; devices/capabilities/providers читаются текущими Swift DTO. |
| Записи | Реальные capabilities, каталог и starting/stopping; повторный start — 409; права чтения/остановки; не создавался фиктивный ready-файл. |
| DELETE с неверным паролем | **422**, `Cache-Control: no-store`; текущая и вторая сессии того же аккаунта продолжают отвечать на `/auth/me`. Один DELETE, без автоматического повтора. |
| DELETE владельца встречи | **409**, пока у аккаунта есть scheduled meeting; сессия остаётся действующей. Встреча отменена через API перед повторной явно запрошенной операцией. |
| Подтверждённое удаление | **200**, JSON `status: success`, `no-store`. Два первоначальных bearer, обе refresh-cookie и новый password login затем получают **401**. |
| Изоляция удаления | Другой аккаунт, его папка и preferences доступны; новый login другого аккаунта проходит; оставшиеся тестовые сессии завершены через logout. |
| Cleanup | 0 созданных контейнеров и 0 созданных сетей после завершения; существующие Docker-сервисы не затронуты. |

Проверка использует настоящий `AuthenticatedClient.deleteAccount(password:)`,
AuthenticationGateway и repositories. Для удаления отправляется ровно
`DELETE /api/v1/auth/me` с JSON `{password}` и bearer текущего аккаунта; user ID
не задаётся вызывающим кодом. Сам endpoint уже присутствовал в baseline `0bd1248a…`.
Источники: `internal/transport/http/platform_routes.go`,
`internal/app/auth/accounts.go`, `internal/usecase/auth/accounts.go`,
`internal/infrastructure/postgres/account_repository.go` и HTTP error mapper.

Первый прогон выявил неверное предположение о password error: фактически сервер
возвращает 422, а новый iOS код ожидал 400 и показывал неопределённый результат.
Исправлен mapping `400/422 → passwordRejected`; окончательный probe требует
именно наблюдаемый 422. После исправления второй и финальный третий прогоны прошли.
Третий добавил проверку неизменности source hashes на протяжении исполнения и
точный счётчик отдельных тестов. История сохранена, начальный FAIL не скрыт.

## Свидетельства и границы

- [runtime.json](evidence/api/runtime.json): pinned source/image IDs, команда,
  30 source hashes, `sourceChangedDuringRun: []`, 2 executed/2 passed/0 failed/0 skipped.
- [results.txt](evidence/api/results.txt): проверенные assertions и результаты Swift.
- [http-statuses.json](evidence/api/http-statuses.json): только агрегаты method/route/status,
  включая DELETE 422/409/200; без credentials, IDs, URL query или response bodies.
- [cleanup.json](evidence/api/cleanup.json) и [attempts.json](evidence/api/attempts.json).

Полные private logs и Go binary остались вне репозитория. После финального прогона
source hashes повторно сверены с рабочими файлами. Это loopback API compatibility,
не проверка публичного HTTPS, камеры, WebRTC/SFU worker, ready media, PushKit/APNs,
native UI или физического устройства. Старый полноценный recording pipeline
этапа 7 не объявляется повторно выполненным на новом backend.

Новая серверная email-verification policy в чистой конфигурации выключена:
регистрация и login прошли без override, SMTP и bypass не включались. Режим с
обязательной verification, password recovery, admin API, guest/live-call/group-owner
конфликты удаления и прикладное поведение при потере ответа DELETE в этот реальный
прогон не входят. Последнее покрывается отдельными детерминированными client tests.
Backend остаётся окончательной проверкой прав и правил удаления; совместимость
всех новых административных возможностей этим отчётом не заявляется.
