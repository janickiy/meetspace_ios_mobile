# Этап 02: результат и проверки

Дата: 2026-11-05. Созданы iOS/iPadOS-проект, модульная архитектура и основа SwiftUI UI.
Этап 03 не выполнялся. Основание — требования `02_FOUNDATION_UI.md` и контракты аудита.

## Критерии

| Критерий | Статус | Доказательство / граница |
| --- | --- | --- |
| Xcode project, iOS 18+, iPhone/iPad, Debug/Release | PASS (структура) | pbxproj, общие схемы, deployment target, family 1/2; plist parser и воспроизводимость прошли |
| App/Core/API/Realtime/Storage/DesignSystem/Features, DI | PASS | App + 6 targets локального package; Swift 6 concurrency; тестовые зависимости |
| Shared SwiftUI-код компилируется на хосте | PASS | `swift build` с MacOSX26.4 SDK; это не iOS build |
| HTTPS origin без TLS bypass | PASS (код/unit) | Запрет userinfo/path/query/HTTP; системная TLS-проверка; redirects запрещены; нет ATS overrides |
| Keychain abstraction / безопасная конфигурация | PASS (реализация) | Actor, scoped keys, device-only, no sync; UserDefaults только origin/theme |
| Navigation, loading/empty/error/offline | PASS (модель/код) | 3 независимых paths, cancellation/stale-response tests, state previews |
| Unit tests на хосте | PASS | 20 тестов; параметризованные URL/HTTP наборы внутри тестов, лог приложен |
| iPhone/iPad simulator build и UI/Keychain integration tests | BLOCKED локально | Полного Xcode и iOS simulator SDK нет; xcode-select указывает CLT |
| CI | Настроен | Workflow отдельно проверяет host tests, Release build, iPhone и iPad; удалённый результат фиксируется после push |
| Light/dark, адаптация, Inter | PASS (основа) | Семантические цвета, responsive layout, реальные TTF+OFL, macOS host renders |
| VoiceOver/Dynamic Type/точная visual parity iOS | BLOCKED для приёмки | Код адаптации и labels есть; требуется проверка iOS и закрытие отличий из матрицы |
| RU/EN | RU PASS; EN BLOCKED | Строки выделены; утверждённого EN copy в исходниках нет |
| Backend/media/SSH/push готовность | Не входит в реализацию этого этапа | Нет fake login, отправки сообщений, установки, записи или звонка |

Критических известных FAIL после локальных исправлений нет. Полное закрытие
визуальной приёмки и симуляторной проверки не заявляется.

## Файлы

- `MeetSpace.xcodeproj/`: pbxproj, workspace, схемы Debug/Release.
- `App/`: entry point, DEBUG-only test doubles, Info.plist, PrivacyInfo.xcprivacy.
- `Packages/MeetSpaceKit/Package.swift`: модульный package без внешних зависимостей.
- `Sources/Core/`: ServerOrigin, конфигурация, storage contracts, load/navigation types.
- `Sources/API/ServerProbe.swift`: проверка `/version`, URLSession transport, response/error models.
- `Sources/Realtime/RealtimeEndpoint.swift`: WSS URL builder и connection state contract.
- `Sources/Storage/`: KeychainStore и PreferencesStore.
- `Sources/DesignSystem/`: тема, адаптивные шрифты/компоненты, BrandMark, TTF, OFL, ru strings.
- `Sources/Features/`: AppModel, root/onboarding, workspace, meetings, messages/thread,
  profile/settings, destinations/calendar/forms/catalog, library, call preview, host preview scene.
- `Packages/MeetSpaceKit/Tests/`: CoreTests, APITests, StorageTests, FeaturesTests.
- `Packages/MeetSpaceKit/Tools/PreviewRenderer/`: macOS renderer для проверки компонентов.
- `Tests/MeetSpaceTests/`: Keychain integration test для iOS host.
- `Tests/MeetSpaceUITests/`: onboarding, URL rejection/success, demo/navigation, states, large text/theme.
- `.github/workflows/ios.yml`, `scripts/ci_simulators.py`: CI и выбор доступных iOS 18+ симуляторов обеих families.
- `scripts/generate_xcode_project.py`, `scripts/verify_foundation.py`: воспроизводимый проект и static integrity.
- Этот отчёт, [архитектура](FOUNDATION_ARCHITECTURE.md), [UI-матрица](FOUNDATION_UI_MATRIX.md),
  `evidence/stage02/` с логами, provenance и host renders; README и .gitignore обновлены.

`Sources/*` в списке относятся к `Packages/MeetSpaceKit/Sources/`.

## Фактические локальные команды

```sh
python3 scripts/generate_xcode_project.py
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_foundation.py
python3 scripts/verify_audit.py --source-root /tmp/meetspace-ios-audit-20261105
plutil -lint MeetSpace.xcodeproj/project.pbxproj App/Info.plist App/PrivacyInfo.xcprivacy \
  Packages/MeetSpaceKit/Sources/DesignSystem/Resources/ru.lproj/Localizable.strings
git diff --check
```

Все перечисленные проверки PASS. Аудит: 120 source hashes, 124 design files,
156 route/group declarations, 7 документов, 23 feature rows, 21 screen rows.

На этом компьютере Swift 6.4, SDK по умолчанию MacOSX27.0, только Command Line Tools.
Обычная сборка упёрлась в отсутствующий SwiftUIMacros plugin нового SDK; SDK15.4
несовместим с текущим Testing.framework (`SendableMetatype`). Доступный стабильный
SDK26.4 собрал все модули. Плагин Swift Testing пришлось указать явно из установленного CLT:

```sh
swift build --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk
swift build --package-path Packages/MeetSpaceKit --configuration release \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift run --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  FoundationPreviewRenderer /tmp/meetspace-stage02-previews
```

Результат: Debug/Release host build PASS, 20 unit tests PASS, 6 host render PNG созданы и просмотрены.
CLT выдаёт linker warnings о несуществующих Developer/Library/Frameworks путях;
это не замалчивается и не относится к iOS simulator verification.
Логи: [unit tests](evidence/stage02/unit-tests.txt), [host build](evidence/stage02/host-build.txt),
[Release host build](evidence/stage02/host-release-build.txt),
[environment/static checks](evidence/stage02/verification.txt).

## Запуск с полным Xcode

Открыть `MeetSpace.xcodeproj`, выбрать схему MeetSpace-Debug и iPhone/iPad simulator.
На welcome доступна проверка собственного сервера и «Посмотреть интерфейс».
В демо: Профиль → Каталог экранов / Состояния интерфейса / Оформление.

```sh
swift test --package-path Packages/MeetSpaceKit
python3 scripts/ci_simulators.py --family iPhone
python3 scripts/ci_simulators.py --family iPad
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

UI tests используют отдельные DEBUG doubles, а не настоящий сервер. Keychain test
использует уникальный test service и удаляет только собственные данные. Эти тесты
добавлены, но локально не запускались. CI не заменяет физические устройства для
камеры, звонков, push, lock screen, фонового lifecycle и реального TLS-сервера.

## Ограничения перед следующими этапами

1. Выполнить simulator checks в полном Xcode/CI и исправить возможные iOS-only ошибки.
2. Закрыть UI-отличия и недостающие состояния из [матрицы](FOUNDATION_UI_MATRIX.md);
   получить нативные offline/permission/error макеты и английские тексты.
3. Подключать auth и реальные repositories через DI; демо fixtures не использовать как данные аккаунта.
4. Выбрать signing team/bundle ID для устройства; production app icon и App Store metadata
   ещё не подготовлены. Приложение не заявляется готовым к публикации в App Store.
