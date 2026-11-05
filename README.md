# MeetSpace для iOS / iPadOS

Целевая платформа — iPhone и iPad, iOS/iPadOS 18+, Swift и SwiftUI.
Репозиторий содержит аудит и **этап 02: iOS-проект, архитектуру и основу SwiftUI-интерфейса**.
Backend используется существующий; его исходники, конфигурация и данные не изменялись.

Откройте `MeetSpace.xcodeproj` в Xcode, выберите `MeetSpace-Debug` и симулятор iPhone/iPad.
На первом экране можно проверить HTTPS-адрес сервера или открыть явный демо-просмотр.
Реальный вход, чаты, звонки и SSH пока не подключены.

- [Результат этапа 02, тесты и ограничения](docs/ios/FOUNDATION_REPORT.md)
- [Архитектура, DI, TLS и хранение](docs/ios/FOUNDATION_ARCHITECTURE.md)
- [Матрица SwiftUI → макеты и недостающие состояния](docs/ios/FOUNDATION_UI_MATRIX.md)

В GitHub Actions проверены 20 unit-тестов, Release-сборка iOS Simulator и по 7 тестов
на iPhone SE и iPad mini: Keychain и основные UI-сценарии. Нативные скриншоты и точный
проверенный коммит указаны в [отчёте](docs/ios/FOUNDATION_REPORT.md).
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

Этап 03 не выполнялся. Готовность приложения к production и точная visual parity всех экранов не заявляются.
