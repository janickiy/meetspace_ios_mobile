# Личные папки — контракт и реализация

Проверено 2026-11-06: backend main `0bd1248a2411842515af4e02f1e95821616748fb`,
Android main `b8f289983e60671d415a128734c2e5bb6e93a29d`,
макеты main `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`.
Remote refs совпали с исходниками на диске. Дополнительная backend-ветка
`codex/admin-console` не является основой мобильного контракта.

Источники backend: `internal/transport/http/folder_routes.go`,
`internal/app/folders/handler.go`, `internal/domain/folders/folders.go`,
`internal/infrastructure/postgres/folder_repository.go`, migration
`000032_personal_folders.up.sql`. Android: `core/data/src/main/kotlin/com/meetspace/core/data/MessagingApi.kt`.
Макеты: `meetspace-refresh-20261016/folders-refresh.js` и `folders-refresh.css`.

| Действие | Подтверждённый REST |
| --- | --- |
| Список / создание | GET / POST `/folders`, создание `{name}` |
| Переименование / удаление | PATCH / DELETE `/folders/:id` |
| Полный порядок | PUT `/folders/order`, `{ids}` всех текущих папок |
| Содержимое | GET `/folders/:id/items` |
| Доступные кандидаты | GET `/folder-items?folderId=…` |
| Добавить / убрать ссылку | PUT / DELETE `/folders/:id/items/:kind/:itemId` |

Kinds только `conversation` и `conference`. Страница содержит `items` и непрозрачный
`nextCursor`, запрос следующей страницы передаёт `before`. Фильтры `type` и `search`;
лимит iOS — 50. Имена NFC, trim, 1–50 Unicode scalars; control/format запрещены,
кроме ZWNJ/ZWJ. Уникальность имени после Unicode case-fold проверяет сервер.
Папок максимум 100; устаревший полный порядок отклоняется сервером с 409.

Папки принадлежат зарегистрированному аккаунту; гостевой запрос отклоняется и
клиентом, и backend AccountOnly. Папка не предоставляет доступ к ресурсу.
Содержимое проверяется backend по текущему membership; direct-call комнаты не
становятся обычными встречами. Клиент не использует папку для обхода admission.

Удаление вызывает только `DELETE /folders/:id`: backend удаляет строку папки и
связи, затем уплотняет позиции. Удаления conversation/conference в этом модуле нет.
При удалении ссылки удаляется только связь. Диалог UI сообщает, что встречи и чаты
останутся. Есть создание, переименование, изменение порядка вверх/вниз/по алфавиту,
фильтры/поиск, добавление и удаление ссылок, переход в чат или открытую встречу.

Сетка и карточки используют существующую палитру, Inter, скругления, иконку папки и
счётчики макета; iPhone показывает одну колонку, iPad — адаптивную сетку. Нативные
menu, sheet, confirmation и доступные действия сортировки — iOS-адаптация.
Закрытая встреча в папке остаётся информационной карточкой.

Model привязана к аккаунту; `close()` отзывает поколения запросов и очищает состояние.
Повторные/старые страницы, дубли ID и некорректные счётчики не попадают в ForEach.
Списки обновляются при открытии, вручную и после изменений. Серверные `folder.*`
realtime события пока не подписываются этим экраном: изменения с другого устройства
становятся видны при обновлении. Полные результаты runtime/UI находятся в README этапа.
