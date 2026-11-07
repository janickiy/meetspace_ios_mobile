# Ограничения этапа 08

Дата обновления: 7 ноября 2026. Результат аудита и подготовки не является разрешением
на production или подтверждением App Store review.

| Gate | Статус | Что требуется для закрытия |
| --- | --- | --- |
| Подпись, provisioning, экспорт и TestFlight | BLOCKED | Apple Team, сертификат с private key, profiles обоих targets, зарегистрированные App Group/APNs; настоящий signed archive, export и Organizer validation |
| Native SDK provenance / notices | BLOCKED | Уточнить применимость требований Apple к Abseil/BoringSSL внутри WebRTC; подписанный проверяемый SDK artifact либо воспроизводимая собственная сборка, полный dependency/license graph и validation |
| Физические iPhone/iPad | BLOCKED | Подписанная установка; камера/микрофон, Bluetooth/route changes, lock/background, разрешения, iOS ↔ Android/Web на HTTPS/WSS стенде |
| Instruments | BLOCKED | Allocations, Leaks, Time Profiler, Energy Log на устройстве: 30 звонков, 60 минут конференции, screen share, reconnect и большие transfers. Host RSS/CPU не заменяют эти результаты |
| APNs | BLOCKED device acceptance | Нужны production/development profiles и настроенный внешний push gateway. Сохранение token не доказывает доставку |
| PushKit / cold-start VoIP | BLOCKED contract | В существующем backend нет подтверждённого VoIP token/payload/delivery contract; adapter выключен. UI CallKit и активная сессия не доказывают пробуждение закрытого приложения |
| Push-привязки при конкурентном удалении аккаунта | FIXED IN PATCH; BACKEND INTEGRATION REQUIRED | [Серверная правка](../../server-patches/account-deletion/README.md) сериализует SaveDevice/DELETE;9/9 PostgreSQL сценариев PASS. На непатченном9e6058c дефект остаётся; требуется включить patch в backend и выпустить сервер. Production не изменён |
| Push после ошибки локального хранилища при удалении | FIXED IN iOS; local fault + native regression PASS | [Отдельное подтверждение и replay](P2_FIXES.md) восстанавливают очистку после write/read failure и restart; другие scopes сохранены. Если все записи отказали и процесс завершён до durable proof, остаётся fail-closed;401 не используется как подтверждение |
| ReplayKit | BLOCKED device acceptance | Реальное системное расширение, захват других приложений, interruption/stop/restart и FPS/CPU/RAM на устройстве. System audio не передаётся |
| Серверные видеозаписи | PARTIAL | Настоящий audio-only pipeline проверен на этапе 7. Composite/screen-focus video, реальный микрофон, долгий playback, Files export и physical lock требуют отдельной проверки |
| App Store privacy / metadata | BLOCKED publisher input | Privacy-policy/support URLs, возрастной рейтинг, export classification, права на материалы, review contact/account и итоговые App Privacy answers |
| Скриншоты | EVIDENCE ONLY | Снимки реального приложения с изолированными fixture данными; для карточки Store нужны выбранные владельцем финальные материалы и проверка актуальных display classes |
| Полная visual parity с макетами | BLOCKED | Реальные normal/AX5 снимки проверяются по основным экранам; полная матрица состояний всех 21 дизайн-макетов, все размеры устройств, клавиатура, loading/error/empty состояния и ручное принятие владельцем не закрыты. См. VISUAL_REVIEW.md, ACCESSIBILITY_REVIEW.md и ACCESSIBILITY_IPAD_REVIEW.md |
| Доступность | PARTIAL | Автоматический аудит не заменяет ручной VoiceOver/Switch Control с пользователем и физическим устройством |
| SSH installation | DISABLED | Только план из этапа 7; установки и backend изменений не выполнялось |

При потере ответа на удаление аккаунта клиент показывает неподтверждённый результат
и не повторяет DELETE автоматически. Общая история переписки может оставаться
анонимизированной согласно существующему серверному контракту. Сервер может
отказать из-за активных звонков, открытых встреч или владения группами.

В исходном backend без нового patch удаление push-привязок в транзакции DELETE не гарантирует, что уже авторизованная
операция другого устройства не добавит их снова. Backend `9e6058c` очищает таблицу
и может оставить tombstone ([account_repository.go:67–108](https://github.com/janickiy/meet-space/blob/9e6058c31cc07bff0f48d8f7f6a40106c55c4881/internal/infrastructure/postgres/account_repository.go#L67-L108));
`SaveDevice` не проверяет состояние владельца под общей блокировкой
([integration_repository.go:110–123](https://github.com/janickiy/meet-space/blob/9e6058c31cc07bff0f48d8f7f6a40106c55c4881/internal/infrastructure/postgres/integration_repository.go#L110-L123)).
Локальное ожидание очереди проверено host regression и не заявляется глобальной гарантией:
потерянный ответ также не доказывает завершение запроса на сервере. Подтверждённое
ограничение относится к сохранению device metadata; доставка после удаления или
обход авторизации не воспроизводились. Обоснование P2 и граница review —
[SECURITY_AUDIT.md](SECURITY_AUDIT.md#p2-регистрация-push-одновременно-с-удалением-аккаунта).

В пределах выполненного source review и регрессионных проверок открытых P0/P1
не выявлено. Непроверенные внешние gates не считаются PASS и не являются
доказательством отсутствия дефектов вне проверенного объёма.
