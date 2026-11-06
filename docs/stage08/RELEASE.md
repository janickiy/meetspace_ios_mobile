# Подготовка релиза MeetSpace iOS

Дата проверки требований: 2026-11-06. Это инструкция подготовки артефакта, а не подтверждение публикации или допуска Apple. Итоговые результаты Stage 8 находятся в `TEST_REPORT.md`; неподписанная сборка, simulator tests и подписанная App Store distribution — разные проверки.

## Текущее состояние и ограничения

- Проект рассчитан на iPhone/iPad, iOS 18+. Release использует оптимизацию `-O`, dSYM, отдельный ReplayKit Upload Extension, production APNs entitlement и общий App Group.
- Для `a33a153147d6941874884357134b3fd46de7532c` CI16 собрал настоящий неподписанный device archive: версия `0.2.0 (1)`, Xcode `26.3 (17C529)`, SDK `iphoneos26.2`, minimum `18.0`. Независимая проверка скачанного архива: **59 PASS; signing.distribution BLOCKED**; [receipt и хеши](evidence/release-product-final/receipt.json). Production trees App/Packages/BroadcastExtension совпадают с `16c7025`; новый архив для последующего test-only commit не собирался. Native suite и signing учитываются отдельно.
- На локальном хосте выбран Command Line Tools, полного Xcode нет; валидных code-signing identities — 0, provisioning profiles — 0. Проверялись только наличие и количество, без экспорта ключей, сертификатов или содержимого профилей. Подключение/возможности физических устройств этим не доказаны.
- Архив с Apple Distribution, экспорт `.ipa`, TestFlight, реальный APNs и физические device gates остаются **BLOCKED** до доступности необходимых ресурсов. Эта работа не выполняет отправку в Apple.
- WebRTC M156 закреплён по версии, Git revision и checksum; его device framework поставляется без подписи дистрибьютора. Подписание/происхождение SDK и полнота notices требуют закрытия перед распространением. Подробнее ниже.
- Опубликованные privacy/support URLs, App Store Connect карточка, актуальные privacy labels, age rating, export compliance и права на распространение должны быть подтверждены владельцем продукта. Значения не выдуманы и в Apple не отправлялись.

С 28 апреля 2026 Apple требует **Xcode 26+ и iOS/iPadOS SDK 26+** для загружаемых приложений. Deployment target 18.0 при этом допустим: SDK сборки и минимальная версия ОС имеют разное назначение. Проверка читает реальные `DTXcode`, `DTSDKName`, `DTPlatformName` из готового продукта. Требование сверено с [Apple Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/).

## Воспроизводимые проверки

Из корня репозитория, на macOS:

```sh
python3 scripts/generate_xcode_project.py --check
python3 scripts/verify_foundation.py
python3 scripts/verify_release.py --report artifacts/release-source.json
```

`verify_release.py` проверяет Release scheme/configurations, отсутствие DEBUG, согласование версий и bundle IDs, App Group, APNs production, ATS, purpose strings, manifests, AppIcon и зафиксированную зависимость. Код возврата 1 означает нарушение проверяемого условия. Код 0 без `.app` означает только успешную проверку исходной конфигурации; отсутствие фактического артефакта явно помечается `BLOCKED`.

Неподписанная сборка для устройства, а не симулятора:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild \
  -project MeetSpace.xcodeproj -scheme MeetSpace-Release -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath artifacts/ReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/verify_release.py \
  --app artifacts/ReleaseDerivedData/Build/Products/Release-iphoneos/MeetSpace.app \
  --report artifacts/release-product.json
