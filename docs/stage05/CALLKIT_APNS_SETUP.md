# CallKit, APNs и PushKit: настройка и границы проверки

Дата проверки исходников и документации Apple: 2026-11-06.

## Что реализуется на клиенте

`MeetSpaceCalling` разделяет системные звонки, обычные APNs и VoIP PushKit. Один
`CXProvider`/`CXCallController` живёт на уровне процесса; координаторы отдельных
аккаунтов получают независимые подписки. Ответ, завершение и mute передаются
координатору как идентификаторы действий, которые нужно завершить `fulfill` или
`fail`. Сброс провайдера завершает текущие звонки, но не уничтожает подписки.
Действия, истёкшие по таймауту CallKit, повторно не завершаются.
Запись в системные Phone Recents выключена: текущий generic handle — UUID вызова,
а проверенного account-scoped redial/NSUserActivity контракта ещё нет.

Обычный APNs adapter получает новый токен от UIApplication; PushKit имеет отдельный
registry и отдельный registrar. Токены не сохраняются и не выводятся в лог. Завершение
аккаунтной сессии сначала отключает регистрацию обычных remote notifications, затем
модель удаляет точные серверные регистрации этого устройства.

CallKit создаётся при запуске приложения через app delegate, до восстановления
SwiftUI-состояния. Само наличие провайдера не регистрирует VoIP push. Native PushKit
adapter создаёт `PKPushRegistry` только после явной инъекции
`ValidatedVoIPPushDeployment`. **Для текущего backend эта инъекция отсутствует;
production PushKit registration выключена.**

## Фактический backend и блокер VoIP push

Проверенный сервер поддерживает:

| Контракт | Фактическое поведение |
| --- | --- |
| `POST /api/v1/notifications/devices` | Только `platform` и `token`; для iOS используется `platform: "ios"`. Токен: 8–8192 байт. |
| `GET /api/v1/notifications/devices` | Список `items` текущего аккаунта. |
| `DELETE /api/v1/notifications/devices/:deviceId` | Удаление конкретной регистрации текущего аккаунта; успешный ответ 204. |
| `GET /api/v1/integrations/capabilities` | Push provider: `noop`, `mock` или `http`. Это не подтверждение APNs-доставки. При `noop` регистрация недоступна. |
| HTTP provider → gateway `/push/send` | Передаёт `idempotencyKey`, `token`, `title`, `body`, `url`. APNs transport в сервере не реализован. |
| Прямые звонки | Публикуют `call.updated` с `{call}` через user WebSocket и `conversation.updated`; VoIP push job/payload отсутствует. |

Регистрация не различает обычный APNs и VoIP token, bundle ID, APNs environment или
installation ID. В коде нет APNs provider credentials, формирования `.voip` topic или
проверенного VoIP payload. Подставлять PushKit token в существующий generic endpoint
нельзя: это создало бы неподтверждённую серверную возможность.

HTTP gateway может самостоятельно реализовать **обычные** APNs, если это действительно
развёрнуто и проверено владельцем сервера. Значение `http` в capabilities само по себе
такой проверки не заменяет. Текущие настройки сервера — `PUSH_PROVIDER_MODE`,
`PUSH_PROVIDER_ENDPOINT`, `PUSH_PROVIDER_TOKEN`, `PROVIDER_TOKEN_ENCRYPTION_KEY`.

## Требуемые изменения сервера — предложение, не выполненная реализация

Для полноценного VoIP deployment требуется отдельное согласование контракта:

1. Раздельная регистрация обычного APNs и VoIP token с корректным account/server
   scope, bundle/topic, sandbox/production и стабильной идентификацией установки.
2. APNs transport либо доверенный gateway с обработкой ответа APNs, инвалидированием
   недействительных токенов и идемпотентностью. Наличие generic HTTP gateway не
   означает, что эти механизмы уже существуют.
3. Push job только для реального нового входящего звонка; payload должен позволять
   синхронно получить проверяемую идентичность звонка/аккаунта и данные интерфейса.
   Точные wire keys здесь намеренно не задаются.
