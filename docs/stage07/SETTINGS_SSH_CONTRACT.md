# Настройки и статус SSH

Аудит 2026-11-06. Источники: backend `0bd1248a2411842515af4e02f1e95821616748fb`,
Android `b8f289983e60671d415a128734c2e5bb6e93a29d`, макеты
`04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`. Backend не изменялся.

## Подтверждённый API

| Действие | Фактический контракт | iOS |
| --- | --- | --- |
| Профиль | `GET /api/v1/auth/me` → `{user}`; `PATCH /api/v1/auth/me` с единственным `displayName` → `{user}` | Редактируется только имя, email read-only; trim, 1–100 Unicode scalars, без control characters; проверяются ID и email ответа |
| Уведомления | `GET`/`PUT /api/v1/notifications/preferences`; пять Bool: `invitation`, `reminder`, `recording`, `email`, `push` | Сохраняются все пять полей, неизвестные локальные переключатели не добавляются в запрос |
| Устройства | `GET /api/v1/notifications/devices` → `{items:[id,platform,provider,createdAt,updatedAt,revokedAt?,disabledAt?]}` | Список push-привязок и статусы. Это не список авторизованных сессий и не аппаратный inventory |
| Платформа | `GET /api/v1/capabilities` → `{status,capabilities:{recordingModes},buildVersion}` | Известные recording modes используются библиотекой записей; серверные значения не превращаются в обещания готовности |
| Интеграции | `GET /api/v1/integrations/capabilities` → `email/push/calendar/calendarOAuthConfigured/mockConnectAllowed` | Показаны категории провайдеров; `http` не означает подтверждённую доставку APNs |

Источники: backend `internal/transport/http/platform_routes.go`,
`integration_routes.go`, `platform_status_routes.go`, `internal/app/auth/handler.go`,
`internal/domain/users/user.go`, `internal/domain/integrations/integration.go`,
`internal/domain/platform/platform.go`; Android `core/data/.../MeetSpaceApi.kt`,
`MessagingApi.kt`, `DefaultFoundationRepository.kt` и их contract tests.

В текущем backend общие capabilities содержат только `recordingModes`.
Флаги transcription/AI/captions не выдуманы и не включаются отсутствующими полями.
Неизвестные поля JSON допускаются; malformed/null/слишком большие recordingModes
отклоняются. Отсутствующий список modes означает отсутствие подтверждённой функции.
Тема остаётся локальной в `PreferencesStore`; аккаунты, их отдельные Keychain-сессии
и выбор сервера используют существующий IdentityModel. Обновлённый профиль также
сохраняется в публичный индекс аккаунтов через scoped callback.

`SettingsModel` создаётся для конкретного клиента, не выполняет запросы при login
и не блокирует восстановление. Чтение происходит при открытии настроек; ошибки
одного раздела не блокируют сохранение имени. Закрытие/switch/logout отзывают epoch:
поздний ответ не обновляет интерфейс или индекс следующего аккаунта.

Серверный `push` — разрешение канала для всех устройств аккаунта. Отдельный toggle
в профиле отвечает за согласие ОС и регистрацию текущего iPhone/iPad, сохраняя
журнал cleanup этапа 5. Удаление чужих push-привязок не добавлено в UI: отключение
этой установки выполняется существующим безопасным journal/disable. На backend
есть `DELETE /notifications/devices/:deviceId`, но remote session logout API нет.

Макеты доступны: `meetspace-refresh-20261016/handoff.html` описывает отдельные
страницы настроек на телефоне и sidebar/editor на планшете, редактирование имени,
email read-only и явное сохранение уведомлений. Эти принципы перенесены в SwiftUI.
Поля макета, не существующие в API (например серверный звук уведомлений), не
отправляются. Аудио/видео управляются в действующих экранах звонков; декоративные
device-test переключатели из макета не представлены как рабочие настройки.
Шрифт, карточки и темы используют общий DesignSystem; полная пиксельная идентичность
и самостоятельная регулировка размера текста 75–200% не заявляются (iOS Dynamic Type).

## SSH: не утверждено для iOS, выключено

