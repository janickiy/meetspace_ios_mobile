# Privacy disclosure: проверяемая матрица

Проверено по исходникам на 2026-11-06. Это подготовленные ответы для владельца продукта; они не отправлены в App Store Connect. Выбранный пользователем сервер и его реально развёрнутые интеграции могут обрабатывать дополнительные данные, поэтому privacy policy и окончательные labels должны быть подтверждены оператором сервиса. Apple требует учитывать данные приложения и partners; локальная обработка и только транзит в реальном времени имеют иной смысл, чем хранение после запроса: [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

## Данные, передаваемые серверу

Во всех строках ниже назначение — App Functionality, linked to user — Yes, tracking — No. В клиенте нет advertising/analytics SDK, IDFA или ATT-запросов. Это не утверждение о произвольном сервере, введённом пользователем.

| Apple data type | Фактическая функция | Источник в проекте |
| --- | --- | --- |
| Name | Регистрация, профиль, имя участника | `API/Authentication.swift`, `API/SettingsRepository.swift` |
| Email Address | Регистрация, вход, профиль, приглашения | Authentication, Settings/Calendar repositories |
| User ID | Account-scoped авторизация, чаты, встречи, права | `Core/Account.swift`, authenticated repositories |
| Device ID | APNs token сохраняется сервером для уведомлений, привязан к аккаунту | `API/NotificationDeviceRepository.swift`; добавлен в app manifest на Stage 8 |
| Emails or Text Messages | Личные/групповые/встречные сообщения | Chat repositories |
| Photos or Videos | Вложения, серверные записи; avatar при доступности соответствующей функции | Files/recordings/profile contracts |
| Audio Data | Звуковые вложения и серверные записи | Files/recordings contracts |
| Other User Content | Документы, названия папок/встреч, события календаря, прочие вложения | Calendar/folder/file repositories |

Device ID здесь — delivery identifier, а не рекламный идентификатор. Apple включает и другие device-level IDs в этот тип: [NSPrivacyCollectedDataType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).

Незарегистрированный/отключённый push не передаёт token; возможное включение push всё равно требует disclosure. PushKit token не отправляется в обычный notifications API. Нельзя заявлять работающий VoIP APNs без действительного gateway contract и device proof.

Камера, микрофон и screen frames участвуют в live transport. Сам по себе real-time поток не означает серверное сохранение; при доступной записи и пользовательских вложениях сохраняемый контент уже входит в матрицу. Необходимо подтвердить фактические recording retention/deletion и доступы выбранного развёртывания. Backend access logs/IP, внешние email/push/recording providers и operator analytics требуют отдельного подтверждения владельцем; manifest клиента не доказывает их отсутствие.

## Required-reason API и manifests

| Bundle | Категория / reason | Фактическое применение |
| --- | --- | --- |
| App | UserDefaults / `CA92.1` | Собственные тема, календарь, account preferences; не чтение global preferences чужих приложений |
| App и BroadcastUpload | SystemBootTime / `35F9.1` | `DispatchTime.now().uptimeNanoseconds` для локальных сроков/таймаутов IPC |
| WebRTC SDK | SystemBootTime / `35F9.1`, `8FFB.1`; FileTimestamp / `C617.1` | Manifest внутри самого закреплённого SDK; приложение не подменяет декларации SDK |

`AccountFileStore` читает size/type выбранного файла, `BroadcastWire` — size/type descriptor в App Group; клиент не запрашивает creation/modification timestamp keys, `stat`, свободное место или keyboard inventory. Дополнительные API reasons не добавлялись на основании одного имени метода. После любых изменений файловой/diagnostic логики этот список нужно пересмотреть по [актуальному перечню Apple](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

App и extension имеют свои `PrivacyInfo.xcprivacy`, SDK — свой; bundled manifests проверяются в реальном `.app`. Apple требует manifest в bundle, который использует соответствующий API, и SDK не может полагаться на manifest приложения: [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

## Перед заполнением privacy policy / labels

- Указать реального оператора и публичный privacy-policy URL; в проекте они не выдуманы.
- Подтвердить серверные retention/deletion, доступ участников/администраторов, processors и расположение данных, обработку IP/logs и фактическую работу recordings.
- Проверить удаление серверного аккаунта и его данных; локальный logout/удаление Keychain не заменяет эту функцию.
- Сгенерировать Xcode Privacy Report из окончательного архива, сопоставить его с этой матрицей и проверить warnings. Source-only plist validation не является отчётом Xcode.
- Подтвердить export compliance с учётом WebRTC/BoringSSL; не проставлять exemption автоматически.

Статус окончательных labels/privacy policy/архивного Xcode Privacy Report: **BLOCKED**, пока владелец не подтвердил фактическое развёртывание и нет подписанного production archive. Реальные private keys, device tokens, production account identifiers и содержимое provisioning profiles в evidence не сохраняются. Синтетические UUID из изолированных API/UI fixtures присутствуют в тестовых отчётах.