4. Отдельная политика duplicate/stale/malformed payload, согласованная с CallKit и
   серверным жизненным циклом. Она должна быть реализована в verified resolver до
   включения PushKit.
5. Надёжный отзыв регистраций при смене аккаунта, logout и неизвестном результате
   POST; защита от одновременного связывания одного device token с разными аккаунтами.

Серверные изменения в этом этапе не выполняются. Apple требует `apns-push-type: voip`
и topic `<bundle-id>.voip` для VoIP, а для обычного уведомления — `alert` и topic самого
приложения. Expiration входящего звонка должен быть нулевым либо очень коротким, чтобы
не доставлять старый вызов позднее. См. [APNs request headers](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
и [обработку VoIP push](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

## Подпись и credentials

- App ID в Apple Developer должен иметь Push Notifications capability. Bundle ID
  подписанного приложения должен совпадать с разрешённым APNs topic.
- `aps-environment`: Debug — `development`, Release — `production`; итоговое значение
  нужно проверить в подписанном архиве и provisioning profile. TestFlight использует
  production. Этот entitlement применяется и к UserNotifications, и к PushKit.
  См. [APS Environment Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment).
- `UIBackgroundModes` содержит `audio` и `voip` для реализованных звонков. `voip`
  требуется CallKit transaction и при выключенном PushKit registry; его отсутствие
  может вернуть `unentitled`. `remote-notification` не добавляется ради обычных alert
  notifications без реализованного silent-push flow.
  См. [CallKit unentitled](https://developer.apple.com/documentation/callkit/cxerrorcoderequesttransactionerror-swift.struct/code/unentitled)
  и [Background Modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes).
- Дополнительный выдуманный «VoIP push entitlement», Default Calling App entitlement
  и entitlement фильтрации notification extension для этой реализации не нужны.
- APNs `.p8` private key либо сертификат с private key хранится только на доверенном
  provider/gateway, в secret storage, с ограничением доступа и ротацией. В приложение,
  Git, payload, CI artifact и диагностические логи он не попадает.
- Произвольный self-hosted сервер не получает право отправлять push для чужого bundle
  ID. Нужен доверенный gateway владельца приложения либо собственная подписанная
  сборка с собственным App ID и соответствующими Apple credentials. Ключ общего
  production-приложения нельзя раздавать всем self-hosted инсталляциям.

Сертификатный вариант описан в [Apple: APNs certificate connection](https://developer.apple.com/documentation/usernotifications/establishing-a-certificate-based-connection-to-apns).
Наличие локального `.entitlements` файла без соответствующей подписи не подтверждает
работоспособность push на устройстве.

## PushKit deadline и системное аудио

Синхронный PushKit delegate сначала передаёт incoming call в `CXProvider` и только
после этого может запускать восстановление аккаунта/сети. Completion PushKit
вызывается ровно один раз из результата CallKit, в том числе при отказе системы.
Нельзя ждать HTTP, Keychain или WebSocket перед `reportNewIncomingCall`. Apple может
завершить приложение за непереданный VoIP-вызов. Отмена и обновление уже доставленного
вызова идут через серверное соединение, а не через дополнительный VoIP push.
См. [PKPushRegistryDelegate](https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/pushregistry(_:didreceiveincomingpushwith:for:completion:)).

Целевой baseline — iOS 18 / SDK 18.5. Более новый API iOS 26.4 с
`PKVoIPPushMetadata.mustReport` не используется как обход обязательного report в
поддерживаемом старом callback.

Для прямого звонка `ConferenceMediaConfiguration.audioActivation = .callKit`.
Категория аудио конфигурируется заранее, но engine не вызывает `setActive(true)`.
`CXProvider.didActivate/didDeactivate` передаются в WebRTC
`RTCAudioSession.audioSessionDidActivate/Deactivate`; manual audio gate разрешает
audio unit только после системной активации. Peer/SDP можно подготовить до неё.
Нельзя задерживать `CXAnswerCallAction.fulfill` до первого аудиопакета: активация
аудио сама зависит от завершения системного действия. См.
[CXProviderDelegate.didActivate](https://developer.apple.com/documentation/callkit/cxproviderdelegate/provider(_:didactivate:)).

При уходе direct call в background камера выключается, а аудио остаётся под контролем
CallKit. Это не меняет правила обычных конференций этапа 4. Реальные маршруты receiver,
speaker, Bluetooth, interruptions и lock screen нужно проверить на устройствах.

## Logout, токены и заблокированное устройство

Backend генерирует ID регистрации из user ID, provider mode и SHA-256 токена.
Один physical token может оказаться у нескольких аккаунтов. Клиент удаляет только
известные собственные device IDs, а не все устройства аккаунта.

Журнал незавершённого отзыва хранит server/account scope, device IDs и fingerprint
токена; raw token остаётся в RAM. Неуспешный revoke или неизвестный результат POST
блокирует новую регистрацию до разрешения старого scope. Если ID неизвестен, токен
сменился или старые credentials уже удалены, может потребоваться повторный вход в
старый аккаунт либо серверное исправление. Нельзя объявлять успешный отзыв при
отсутствии подтверждения сервера.

Текущий Keychain использует `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, в том числе
для credentials и журнала регистраций. При заблокированном устройстве данные могут
быть недоступны. Поэтому восстановление авторизованной media session из terminated/
locked состояния **не подтверждено и не объявляется работающим**. Входящий push всё
равно должен быть немедленно передан CallKit без ожидания Keychain; дальнейший ответ
обязан корректно завершиться при невозможности восстановить сессию. Автоматического
ослабления Keychain accessibility здесь нет.

## Проверки и матрица реальных устройств

На момент создания этого документа выполнены: полная Swift 6 typecheck модулей Media
и Calling против Apple Catalyst headers и настоящего WebRTC M156; 7 unit tests
границы Calling в отдельной временной копии Core/Media/Calling. Проверены sync report,
completion success/error ровно один раз, конкурентный callback, независимые
подписки после account cancellation, replay и недоступность native APIs на host.
Это не подписанная iOS-сборка и не проверка APNs/CallKit на устройстве.

`CallAudioIntegrationTests.testDirectCallCanNegotiateBeforeCallKitActivatesAudio`
добавлен для hosted iOS CI. До получения результата CI он считается NOT_RUN.

| Физический сценарий | Статус | Что нужно подтвердить |
| --- | --- | --- |
| Outgoing → answer → двусторонний звук, завершение | NOT_RUN | Два устройства, реальные серверные состояния и CallKit actions. |
| Incoming при открытом приложении | NOT_RUN | Системный UI, reject/answer, DND/error path. |
| Обычный APNs alert в foreground/background/terminated | NOT_RUN | Подпись, gateway, правильный environment и актуальный token. |
| VoIP push background/terminated | BLOCKED | На текущем сервере отсутствует VoIP transport/contract; после его согласования — физическая проверка. |
| Ответ с lock screen, включая перезапуск устройства | NOT_RUN | Доступность Keychain, restore, activation без deadlock. |
| Ответ/отказ на другом устройстве | NOT_RUN | Первый серверный winner, остальные CallKit UI закрываются соответствующей причиной. |
| Audio interruption, Bluetooth removal, speaker/receiver | NOT_RUN | Нет нежелательной записи, корректный mute и возврат маршрута. |
| Background video | NOT_RUN | Камера выключается; возвращение в foreground не включает её без действия пользователя. |
| Token rotation/logout/offline revoke/account switch | NOT_RUN | Отзыв точных регистраций; новый аккаунт не получает старые уведомления. |
| Повторный/stale/malformed VoIP push | BLOCKED | Сначала verified payload policy; затем report deadline и отсутствие лишнего вызова. |

PASS этапа для доставки APNs/VoIP не может быть получен из одних mock tests или
Simulator UI. Реальные credentials, deployment и физические устройства в этой
проверке не использовались.
