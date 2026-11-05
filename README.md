# MeetSpace для iOS / iPadOS

Целевая платформа — iPhone и iPad, iOS/iPadOS 18+, Swift и SwiftUI.
Репозиторий содержит аудит, основу iOS-проекта и **этап 03: авторизацию, личные/групповые чаты и файлы**.
Backend используется существующий; его исходники, конфигурация и данные не изменялись.

Откройте `MeetSpace.xcodeproj` в Xcode, выберите `MeetSpace-Debug` и симулятор iPhone/iPad.
На первом экране можно проверить HTTPS-адрес сервера или открыть явный демо-просмотр.
Подключены реальный вход, регистрация, до 5 аккаунтов на сервере, чаты и вложения.
Звонки, push и SSH относятся к следующим этапам.

- [Результат этапа 03, команды, проверки и ограничения](docs/ios/AUTH_CHATS_FILES_REPORT.md)

- [Результат этапа 02, тесты и ограничения](docs/ios/FOUNDATION_REPORT.md)
- [Архитектура, DI, TLS и хранение](docs/ios/FOUNDATION_ARCHITECTURE.md)
- [Матрица SwiftUI → макеты и недостающие состояния](docs/ios/FOUNDATION_UI_MATRIX.md)

Проверки разделены на unit-тесты, контракт с двумя клиентами настоящего backend
и нативные UI/Keychain-тесты iPhone/iPad в GitHub Actions. Точные коммиты,
результаты и границы проверки указаны в отчётах соответствующих этапов.
Локально установлен только Command Line Tools; запуск iOS здесь требует полного Xcode.

Аудит выполнен 5 ноября 2026 года по зафиксированным коммитам backend, Android и макетов.
`mobile_maket` уже содержит материалы: 21 экран интерактивного прототипа, светлую и тёмную темы, телефон и планшет.

- [Результат этапа, команды, проверки и ограничения](docs/ios/AUDIT_REPORT.md)
- [Контракты HTTP API и права](docs/ios/API_CONTRACTS.md)
- [WebSocket, SFU, звонки и восстановление](docs/ios/REALTIME_PROTOCOL.md)
- [Матрица макет → экран → состояния](docs/ios/SCREEN_MATRIX.md)
- [Соответствие функций backend / Android / iOS](docs/ios/FEATURE_PARITY.md)
- [Риски и условия снятия блокировок](docs/ios/RISK_REGISTER.md)

Наличие функции в макете или Android не означает наличия актуального серверного контракта.
Расшифровки и ИИ-функции отсутствуют в текущем backend. APNs/VoIP, нативная демонстрация экрана
и отдельные состояния iOS требуют дополнительных материалов или проверок.

Проверка целостности материалов без сетевых запросов:

```sh
python3 scripts/verify_audit.py
```

Проверка привязки документов к исходникам дополнительно принимает каталог с checkout
`backend`, `android`, `design` на коммитах из
[манифеста](docs/ios/evidence/source-manifest.json):

```sh
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
```

Готовность приложения к production и точная visual parity всех экранов не заявляются.
