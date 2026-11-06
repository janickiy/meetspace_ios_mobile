# Тестирование этапа 08

Дата: 2026-11-06. Финальная приёмка текущих изменений ещё PENDING:
[CI 42275177048](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42275177048),
source `04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f`, полный scope.
Неуспешные предыдущие прогоны и исправления сохранены в [CI_HISTORY.md](CI_HISTORY.md).
Ниже отделены выполненные проверки от незакрытых simulator gates.

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

GitHub Actions использует `macos-15-intel` и выбирает Xcode 26.3 явно. Release gate проверяет фактические
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
AX5 live navigation/scroll, удаление аккаунта, создание конференции/media controls/chat/leave
и large-text/appearance. Full scope включает все UI сценарии
предыдущих этапов. Runtime/family не заменяются при отсутствии: runner завершится
с BLOCKED/failure, сохранив доступный inventory.

Автоматический аудит сохраняет все исходные issues и их решения в JSON attachment.
Тест проваливается при неизвестном или неразрешённом замечании. Для двух наблюдавшихся тайм-аутов движка Apple (`elementDetection` и `dynamicType`, exact domain/code −56, без единого callback) разрешён один повтор того же pass; обе попытки сохраняются отдельно. Повторная ошибка завершает тест. Успех после повтора не считается успехом с первой попытки. Узкие reviewed cases
и независимые проверки описаны в [ACCESSIBILITY_POLICY.md](ACCESSIBILITY_POLICY.md);
количество raw findings не выдаётся за ноль. Не используется blanket suppression. Скриншоты сняты
XCUITest из работающего приложения, не сгенерированы из дизайна. Сценарии используют
DEBUG fixture dependencies; production Release не содержит этот путь.

Локальный host не имеет Xcode, xctrace, devicectl, signing identities и profiles.
Устройства, реальная доставка push, system ReplayKit и Instruments описаны как
BLOCKED в [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

## Уже полученные результаты

| Проверка | Фактический результат | Evidence / граница |
| --- | --- | --- |
| SwiftPM local, текущий исходник | 179 PASS, 5 opt-in SKIP, 0 FAIL из 184; focused deletion 11/11 | [Push-ordering receipt](evidence/account-deletion/push-ordering/receipt.json); macOS host. Ранее три повтора 176/181 после исправления stress assertion сохранены отдельно |
| Stress cycles | 18/18 PASS: 6 сценариев × 3 процесса, каждый по 30 циклов | [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md), настоящий host CPU/RSS; не iOS energy |
| Настоящий backend | 2/2 PASS, 0 SKIP; 106 API + 1 version request | [API_CONTRACT.md](API_CONTRACT.md); изолированный backend, не production |
| Конфигурация/контраст | Project generation, audit/foundation integrity, 30 source release checks, 40 palette pairs PASS | Отдельно проверяется содержимое настоящего архива |
| CI13 Release, тот же production-код | ARCHIVE SUCCEEDED; 59 packaging checks PASS; signing BLOCKED | `a052abd`; [независимая проверка скачанного архива](evidence/release-product-attempt13/receipt.json), хеш ZIP совпадает с GitHub |
| CI3 hosted tests | 10/10 PASS на каждом из четырёх симуляторов | Настоящий Keychain и 74 комбинации шрифтов × 12 размеров на каждой платформе |
| CI3 native suite | iPhone26 33/35, iPad26 32/35, iPhone18 11/15, iPad18 13/15 PASS | Неуспешный прогон: новые accessibility/deletion проверки и compact large-text layout; прежние full UI сценарии прошли |
| Current iPhone/iPad CI | PENDING | Все 4 device/runtime комбинации должны завершиться, без skipped simulator tests |
| Physical devices / Instruments / signed IPA | BLOCKED | [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) |

## Исправления по реальным неуспешным прогонам

- CI1 `42228833201`, исходник `25f54fb`: package/unsigned archive прошли; UI выявил
  проблемы accessibility, подтверждения удаления и фокуса поля конференции на iPad.
- CI2 `42233879641`, исходник `acc193a4`: сохранены 29 raw iPhone26 findings и normal/AX5
  снимки в [ACCESSIBILITY_REVIEW.md](ACCESSIBILITY_REVIEW.md). Снимки выявили настоящие
  наложение calendar scope и clipping recording filters; menu labels исправлены.
  iPad AX5 navigation прошла; отдельная review — [ACCESSIBILITY_IPAD_REVIEW.md](ACCESSIBILITY_IPAD_REVIEW.md).
- CI2 также выявил race в stress assertion CallKit completion; ограниченное ожидание
  фактического результата проверено тремя полными локальными suite. Login helper вернулся
  к прямому вводу в secure field, нативное подтверждение удаления заменено alert с отменой
  на обеих платформах; welcome audit изолирован от следующего login запуском приложения.
- Временные отменённые push/dispatch прогоны не засчитываются как успешные проверки.
  Исторические findings сохраняются; новый исходник должен получить собственный результат.

UI tests работают с изолированными DEBUG fixtures. Hosted tests используют настоящие
Security.framework, UIKit/SwiftUI и AVPlayer/RTC компоненты в симуляторе. Они не
подтверждают камеру, физический аудиомаршрут, APNs delivery, системный захват ReplayKit,
ручной VoiceOver или непрерывный часовой звонок на устройстве.
