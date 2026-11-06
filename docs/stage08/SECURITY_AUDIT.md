# Аудит безопасности этапа 08

Дата: 2026-11-06. Проверен iOS baseline `42c0295` и изменения этапа 8.
Это обзор исходников, контрактов и целевых тестов; не независимый pentest и не
сертификация безопасности. Production данные и backend не изменялись.

Актуальные upstream refs: backend `9e6058c31cc07bff0f48d8f7f6a40106c55c4881`,
Android `b8f289983e60671d415a128734c2e5bb6e93a29d`, макеты
`04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`. Backend checkout стендов этапа 7
остаётся `0bd1248a2411842515af4e02f1e95821616748fb`. В security review сверены diff
auth middleware/session repository и recording access/library: новый backend
усиливает отзыв сессий и применяет серверную retention policy; обходов прав на
стороне iOS не добавляется. `DELETE /auth/me` уже существовал в baseline backend;
релизная доработка client deletion проверяется отдельным account-lifecycle review.

## Результат и исправление

В проверенных границах не найдено открытых **P0/P1**. Найден и исправлен **P2**:
ответ сервера на загрузку вложения мог неограниченно накапливаться в памяти.
`URLSessionRequestTransport` вызывал async `upload(for:fromFile:)` и проверял
`Data.count` только после полного получения ответа. Пользовательский HTTPS-сервер
мог вернуть огромный либо бесконечный ответ и вызвать завершение приложения из-за
нехватки памяти.

Теперь `BoundedUpload` использует upload task с data delegate: проверяет объявленную
длину до чтения, ограничивает накопленные байты до добавления следующего блока и
немедленно отменяет запрос при превышении. Успешный ответ ограничен caller limit,
ошибка HTTP — 64 KiB. Сохраняются загрузка из файла, системная проверка TLS,
запрет redirects, ephemeral session, progress, отмена задачи и account-wide
`cancelAll()`. Серверный API и предел размера исходного вложения не менялись.

В реализации все mutable поля delegate и registry защищены `NSLock`; continuation
завершается ровно один раз, session инвалидируется и при успехе, и при ошибке.
Сеансы upload входят в account cancellation, последующий logout остаётся возможен.

## Проверенные границы

| Область | Наблюдение в исходниках | Результат / предел |
| --- | --- | --- |
| ATS и TLS | В Info.plist приложения и extension нет ATS exceptions. URLSession использует системное trust evaluation без custom trust callback. API допускает HTTPS, sockets — WSS; redirects отклоняются. | PASS source review и negative URL tests; реальный MITM/истёкший сертификат на устройстве не тестировался. |
| Origin и API scope | `ServerOrigin` отвергает credentials, subpath, query, fragment, percent/backslash/control ambiguity; нормализует scheme/host/default port. `EndpointURL` строит маршруты из проверенных компонентов. AuthenticatedClient закреплён за origin/account. | PASS; чужой URL из ответа не становится назначением bearer-запроса. |
| Session credentials | Access token и refresh-cookie хранятся только в Keychain; auth cookie отправляется явно только в auth routes. Account index содержит origin, UUID, имя/email и иные public account fields, не токены. Refresh single-flight; logout дожидается сохранения refresh перед удалением credentials. | PASS существующих scope/refresh/logout regression tests. Имя, email и IDs остаются персональными данными, хотя это не секреты авторизации. |
| Keychain | Credential и push-journal stores используют scoped service/account queries, `WhenUnlockedThisDeviceOnly`, `Synchronizable=false`, без plaintext fallback или общего удаления Keychain. Отдельный journal содержит IDs и SHA-256 fingerprints, не OS push token. | PASS source review; новые hosted attribute tests требуют результата Xcode CI. Работа при locked device и после restore требует физического устройства. |
| Chat attachments | Файл ограничен 10 MiB, импорт через security-scoped resource и NSFileCoordinator; unsafe filename/path отвергается. Authenticated content URL должен точно соответствовать origin/conversation/attachment. Signed downloads не получают bearer/cookies; длина/hash проверяются. | PASS unit/integration boundaries. P2 upload-response buffering исправлен выше. |
| Записи | Signed URLs не сохраняются в observable/persistent metadata. Отдельная ephemeral session без bearer/cookies/cache; HTTPS, без redirects; 512 MiB disk-stream limit, MIME/size/hash, повторная авторизация после загрузки. AVPlayer получает локальный файл. | PASS тестов потока, отзыва прав и cleanup. Удалённый отзыв уже начатого playback или экспортированной копии не обещается. |
| Файлы на устройстве | Account-scoped cache; iOS Complete file protection, исключение media directories из backup. Cleanup при уходе/закрытии модели, recording crash leftovers очищаются при следующем открытии downloader аккаунта. | PASS источников и cleanup tests. Удаление best-effort при I/O failure; physical lock/backup verification — BLOCKED. |
| WebSocket / media | Fresh tickets ограничены, проверены scope и WSS; без persistent cookies. Ограничен размер сообщений. ICE configuration ограничивает типы/длину URL; TURN TLS policy `.secure`. | PASS source/contracts. ATS относится к URL Loading System, а не ко всему WebRTC/UDP: полной защиты медиа одним ATS не заявляем. |
| App Groups / ReplayKit | Только общий app-group entitlement у host/extension; keychain sharing entitlement не добавлен. Descriptor содержит session UUID, короткоживущий nonce и параметры frames, без API credentials. UNIX socket, bounded frames, handshake, timestamps и heartbeat; pixels не пишутся на диск. | PASS IPC regression/source review. Nonce — временная IPC capability, доверие к общему container зависит от подписи/entitlement. Устройство с реальным provisioning — BLOCKED. |
| Logs / PII | В production Swift sources не обнаружены вызовы print/debugPrint/dump/NSLog/os_log/Logger. UI получает curated errors, без URL, server error body, SDP, ICE secrets или bearer. CI fixtures используют синтетические значения. | PASS ограниченного source scan; это не гарантия отсутствия системных/сторонних диагностических логов и не полный secret audit всей истории Git. |

