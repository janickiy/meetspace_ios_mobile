# ReplayKit: подпись, устройство и границы приёмки

Дата: 2026-11-06. Настоящая ReplayKit-трансляция и физические измерения в этой
сессии **NOT_RUN/BLOCKED**. Simulator doubles показывают только состояние приложения.

## Настройка Apple

1. В Apple Developer зарегистрировать App ID основного приложения и отдельный
   `com.meetspace.ios.BroadcastUpload`; для обоих разрешить одну App Group.
2. Значение `BROADCAST_APP_GROUP` в проекте по умолчанию:
   `group.com.meetspace.ios.broadcast`. Оно должно существовать у выбранной команды
   и присутствовать в обоих provisioning profiles/подписанных entitlements.
3. При смене bundle ID обновить ID extension и `MeetSpaceBroadcastExtension` в
   `App/Info.plist`. Проверить итоговый `MeetSpace.app/PlugIns/BroadcastUpload.appex`,
   совпадение Team ID и версий app/extension, `APPLICATION_EXTENSION_API_ONLY=YES`.
4. `NSExtensionPointIdentifier` — `com.apple.broadcast-services-upload`,
   `RPBroadcastProcessMode` — `RPBroadcastProcessModeSampleBuffer`. Отдельный
   broadcast setup UI extension не требуется: используется системный picker.
5. Не помещать credentials аккаунта, Apple private keys, tickets или SDP в App Group.
   Эта реализация передаёт расширению только параметры кадра и короткую IPC lease.

См. [системный picker](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview),
[RPBroadcastSampleHandler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler),
[App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups).
Privacy manifests app/extension декларируют SystemBootTime `35F9.1` для локальных
таймеров/deadlines; см. [required reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Ограничения исполнения

Расширение использует локальный Unix domain socket. Длина пути App Group должна
помещаться в `sockaddr_un.sun_path`; иначе подготовка явно недоступна. Длинные пути
Simulator могут не подходить. Host IPC тестируется в коротком временном каталоге;
это не проверка App Group provisioning. Descriptor имеет file protection Complete,
не содержит кадров или секретов аккаунта и удаляется при завершении.

Системная трансляция требует работающего основного процесса для WebRTC. Extension
не выдаёт ему дополнительного права фонового исполнения. При пропаже main-actor
heartbeat примерно за 5 секунд extension прекращает захват; socket write имеет
отдельный предел 0.5 с. Если iOS приостановит/завершит приложение, обещания продолжить
вещание нет. Поддержка вне приложения должна быть проверена на устройстве с реальным
audio lifecycle; искусственного silent audio keepalive здесь нет.

Обрабатываются только `.video`; `.audioApp` и `.audioMic` игнорируются, microphone
button picker скрыт. Это не доказательство и не обещание передачи системного звука.
Warning/critical memory pressure останавливает extension; жёсткий jetsam может
прекратить процесс раньше callback, тогда приложение обнаруживает закрытый socket.
Ограничения 10 FPS/1280×720 и bounded queues описывают алгоритм, а не достигнутые
показатели устройства.

## Матрица устройств

Для каждого результата зафиксировать модель, iOS/iPadOS, build SHA, подпись/team,
server SHA и конфигурацию, сеть/ICE route, длительность и способ измерения.
Использовать тестовые аккаунты и несекретное содержимое экрана.

| Сценарий | iPhone | iPad | Критерий |
| --- | --- | --- | --- |
| Picker → подтверждение → другое приложение | NOT_RUN | NOT_RUN | Web и Android показывают корректный screen track и читаемое изображение |
| Отмена picker и повторный запуск | NOT_RUN | NOT_RUN | Нет screen RTP до согласия, старая lease не пригодна для нового запуска |
| Portrait/landscape, все поддержанные повороты | NOT_RUN | NOT_RUN | Правильная ориентация/цвета/пропорции, без зеркалирования |
| Stop в app и системный Stop | NOT_RUN | NOT_RUN | Кадры прекращаются, экран исчезает у получателей, slot свободен |
| Два одновременно запускающих участника | NOT_RUN | NOT_RUN | Один получает конфликт; текущий показ и голос продолжаются |
| Запрет screen/camera, kick, logout, switch account | NOT_RUN | NOT_RUN | Захват и публикация прекращаются, нет автоматического рестарта |
| Pause/resume, lock/unlock | NOT_RUN | NOT_RUN | Нет выдачи старых кадров; восстановление учитывает актуальные права/конфликт |
| Terminate host/extension, сеть offline/online | NOT_RUN | NOT_RUN | Нет бесконечной трансляции без host, новые кадры только после нового согласия |
| 10 минут статичного и движущегося экрана | NOT_RUN | NOT_RUN | Измерены исходный/принятый FPS, drop rate, задержка, CPU, RAM обоих процессов, thermal |
| Low-memory/длительная смена ориентации | NOT_RUN | NOT_RUN | Контролируемый stop либо jetsam cleanup, нет роста очереди/остаточных SFU ресурсов |
| Личный звонок с CallKit и Bluetooth/interruption | NOT_RUN | NOT_RUN | Экран не меняет владельца аудиосессии, выход не оставляет capture |

Измерять FPS/CPU/RAM отдельно для host и extension средствами Instruments/Activity
Monitor/OS signposts и статистикой принимающего клиента, сохраняя исходные результаты.
Не подменять эти графы скоростью синтетического Pion probe или временем unit-тестов.
