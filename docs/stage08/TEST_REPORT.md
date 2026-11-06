# Тестирование этапа 08

Дата: 2026-11-06. Финальная приёмка текущих изменений ещё **PENDING**.
Проверки разделены по фактически выполненному scope:

| Прогон / source | Проверяемый набор | Уже полученный результат |
| --- | --- | --- |
| [CI15](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42281088607), `55bfcfb` | Full35 на iPhone/iPad26, compatibility15 на iPhone/iPad18 | Оба26: **34 PASS /1 FAIL**; iPhone18 **15/15 PASS**, iPad18 **14 PASS /1 FAIL**. Всего97 PASS /3 FAIL из100, без SKIP; все3 failures — helper удаления |
| [CI16](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42283560617), `a33a153` | Regression14: 10 hosted + Core AX + AX5 + настройки + удаление на каждом из4 устройств | iPhone26 **14/14 PASS**, iPad26 **13 PASS /1 FAIL**; iPhone18 job SUCCESS, итоговые attachments ожидаются; iPad18 PENDING |
| [CI17](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42287121804), `163fb79` | Только deletion UI; package намеренно SKIP | iPad26 job SUCCESS. Остальные3 jobs отменены автором после нового кандидата; workflow CANCELLED, не4×1PASS |
| [CI18](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42288899326), `16c7025` | Только deletion UI, 1 тест ×4 устройства; package намеренно SKIP | PENDING; проверяет native typeText после наблюдаемой латинской раскладки |

Product-код между этими исходниками не менялся. В a33a153 исправлены два места
UI-тестов; в163fb79 добавлен выбор наблюдаемой iPad клавиши abc и all4 deletion scope.
В16c7025 ручной цикл символов/more заменён публичным XCTest `typeText` после
проверки Latin f. Fixture пароли, native SecureField и assertions отказа/отмены/успеха сохранены.
Новый целевой прогон не обозначается как полный suite итоговой ревизии.
История и исходные failures сохранены в [CI_HISTORY.md](CI_HISTORY.md),
[CI15 receipts](evidence/ci-attempt15/receipt.json) и [CI16 receipt](evidence/ci-attempt16/receipt.json).
Все четыре CI15 Core AX прошли:196 initial passes +3 visible retests, без retry;
[единый source-bound receipt](evidence/accessibility-ci15-matrix/receipt.json) сохраняет83 raw findings, включая5 offscreen без contrast measurement.
[Полный baseline receipt](evidence/baseline-ci15-provenance/receipt.json) сохраняет97/3.
Неизвестная post-audit navigation ошибка CI14 в этих запусках не повторилась. Причина старого сбоя не объявлена доказанной.

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

GitHub Actions использует `macos-15-intel` для package/archive и `macos-15` для simulator matrix, максимум два native jobs одновременно; Xcode 26.3 выбран явно. Intel CI14 сохранил тайм-ауты audit engine и инициализации UI runner; переход к ARM не объявлен их доказанным исправлением. Release gate проверяет фактические
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
Тест проваливается при неизвестном или неразрешённом замечании. Для наблюдавшегося тайм-аута движка Apple (`elementDetection`, exact domain/code −56, без единого callback) разрешён один повтор того же pass; обе попытки сохраняются отдельно. Повторная ошибка завершает тест. Успех после повтора не считается успехом с первой попытки. Dynamic Type timeout завершается ошибкой сразу: в CI14 его немедленный повтор закончился ещё одним тайм-аутом, а font overrides могли продолжаться после первого. Узкие reviewed cases
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
| Stress cycles | 18/18 PASS: 6 сценариев × 3 запуска SwiftPM, каждый по 30 циклов | [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md), настоящий host CPU/RSS; не iOS energy |
| Настоящий backend | 2/2 PASS, 0 SKIP; 106 API + 1 version request | [API_CONTRACT.md](API_CONTRACT.md); изолированный backend, не production |
| Конфигурация/контраст | Project generation, audit/foundation integrity, 30 source release checks, 40 palette pairs PASS | Отдельно проверяется содержимое настоящего архива |
| CI16 Release, текущий проверяемый исходник | ARCHIVE SUCCEEDED; 59 packaging checks PASS; signing BLOCKED | `a33a153`; [независимая проверка скачанного архива](evidence/release-product-final/receipt.json), хеш ZIP совпадает с GitHub |
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