Основные просмотренные файлы: `Sources/Core/{ServerOrigin,Account,FilePolicy}.swift`,
`Sources/API/{Authentication,RequestTransport,BoundedUpload,ServerProbe,MessagingRepository,RecordingsRepository,RecordingDownloads}.swift`,
`Sources/Storage/{KeychainStore,PushRegistrationStore,AccountFileStore,AccountPreferencesStore}.swift`,
`Sources/Realtime/{UserRealtime,ConferenceSignaling}.swift`, все `Sources/Broadcast/*`,
`Sources/Media/NativePeer.swift`, app/extension plists и entitlements. Пути Sources
относительны `Packages/MeetSpaceKit`. Dependencies/privacy disclosure проверяются
отдельным release review; изменения их деклараций не заменяют эту проверку кода.

## Фактическая проверка

Новые `Stage08SecurityTransportTests.swift`: **3/3 PASS** в первом host-прогоне
этапа 8. В частности, announced 1 GB, chunked response без EOF и oversized HTTP
error отклоняются до завершения ответа; transport отменяет запрос. Проверены
точная граница успешного ответа, сохранение 401 при tiny success limit, 302,
Task cancellation, `cancelAll()` и повторное использование для logout.

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  --filter stage08
git diff --check
```

Первичный log: `/tmp/meetspace-stage08-stress-first.log`. URLProtocol доставляет
ответы настоящему URLSession delegate; сетевые TLS/сертификаты этим тестом не
проверяются. Новые hosted `Stage08SecurityKeychainTests.swift` читают только
attributes созданных тестовых Keychain items после add/update; секретные данные
не запрашиваются и не печатаются. Итоговый Xcode/full-suite результат фиксируется
в `TEST_REPORT.md`, до него hosted tests не объявляются выполненными.

[Source-review evidence](evidence/security-source-review.json) фиксирует scan
production Swift sinks, отсутствие custom trust bypass/process execution, ключи
entitlements и хеши plist. По ограниченному набору GitHub/AWS/private-key signatures
в tracked files совпадений не найдено; содержимое credentials в evidence не выводится.

Существующие тесты дополнительно покрывают cross-origin authenticated download,
signed download без credentials, malformed cookie, changed account during refresh,
late refresh write после logout, download cancellation, запись на диск, guest/
participant permissions, ReplayKit nonce/timeout/frame bounds. Повторять старую
гонку back/new playback отдельным изменением этого этапа не требовалось.

## Ограничения и релизный барьер

Локально доступны только Command Line Tools: нет Xcode/xctrace/devicectl, signing
identity и provisioning profiles. Поэтому device TLS interception, locked-device
Keychain/file protection, signed App Groups, APNs/PushKit и restore from backup
здесь **BLOCKED**, а не PASS. CI simulator не заменяет эти проверки.
Certificate pinning к одному серверу не вводился: приложение принимает пользовательский
HTTPS origin и использует системный trust store; self-signed/broken TLS не обходится.
SSH deployment не выполнялся. Политика резервных копий, privacy disclosures,
dependency provenance и общий список релизных blockers — в отчётах этапа 8.

## Первичные источники

- Apple: [ATS и системная проверка защищённых соединений](https://developer.apple.com/documentation/security/preventing-insecure-network-connections).
- Apple: [WhenUnlockedThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly) и [ограничения accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility).
- Apple: [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).
- Apple: [uploadTask из файла с delegate](https://developer.apple.com/documentation/foundation/urlsession/uploadtask(with:fromfile:)) и [URLSessionDataDelegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate).
