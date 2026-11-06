# Этап 08 — безопасность, проверки и подготовка релиза

Аудит от 2026-11-06 продолжает этап 7 в существующем репозитории. Backend и
production данные не менялись. Подготовка выполняется для iOS/iPadOS 18+;
распространение через TestFlight/App Store остаётся BLOCKED внешними gates.

Исправлены ограничение ответа upload, контрастность текста и privacy disclosure
APNs device token. Добавлены серверное удаление аккаунта с паролем/подтверждением,
App Icon из существующего BrandMark, проверки Keychain, 30-кратных lifecycle
циклов, реального API и доступности. CI использует Xcode 26.3, собирает unsigned
device Release archive и проверяет его фактическое содержимое; это не подписанный IPA.

- [Аудит безопасности](SECURITY_AUDIT.md)
- [Производительность: реальные host-измерения и device BLOCKED](PERFORMANCE_REPORT.md)
- [Команды, результаты и границы тестирования](TEST_REPORT.md)
- [История CI и расследования неуспешных прогонов](CI_HISTORY.md)
- [Подпись, provisioning и выпуск](RELEASE.md)
- [Privacy disclosures](PRIVACY_DISCLOSURE.md)
- [Известные ограничения](KNOWN_LIMITATIONS.md)
- [Актуальный backend и удаление аккаунта](API_CONTRACT.md)
- [Матрица 21 макета и границы визуальной приёмки](VISUAL_REVIEW.md)
- [Правила accessibility audit и независимые проверки](ACCESSIBILITY_POLICY.md)
- [Список изменённых файлов](CHANGED_FILES.md)

## Исправление вывода предыдущего аудита

`DELETE /api/v1/auth/me` существовал уже на backend `0bd1248`, использованном
на этапе 7. Прежние утверждения об отсутствии account-deletion API ошибочны.
Этап 8 подключает существующий endpoint; новый backend API не создавался.
Актуальный backend pin — `9e6058c31cc07bff0f48d8f7f6a40106c55c4881`.
Android `b8f289983e60671d415a128734c2e5bb6e93a29d` и макеты
`04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3` не изменились. Макеты доступны:
историческая оговорка задания об их пустом репозитории больше не применима.

Полный CI15 завершился97 PASS /3 FAIL из100; failures связаны с helper ввода
удаления. Native Core/font проверки всех4 платформ прошли. Исправленный helper
проверяется отдельным CI18; до результата его нельзя считать PASS. Текущие
scopes/source commits находятся в [TEST_REPORT.md](TEST_REPORT.md).
