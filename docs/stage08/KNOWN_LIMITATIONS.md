# Ограничения этапа 08

Дата проверки: 2026-11-06. Результат аудита и подготовки не является разрешением
на production или подтверждением App Store review.

| Gate | Статус | Что требуется для закрытия |
| --- | --- | --- |
| Подпись, provisioning, экспорт и TestFlight | BLOCKED | Apple Team, сертификат с private key, profiles обоих targets, зарегистрированные App Group/APNs; настоящий signed archive, export и Organizer validation |
| Native SDK provenance / notices | BLOCKED | Уточнить применимость требований Apple к Abseil/BoringSSL внутри WebRTC; подписанный проверяемый SDK artifact либо воспроизводимая собственная сборка, полный dependency/license graph и validation |
| Физические iPhone/iPad | BLOCKED | Подписанная установка; камера/микрофон, Bluetooth/route changes, lock/background, разрешения, iOS ↔ Android/Web на HTTPS/WSS стенде |
| Instruments | BLOCKED | Allocations, Leaks, Time Profiler, Energy Log на устройстве: 30 звонков, 60 минут конференции, screen share, reconnect и большие transfers. Host RSS/CPU не заменяют эти результаты |
| APNs | BLOCKED device acceptance | Нужны production/development profiles и настроенный внешний push gateway. Сохранение token не доказывает доставку |
| PushKit / cold-start VoIP | BLOCKED contract | В существующем backend нет подтверждённого VoIP token/payload/delivery contract; adapter выключен. UI CallKit и активная сессия не доказывают пробуждение закрытого приложения |
| ReplayKit | BLOCKED device acceptance | Реальное системное расширение, захват других приложений, interruption/stop/restart и FPS/CPU/RAM на устройстве. System audio не передаётся |
| Серверные видеозаписи | PARTIAL | Настоящий audio-only pipeline проверен на этапе 7. Composite/screen-focus video, реальный микрофон, долгий playback, Files export и physical lock требуют отдельной проверки |
| App Store privacy / metadata | BLOCKED publisher input | Privacy-policy/support URLs, возрастной рейтинг, export classification, права на материалы, review contact/account и итоговые App Privacy answers |
| Скриншоты | EVIDENCE ONLY | Снимки реального приложения с изолированными fixture данными; для карточки Store нужны выбранные владельцем финальные материалы и проверка актуальных display classes |
| Visual parity с макетами | PARTIAL | Реальные normal/AX5 снимки проверяются по основным экранам; полная матрица состояний всех 21 дизайн-макетов, все размеры устройств, клавиатура, loading/error/empty состояния и ручное принятие владельцем не закрыты. См. ACCESSIBILITY_REVIEW.md и ACCESSIBILITY_IPAD_REVIEW.md |
| Доступность | PARTIAL | Автоматический аудит не заменяет ручной VoiceOver/Switch Control с пользователем и физическим устройством |
| SSH installation | DISABLED | Только план из этапа 7; установки и backend изменений не выполнялось |

При потере ответа на удаление аккаунта клиент показывает неподтверждённый результат
и не повторяет DELETE автоматически. Общая история переписки может оставаться
анонимизированной согласно существующему серверному контракту. Сервер может
отказать из-за активных звонков, открытых встреч или владения группами.

В пределах выполненного source review и регрессионных проверок открытых P0/P1
не выявлено. Непроверенные внешние gates не считаются PASS и не являются
доказательством отсутствия дефектов вне проверенного объёма.
