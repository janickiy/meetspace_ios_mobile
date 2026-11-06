# Тестирование этапа 08

Дата: 2026-11-06. Финальные CI результаты ожидаются; эта промежуточная версия
не утверждает прохождение ещё не выполненных сборок.

## Воспроизведение

```sh
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_audit.py
python3 scripts/verify_foundation.py
python3 scripts/verify_contrast.py --report artifacts/contrast-verification.json
python3 scripts/verify_release.py --report artifacts/source-release-verification.json
git diff --check
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

GitHub Actions выбирает Xcode 26.3 явно. Release gate проверяет фактические
DTXcode/DTSDKName, device platform, resources, privacy manifests, embedded extension,
версии и App Icon. `CODE_SIGNING_ALLOWED=NO` намеренно отделён от distribution signing.

```sh
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath artifacts/MeetSpace-Unsigned.xcarchive CODE_SIGNING_ALLOWED=NO archive
python3 scripts/verify_release.py --archive artifacts/MeetSpace-Unsigned.xcarchive \
  --report artifacts/release-verification.json
python3 scripts/ci_simulators.py --family iPhone --runtime-major 26 --label iPhone26
python3 scripts/ci_simulators.py --family iPad --runtime-major 26 --label iPad26
python3 scripts/ci_simulators.py --family iPhone --runtime-major 18 --label iPhone18 --scope compatibility
python3 scripts/ci_simulators.py --family iPad --runtime-major 18 --label iPad18 --scope compatibility
```

Compatibility scope запускает все hosted tests, audit доступности семи экранов,
удаление аккаунта и large-text/appearance. Full scope включает все UI сценарии
предыдущих этапов. Runtime/family не заменяются при отсутствии: runner завершится
с BLOCKED/failure, сохранив доступный inventory.

Автоматический аудит собирает все issues в JSON attachment и затем проваливает
тест, если список не пуст. Не используется blanket suppression. Скриншоты сняты
XCUITest из работающего приложения, не сгенерированы из дизайна. Сценарии используют
DEBUG fixture dependencies; production Release не содержит этот путь.

Локальный host не имеет Xcode, xctrace, devicectl, signing identities и profiles.
Устройства, реальная доставка push, system ReplayKit и Instruments описаны как
BLOCKED в [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).
