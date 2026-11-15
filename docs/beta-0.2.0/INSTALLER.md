# Нативный установщик iOS

Источник протокола: Android `9681bddb31c738d133fe9e82794cd52c9c27faec`,
`core/ssh`, `InstallerViewModel` и `installer/v1`. Макет:
`mobile_maket@c4f00b57a9058a44586addd87b92318007ebd55f`, `installer.js`,
`installer-options.js`, `installer.css`.

Реализованы адрес VPS → проверка SSH-ключа без USERAUTH → явное доверие → пароль
или файл OpenSSH Ed25519 → read-only диагностика → параметры → проверяемый
план → применение → наблюдение/остановка/продолжение → результат.
Обязательны данные администратора; SMTP опционален. Пароли администратора и SMTP передаются только
на этапе применения через stdin SSH, без включения в командную строку или логи.
Публичный ticket сохраняется до apply; после перезапуска нужны новые credentials.
Потерянный ответ не трактуется как отсутствие задания. Отдельная read-only
перепроверка плана восстанавливает существующий job либо возвращает новый план,
который требует нового явного подтверждения.

Используется нативный Citadel (revision закреплён), NIO SSH. Операция владеет отдельной NIO event-loop group от TCP connect до завершения.
Shutdown закрывает все её каналы, включая ожидающий handshake; отмена и ошибки
освобождают соединение. Используется `Citadel.connect(to:)`, устанавливающий
обработчики до чтения banner; `connect(on:)` не используется из-за обнаруженного
в закреплённой версии нарушения event-loop precondition.
TCP deadline 15 секунд, внутренний handshake/auth deadline 10 секунд,
исполнение ограничено 180 секундами; stdout 256 КиБ, stderr 16 КиБ,
payload 512 КиБ. Inspection прерывает host authentication до отправки credentials.
Подтверждённый ключ закреплён по host/port; каждый authenticated handshake сверяет
реальный ключ. Смена ключа требует удаления доверия и независимой повторной проверки.

Точные Android runner, manifest, signature, trust root и Docker key включены
без изменения байтов. [Provenance и SHA-256](../../Packages/MeetSpaceKit/Sources/Installer/Resources/provenance.json).
На клиенте проверяются RSA-подпись manifest, runner/Docker hashes, canonical hash
плана, привязка source/image lock, endpoint/options/job/status. Сам runner повторно
проверяет план, срок действия, ресурсы и идентичность release перед изменениями.

Границы текущей реализации:

- Собственный SSL-сертификат в макете — расширение прототипа, отсутствующее в
  Android signed runner. iOS показывает это ограничение; поддержан Let's Encrypt
  с согласием на условия. Такое отличие не объявляется визуальной идентичностью.
- Импорт ключа: OpenSSH Ed25519, включая зашифрованный passphrase. RSA/EC/PKCS1
  PEM не поддерживаются. Optional RSA в Citadel использует legacy SHA-1, поэтому
  он намеренно не включён; интерфейс предлагает Ed25519 или пароль SSH. Host-key
  negotiation сохраняет современные Ed25519/ECDSA defaults NIO. Это отличие от
  Android; неподдерживаемый ключ не заменяется другим методом входа автоматически.
- Credentials живут только в памяти, очищаются при закрытии/уходе в фон. Swift
  String не гарантирует физическое обнуление всех внутренних копий.
- Idle доступ истекает через 10 минут; просмотр подтверждённого плана/начатого
  задания сохраняет доступ до закрытия, как Android. Удалённая установка продолжает
  работать независимо от окна приложения.
- Диагностика показывает фактические результаты probe, включая unknown. Она не
  доказывает доступность всех портов из интернета. Применение подтверждённого плана
  остаётся дополнительной серверной проверкой.
- Выпуск не изменяет чей-либо VPS. Полный deploy/readiness реального VPS и
  собственный сертификат не являются пройденными проверками.
- Старые Android tickets/legacy recipes не импортируются: iOS хранит только свои
  задания с текущим подписанным recipe.

Для DEBUG UI-test используется только сочетание `-uitesting -installer-fixture`.
Синтетический transport проходит тот же parser/validation и не подключается к VPS;
обычный Debug и Release запускаются с живым SSH transport.

Опциональный loopback SSH contract использует `scripts/fixtures/ssh_installer.py`
с Paramiko во временной Python-среде; он не выполняет shell/installer, а считает
handshake, auth и stdin; delayed-auth сценарий проверяет отмену до exec. Запуск теста с `MEETSPACE_SSH_FIXTURE=1` проверяет
`installerNativeSSHHandshakePinningAndStdin`; без переменной тест явно пропускается.
Фактические результаты запусков записываются отдельно в итоговый отчёт.