`IOSFeatureAvailability.sshInstallationEnabled == false`. Это локальное решение
продукта, которое не может быть включено непроверенным ответом capabilities.
В настройках явно написано, что установка недоступна; ввод паролей/ключей,
SSH-соединение, установочный прогресс и изменение VPS не выполняются.

Фактический Android `core:ssh` уже содержит:

- `JschSshTransport`: новый transport/session на операцию; discovery ключа до
  USERAUTH; `StrictHostKeyChecking=yes`, pin действительного handshake, отказ при
  изменении ключа; no PTY/agent forwarding и ограниченный stdout/stderr.
- `HostPinStore`: host/port scope, SHA-256 fingerprints, атомарное добавление pin
  без автоматической замены существующего ключа.
- `PrivateKeyPolicy`: ограничения размера/формата и затрат KDF; in-memory ключи,
  уничтожение owned buffers, отсутствие секретов в журнале. Это свойства Android,
  не проверенная реализация Swift.
- `SshInstallerRepository` и `InstallerProtocol`: подписанный bundle (RSA/SHA-256),
  hashes runner/Docker key, verified plan hash, отдельные `plan/apply/status/cancel/resume`,
  подтверждение Docker/ACME, публичный recovery ticket без SSH credentials.
- Проверка host key повторяется перед authenticated operation и при handshake;
  ключ, показанный на preflight, связан с последующей установкой.

Backend `install.sh` — интерактивный Linux bootstrapper для нового сервера:
root, `/dev/tty`, amd64/arm64, по умолчанию готовые образы, source build явно.
Он изолирует Git-конфигурацию, получает checkout, проверяет запрошенный SHA при
передаче полного commit и делегирует Python installer. Простой запуск через
неинтерактивный SSH exec не повторяет Android structured job protocol. Скрипт
заявляет, что существующая установка не обновляется/не удаляется; это не основание
считать любой повторный запуск безопасным без проверки конкретного job/plan.

Сверенные SHA-256:

| Файл | SHA-256 |
| --- | --- |
| backend `install.sh` | `2136e73bfb566a7e1ca195651707e44d8dac6ad89374e20f1f04514ee360e780` |
| Android `JschSshTransport.kt` | `92bc05eba59b61bbf998b0389e8cfff3411eb546b761045239d33b011cbf22a8` |
| Android `InstallerProtocol.kt` | `4feb24b64efc5d0fb1e737ff43b0fb993bcc037069efb6c806f5e26a4718f062` |

## План отдельной iOS-реализации после утверждения

1. Выбрать и проверить SSH-библиотеку для поддерживаемых iOS/архитектур: host-key
   callback до authentication, pinning, современные алгоритмы, bounded I/O,
   cancellation; проверить лицензии и отсутствие обхода TLS/SSH trust.
2. Discovery возвращает настоящий ключ и SHA-256 fingerprint; пользователь
   сверяет его с VPS-консолью. Changed key всегда блокирует соединение и требует
   отдельного осознанного reset/trust, без автоматического TOFU overwrite.
3. По умолчанию пароль/ключ живут только в памяти операции. Импорт через системный
   file picker с ограничениями размера/KDF; при отдельно выбранном хранении —
   scoped Keychain `ThisDeviceOnly`, без синхронизации, логов и UserDefaults.
   Буферы zeroize где библиотека позволяет; Swift String не обещает гарантированного
   стирания, поэтому секреты не должны проходить через строки журнала.
4. Перенести verified signed bundle и canonical plan binding, не конкатенировать
   введённый host/domain в shell. Read-only preflight определяет ОС, ресурсы,
   Docker, существующую установку, DNS/TLS и реальные порты выбранной версии.
5. Перед apply показать проверенный release/commit/digest, план изменений и
   отдельные согласия на Docker/ACME. Не заменять данные существующего сервера.
6. Прогресс брать из `status` конкретного job, ограничивать/очищать журнал.
   Suspend/обрыв не равны успеху или отмене; recovery ticket содержит только
   публичный plan/job binding, после foreground повторяется host verification.
7. PASS требует disposable VPS tests: changed key/MITM, malformed keys/дорогая KDF,
   отмена/обрыв/восстановление, signature/hash mismatch, permission denied,
   existing install, HTTPS health и отдельная media readiness. Пока всё это
   **NOT_RUN/BLOCKED**, SSH не считается готовой функцией этапа 7.