```

Путь Xcode должен соответствовать фактически установленной версии 26+. CI закрепляет Xcode явно; версия и SDK выводятся в логе. Указанная команда не доказывает работоспособность подписи, Apple services, физической камеры или энергопотребления. Проверка продукта требует native WebRTC, собственные manifests приложения/расширения/SDK, встроенный `.appex`, скомпилированный AppIcon и notices в ресурсах.

## Идентификаторы и signing

| Назначение | Текущее значение | Требование перед архивом |
| --- | --- | --- |
| Application bundle ID | `com.meetspace.ios` | Зарегистрирован в выбранной Apple Developer Team; Push Notifications включены |
| Broadcast extension ID | `com.meetspace.ios.BroadcastUpload` | Отдельный explicit App ID той же Team |
| App Group | `group.com.meetspace.ios.broadcast` | Зарегистрирован и включён для обоих App IDs и обоих profiles |
| Release APNs | `production` | Distribution profile приложения разрешает entitlement |
| Version / build | Генератор проекта задаёт оба target согласованно | Перед каждым upload выбрать ещё не использованный build number |

Смена bundle ID требует согласованно обновить generator, `MeetSpaceBroadcastExtension` в `App/Info.plist`, App Group и Apple registrations; одного переопределения `PRODUCT_BUNDLE_IDENTIFIER` всем target недостаточно. Изменения generator фиксируются вместе с заново сгенерированным `.xcodeproj`.

Приложение имеет только APNs и App Group entitlements; extension — только App Group. Release не должен содержать `get-task-allow=true`. Не следует добавлять VoIP entitlement/token contract по предположению: [Stage 5](../stage05/CALLKIT_APNS_SETUP.md) отдельно описывает ограничения существующего gateway/PushKit. ReplayKit требуется проверить на устройстве по [Stage 6 device plan](../stage06/DEVICE_TEST_PLAN.md).

После предоставления Team, сертификата с приватным ключом и подходящих profiles оператор может выполнить архив. Здесь приведена команда, **она не выполнялась локально**:

```sh
xcodebuild -project MeetSpace.xcodeproj -scheme MeetSpace-Release \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath artifacts/MeetSpace.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID archive
python3 scripts/verify_release.py --archive artifacts/MeetSpace.xcarchive \
  --require-signing --report artifacts/release-signed-archive.json
```

Automatic signing требует заранее настроенной учётной записи и profiles. Скрипт ничего не создаёт в Apple Developer Portal. При ручной подписи оба target получают свои distribution profiles в локальной signing-конфигурации; сертификаты, ключи и `.mobileprovision` не коммитятся.

`--require-signing` проверяет подписи приложения/расширения, public entitlements, совпадение Team/App Group/app identifiers, production APNs, отсутствие debugging/device-list/enterprise profiles и срок действия профилей. Их содержимое обрабатывается только в памяти и не попадает в JSON. Это технический gate, не замена Xcode Organizer Validate App и серверной проверке Apple.

Для локального экспорта создайте вне Git `ExportOptions.plist` с `method=app-store-connect`, `destination=export`, `teamID=YOUR_TEAM_ID`, подходящим `signingStyle` и, для manual signing, `provisioningProfiles` для **обоих** bundle IDs. Затем:

```sh
xcodebuild -exportArchive -archivePath artifacts/MeetSpace.xcarchive \
  -exportPath artifacts/Export -exportOptionsPlist /private/path/ExportOptions.plist
