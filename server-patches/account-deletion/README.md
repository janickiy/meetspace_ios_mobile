# Исправление регистрации push после удаления аккаунта

Подготовлено 7 ноября 2026 года для `janickiy/meet-space` на commit
`9e6058c31cc07bff0f48d8f7f6a40106c55c4881`. Серверный код находится в отдельном
репозитории, поэтому правка поставляется здесь как [применяемый patch](backend-device-account-serialization.patch)
с тестами. Backend production и его удалённые Git-ветки этой работой не изменены.
Для устранения гонки на действующем сервере требуется включить patch в backend
и выпустить обновлённый сервер; обновления только iOS недостаточно.

`SaveDevice` теперь внутри своей транзакции берёт `users FOR UPDATE` до блокировки
квоты и UPSERT. Он повторно проверяет состояние пользователя после ожидания.
При регистрации первой последующий `DeleteAccount` удалит созданную запись;
при удалении первым поздняя регистрация получает существующий HTTP401.
Удалённый пользователь не получает новый `push_devices` token. Заблокированный
пользователь и гость получают HTTP403 через существующий mapper. Изменений
схемы, нового endpoint или нового формата ошибки нет.

Порядок блокировок согласован с `DeleteAccount`: user → devices. Это соответствует
[правилам PostgreSQL для row locks](https://www.postgresql.org/docs/17/explicit-locking.html#LOCKING-ROWS)
и [повторной проверке строки после ожидания в Read Committed](https://www.postgresql.org/docs/17/transaction-iso.html#XACT-READ-COMMITTED).
Проверки выполнены на PostgreSQL17 с фактическим Read Committed; уже начатая
доставка push через внешний gateway не входит в эту правку.

Из корня iOS-репозитория проверка не изменяет переданный backend checkout:

```sh
python3 scripts/verify_backend_deletion_patch.py \
  --backend /absolute/path/to/meet-space \
  --output /absolute/path/to/empty-p2-results
```

Нужны Git, Go, Docker и pinned commit в локальном backend-репозитории.
Скрипт извлекает отдельную временную копию commit, проверяет и применяет patch,
запускает собственный PostgreSQL с временным хранилищем и случайным loopback-портом,
исполняет реальные тесты с `-race` и удаляет только свой контейнер.
Существующие БД, `.env`, рабочие изменения backend и production не используются.
Успех требует 9/9 сценариев без SKIP и четырёх наблюдённых зависимостей
`pg_blocking_pids`; ожидание по таймеру не считается доказательством гонки.

Для интеграции используйте отдельную ветку backend от указанного commit:

```sh
git switch -c codex/device-delete-serialization 9e6058c31cc07bff0f48d8f7f6a40106c55c4881
git apply --check /absolute/path/to/meetspace_ios_mobile/server-patches/account-deletion/backend-device-account-serialization.patch
git apply /absolute/path/to/meetspace_ios_mobile/server-patches/account-deletion/backend-device-account-serialization.patch
```

На другой ревизии сначала перенесите и проверьте правку; успешное применение
к pinned source не доказывает совместимость с будущими изменениями backend.

[Receipt](receipt.json) сохраняет точные source/patch hashes, команды, окружение
и границы. [Baseline](baseline.log): 8 FAIL /1 PASS в девяти сценариях;
[исправление](fixed.log): 9/9 PASS; [смежные проверки с race detector](related-race.log):
15 верхнеуровневых тестов и27 вложенных сценариев PASS,0SKIP. Вложенные сценарии
входят в родительские тесты и не суммируются с ними как независимое покрытие.
