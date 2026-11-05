# Этап 02: результат и проверки

Дата: 2026-11-05. Созданы iOS/iPadOS-проект, модульная архитектура и основа SwiftUI UI.
Этап 03 не выполнялся. Основание — требования `02_FOUNDATION_UI.md` и контракты аудита.

## Критерии

| Критерий | Статус | Доказательство / граница |
| --- | --- | --- |
| Xcode project, iOS 18+, iPhone/iPad, Debug/Release | PASS | Воспроизводимый pbxproj, общие схемы; Debug build/test на обеих families, Release generic iOS Simulator build в CI |
| App/Core/API/Realtime/Storage/DesignSystem/Features, DI | PASS | App + 6 targets локального package; Swift 6 concurrency; тестовые зависимости |
| Shared SwiftUI-код компилируется на хосте | PASS | `swift build` с MacOSX26.4 SDK; это не iOS build |
| HTTPS origin без TLS bypass | PASS (код/unit) | Запрет userinfo/path/query/HTTP; системная TLS-проверка; redirects запрещены; нет ATS overrides |
| Keychain abstraction / безопасная конфигурация | PASS (код/integration) | Actor, scoped keys, device-only, no sync; read/update/delete и изоляция серверов проверены в iOS |
| Navigation, loading/empty/error/offline | PASS (проверенные сценарии) | 3 независимых paths, cancellation/stale-response tests; вкладки, выход из демо, состояния и retry проверены UI-тестами |
| Unit tests на хосте | PASS | 20 тестов; параметризованные URL/HTTP наборы внутри тестов, лог приложен |
| iPhone/iPad simulator build и UI/Keychain integration tests | PASS в CI | iPhone SE (3rd generation), iPad mini (A17 Pro), iOS 18.5; по 1 hosted Keychain + 6 UI tests, 0 failures |
| CI | PASS | Xcode 16.4; package tests, Release build, обе simulator jobs; коммит и журналы зафиксированы ниже |
| Light/dark, адаптация, Inter | PASS (основа) | Семантические цвета, responsive layout, TTF+OFL; host renders и нативные скриншоты обеих families |
| Dynamic Type | PASS (проверенный сценарий) | Максимальный accessibility-размер, переход в оформление и выбор темы; остальные экраны требуют расширенной приёмки |
| VoiceOver и полная visual parity iOS | Не закрыто | Labels и адаптация есть; ручной VoiceOver не выполнен. Известные UI-отличия перечислены в матрице; точное равенство всех состояний не заявляется |
| RU/EN | RU PASS; EN BLOCKED | Строки выделены; утверждённого EN copy в исходниках нет |
| Backend/media/SSH/push готовность | Не входит в реализацию этого этапа | Нет fake login, отправки сообщений, установки, записи или звонка |

Критических известных runtime FAIL после исправлений нет. Симуляторные проверки
основы прошли; полное закрытие визуальной приёмки не заявляется.

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
  `evidence/stage02/` с логами, provenance, host renders и native screenshots; README и .gitignore обновлены.

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

## Фактическая проверка iOS в CI

[GitHub Actions №42015416090](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42015416090)
завершён успешно 2026-11-05. Проверенный исходный коммит:
`1415f83abea14c4ad1b17b39a8bebe661087579f`. После него в итоговом коммите отчёта
изменены только README, документация и доказательства проверки.

| Задача | Среда и результат |
| --- | --- |
| package | macOS runner; 20 unit tests PASS; Release iOS Simulator build PASS |
| simulators (iPhone) | iPhone SE (3rd generation), iOS 18.5; Debug build + 1 Keychain test + 6 UI tests PASS |
| simulators (iPad) | iPad mini (A17 Pro), iOS 18.5; Debug build + 1 Keychain test + 6 UI tests PASS |

Использован Xcode 16.4. Фактические команды — `swift test`, `xcodebuild` и
`scripts/ci_simulators.py`, приведённые ниже. Simulator tests выполняются с ad-hoc
подписью, Release build — с `CODE_SIGNING_ALLOWED=NO`.
Предупреждение AppIntents metadata extraction ожидаемо: AppIntents не подключён.

Сохранены [манифест CI и SHA-256 скриншотов](evidence/stage02/ci-verification.json),
выдержки исходных журналов [package](evidence/stage02/ci-package.txt),
[iPhone](evidence/stage02/ci-iphone.txt), [iPad](evidence/stage02/ci-ipad.txt)
и [10 нативных скриншотов](evidence/stage02/native-previews/).
Журналы подтверждают результаты тестов; скриншоты просмотрены отдельно.
Xcode result bundles доступны в артефактах workflow с retention 7 дней.

UI-тесты проверяют первый запуск без авторизации, явный вход/выход из демо и три вкладки,
отказ HTTP URL, успешный probe через double с недоступным auth submit,
loading/empty/error/offline и retry, максимальный Dynamic Type и выбор тёмной темы.
Они не доказывают работоспособность реального auth, WebSocket, медиасервера или SSH.

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
запущены в GitHub Actions, локально полный Xcode отсутствует. CI не заменяет физические устройства для
камеры, звонков, push, lock screen, фонового lifecycle и реального TLS-сервера.

## Ограничения перед следующими этапами

1. Дополнить основные simulator checks ручной проверкой VoiceOver, landscape и Split View.
2. Закрыть UI-отличия и недостающие состояния из [матрицы](FOUNDATION_UI_MATRIX.md);
   получить нативные offline/permission/error макеты и английские тексты.
3. Подключать auth и реальные repositories через DI; демо fixtures не использовать как данные аккаунта.
4. Выбрать signing team/bundle ID для устройства; production app icon и App Store metadata
   ещё не подготовлены. Приложение не заявляется готовым к публикации в App Store.