```

Экспорт не выполняет upload. Перед разрешённой отдельно отправкой следует проверить Organizer Validate App, сохранение dSYM и подписанный экспорт. Apple описывает workflow в [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## Зависимости и privacy

| Компонент | Зафиксированное происхождение | Проверка / остаток |
| --- | --- | --- |
| `stasel/WebRTC` | Version `156.0.0`; Git `3cc466ea040e5dcd1344697bf211dc4c079d1a0c` | Единственная внешняя SPM-зависимость, exact pin |
| Binary artifact | `WebRTC-M156.xcframework.zip`; SHA256 `43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46` | SPM checksum и предыдущий скачанный hash совпадают; не является подписью поставщика |
| Upstream WebRTC | `2a990ce0ccd00a3ad449f2201a8e5c2dad53177d`, `branch-heads/8078` | Device/simulator slices и SDK manifest есть |
| SDK notices | BSD-3-Clause, PATENTS, distributor license, 39 дополнительных license/notice texts | Консервативный набор; точный GN graph данного binary не предоставлен дистрибьютором |
| Inter fonts | Уже аудированные ресурсы и `Inter-OFL.txt` | Встроенная лицензия проверяется в продукте |

Доказательства pin/checksum/notices находятся в `docs/ios/evidence/stage04/webrtc-library.json` и `webrtc-notices.json`. [Повторная проверка Stage 8](evidence/release-dependencies.json) фиксирует revision, checksum manifest/binary, slices и metadata подписей: **и корневой XCFramework, и device framework не подписаны**. Нельзя выдавать checksum, ad-hoc signature симулятора или последующее подписание приложения за developer signature поставщика SDK. [Source gate](evidence/release-source.json) сохраняет хеши проверенной конфигурации; при dirty working tree он не выдаёт HEAD за точный снимок всех изменений.

Apple требует manifests и подписи для перечисленных binary SDK и их repackaged вариантов; в списке есть Abseil и BoringSSL. Они присутствуют среди зафиксированных native dependencies WebRTC. Поэтому до App Store нужно получить проверяемый подписанный SDK с полным отчётом зависимостей либо воспроизводимо собрать и оформить собственный binary artifact из закреплённых исходников, после чего повторить license/privacy/signature review и реальную Xcode validation. Применимость требований к итоговому пакету не доказана успешной simulator-сборкой. Это **BLOCKED distribution gate**, а не заявление об отклонении приложения Apple. Источник: [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/).

Согласованная матрица App Privacy, локальных API reasons и ещё необходимых publisher confirmations — в [PRIVACY_DISCLOSURE.md](PRIVACY_DISCLOSURE.md). App manifest теперь включает Device ID для сохраняемого APNs delivery token. Extension не сохраняет и не отправляет данные на сервер самостоятельно; передача экранных кадров приложению по App Group socket покрывается пользовательским согласием ReplayKit и disclosure приложения. Пользовательские записи/вложения на сервере не следует смешивать с transient RTP.

## Материалы для App Store Connect

До заполнения карточки продукта оператор подтверждает название, категорию, локализованные description/keywords, support URL, privacy-policy URL, контакт для review и demo account на доступном сервере. Нет автоматической публикации и выдуманных серверных credentials.

Нужны актуальные ответы App Privacy и age rating (включая пользовательские сообщения/файлы), export compliance для используемой криптографии TLS/DTLS-SRTP/BoringSSL и права на бренд/ресурсы. `ITSAppUsesNonExemptEncryption` намеренно не установлен в `false` без классификации экспортёром. Account deletion должна быть доступна из приложения при наличии регистрации; удаление локального аккаунта/Keychain не равно удалению серверного аккаунта. Требование: [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/).

На этапе 8 реализовано серверное удаление из профиля с паролем и подтверждением:
[контракт и lifecycle](ACCOUNT_DELETION.md), [настоящий одноразовый backend-прогон](API_CONTRACT.md).
Неверный пароль сохраняет сессии, подтверждённое удаление отзывает их; другой аккаунт
сохраняется. Эти API-проверки не заменяют завершение UI-проверки на текущем исходнике,
проверку подписанной установки и подтверждение владельцем политики удаления общих
данных. Актуальный итог simulator matrix должен быть указан в [TEST_REPORT.md](TEST_REPORT.md);
незавершённый либо неуспешный прогон не закрывает release gate.

Реальные simulator screenshots лежат в evidence Stage 7 и Stage 8. Они подтверждают UI проверенных сценариев; это не обещание готовых маркетинговых App Store screenshots. Для загрузки нужны выбранные владельцем реальные экраны без fixture data и подходящие размеры актуальных iPhone/iPad display classes. Требования размеров проверяются перед upload по [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/).

## Критерий допуска к распространению

Успех source/product gates и CI нужен, но недостаточен. До TestFlight/App Store должны быть закрыты: подписанный архив и экспорт, SDK provenance/notices gate, подтверждение privacy/export/metadata, корректная account-deletion flow, физические device/performance/security gates из отчётов Stage 8. Не выполненный gate остаётся `BLOCKED`; его нельзя заменить отметкой PASS по документации или mock-тестам.
