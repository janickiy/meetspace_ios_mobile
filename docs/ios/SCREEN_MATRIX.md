# Макеты → экраны → состояния

Проверено 2026-11-05. `mobile_maket` **не пуст**.
Commit: `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`.
Remote refs: только `refs/heads/main`; тегов на момент проверки нет.
В git — 124 файла. Полный список путей, размеров и SHA-256:
[source-manifest.json](evidence/source-manifest.json).

Источник актуального экрана — цепочка CSS/JS из [preview.html][D-preview] и
[gallery.js][D-gallery], а не произвольный старый PNG. В репозитории есть HTML,
CSS, JS, локальные WOFF2, SVG-знак, JS-иконки, demo-вложение, preview PNG/JPG и
исторические QA JSON. Figma/Sketch-документы, iOS-проект и SwiftUI-компоненты не обнаружены.

**PASS:** материалы доступны и инвентаризированы.
**BLOCKED частично:** нет отдельного полного набора iOS-системных и ошибочных состояний.
Утверждение о точном соответствии ещё не созданного приложения макетам не делается.

## Уровень проверки

Статически проверены 21 ID галереи, подключаемые ресурсы и модули взаимодействий.
Локальная галерея запущена через `serve.py`; в браузере визуально просмотрены
«Встречи», «Личный звонок» и «Просмотр записи» в сравнении телефона/планшета.
Для записи включены тёмная тема и портрет планшета. Наблюдаемые размеры:
телефон 390×844, планшет 1194×834 и после поворота 834×1194.
Это выборочная визуальная проверка прототипа, не нативный screenshot regression suite.

Исторический [verify.mjs][D-verify] содержит 18 screen ID и 6 viewport × 2 темы;
он не покрывает все текущие 21 ID (`folders`, `personal-call`, `register` отсутствуют
в его основной screen matrix). Старые QA JSON не считаются тестами этого этапа.

## Основная матрица

В столбце «Состояния макета» перечислено поведение исходного прототипа, а не
утверждённые ответы backend. «Контракт» связывает функцию с audit parity ID.
Общие недостающие состояния вынесены ниже, чтобы не выдавать их за готовый дизайн.

| ID / экран iOS | Источник макета | Состояния макета | Контракт / ограничение |
| --- | --- | --- | --- |
| `meetings` / Встречи | [meetings.js][D-meetings], [workspace tokens][D-tokens] | Upcoming/active/past, фильтры, создание, планирование, детали | F05–F07: timeline/schedule/invites; текстовый поиск встреч не выводить из timeline query |
| `messages` / Чаты | [screens][D-screens], [chat refresh][D-chat] | Все/личные/новые, поиск, папки, действия над чатом | F08–F10; scopes personal/conference различаются |
| `settings` / Профиль | [settings][D-settings] | Profile/audio/video/notifications/appearance/connection/accounts; saved/dirty | F02–F04, F18; server preferences отделить от локальных AV-настроек |
| `thread` / Диалог | [chat refresh][D-chat], [groups][D-groups] | Отправка, reply, edit/delete, pins, поиск, вложения, group info | F08–F10; emoji reactions на сообщения BLOCKED |
| `calendar` / Календарь встреч | [screens][D-screens], [meetings][D-meetings] | Выбор дня, встречи и планирование | F15: timeline подтверждён; внешний OAuth отдельный сценарий |
| `recordings` / Библиотека | [recordings refresh][D-recordings] | Список/плитка, поиск, период, сортировка, фильтр встречи/состояния | F14; в API только cursor/limit, полный серверный поиск BLOCKED |
| `recording` / Запись | [recordings refresh][D-recordings] | Demo-плеер, файлы, информация, transcript/AI tabs | F14/F19: плеер без реального файла; AI/transcript в backend удалены |
| `folders` / Папки | [folders refresh][D-folders] | Создание, rename, order, выбор чатов/встреч, удаление | F10: API папок есть, доступ к объектам проверяется отдельно |
| `prejoin` / Перед встречей | [screens][D-screens], [call meeting][D-calls] | Выбор камеры/микрофона, предпросмотр, подключение | F11; системные iOS permissions не представлены |
| `call` / Видеовстреча | [call meeting][D-calls] | Участники, чат, waiting/admission, роли, mic/camera/screen, четыре режима записи | F07/F11/F13/F14; UI прав выводить из backend, не из demo-owner |
| `personal-call` / Личный звонок | [personal-call.js][D-personal] | Outgoing/incoming/connected, mic/camera, завершение, возврат | F12; нет записи/третьего участника, background call UI BLOCKED |
| `welcome` / Первый запуск | [onboarding][D-onboarding] | Подключить сервер / создать сервер | F01/F17; не требуется сетевой endpoint экрана |
| `connect` / Адрес сервера | [onboarding][D-onboarding] | Ввод URL/приглашения, переход к login | F01; нормализация HTTPS, ошибка TLS не подменяется demo-success |
| `login` / Вход | [onboarding][D-onboarding] | Email/password, ошибка, demo-login | F02; пароль `demo` относится только к макету |
| `register` / Регистрация | [onboarding][D-onboarding] | Имя/email/password, validation, возврат | F02; сервер после register не выполняет автоматический login |
| `deploy` / Создание сервера | [onboarding][D-onboarding] | SSH host/user/credentials, параметры | F17: Android SSH protocol; не REST endpoint MeetSpace |
| `fingerprint` / Ключ SSH | [onboarding][D-onboarding] | Показ fingerprint и доверие | F17; iOS SSH implementation BLOCKED до выбора/проверки транспорта |
| `preflight` / Проверка сервера | [onboarding][D-onboarding] | Ресурсы, сеть, blockers | F17; выводить реальные результаты probe |
| `install` / Установка | [onboarding][D-onboarding] | Этапы и прогресс | F17; demo-progress не подтверждает реальную установку |
| `complete` / Установка готова | [onboarding][D-onboarding] | URL сервера, переход к входу | F17; нужен readiness установленного сервера |
| `install-error` / Ошибка установки | [onboarding][D-onboarding] | Ошибка и варианты продолжения | F17; реальные errorCode/resume из installer protocol |

Все 21 screen ID покрыты. Детальные API-контракты и статусы Fxx находятся в
[FEATURE_PARITY.md](FEATURE_PARITY.md), [API_CONTRACTS.md](API_CONTRACTS.md).

## Вложенные экраны и панели

| Панель | Материал | Состояния / пробелы |
| --- | --- | --- |
| Notifications inbox | [notifications.js][D-notifications] | Unread/read, popover/центр; APNs permission и push failure отсутствуют |
| Аккаунты | [settings][D-settings], runtime accounts module | Несколько аккаунтов, add/switch/logout/delete; реальная origin isolation не моделируется |
| Profile/group avatar | [avatars.js][D-avatars], [groups.js][D-groups] | Выбор, crop, save/remove; iOS Photos picker/ограниченное разрешение не представлены |
| Audio settings | [settings][D-settings] | Выбор входа/выхода/сигнала, уровни, noise reduction, auto-mute; реальное аудио имитируется |
| Video settings | [settings][D-settings] | Камера, preview, параметры отображения; физические capture profiles не подтверждаются макетом |
| Meeting detail/schedule/invite | [meetings][D-meetings], [call meeting][D-calls] | Формы, диалоги, роли; email delivery зависит от backend |
| Group create/edit/members/leave | [groups][D-groups] | Имя/аватар/участники, сохранить/отменить; реальное управление ролями проверяет сервер |
| Message actions / attach | [chat][D-chat] | Reply/edit/delete/pin/reaction/file; reaction не имеет подтверждённого message API |
| Recording start/stop | [call meeting][D-calls], workspace refresh | Четыре режима; запуск доступен registered participant, stop — initiator/owner |

## Дизайн-токены и адаптация

`app.css` подключается раньше `workspace-refresh.css`. Поэтому цвета из старого
handoff (`#3668ed`) не являются конечной палитрой workspace. Проверенные глобальные
переопределения [workspace-refresh.css][D-tokens]:

| Token | Light | Dark |
| --- | --- | --- |
| `--bg` | `#f7f8fc` | `#171821` |
| `--surface` | `#ffffff` | `#21232f` |
| `--surface2` | `#f0f1f7` | `#2b2e3e` |
| `--ink` | `#292b3b` | `#f3f3fa` |
| `--muted` | `#727687` | `#b0b3c7` |
| `--line` | `#e7e8f0` | `#36394c` |
| `--accent` | `#6264d9` | `#aaaaff` |
| `--accent-soft` | `#eeeffe` | `#343452` |

Это глобальные значения, не исчерпывающий каталог component CSS. Специальные стили
звонка/аватаров/групп подключаются отдельно; при реализации измерять итоговый каскад.

Шрифт — локальный Inter (latin/cyrillic, файлы 400 и 600 WOFF2).
База в [app.css][D-base-css]: текст 14 px, line-height 1.5; h1 30/1.2,
h2 19, h3 15, small 12. Отдельные компоненты переопределяют размеры.
Native-ready TTF/OTF и лицензия шрифта в инвентаре не найдены: перед включением
шрифта в приложение нужны подтверждённые файлы/лицензия, а не молчаливая замена.

Handoff описывает Android Compact/Medium/Expanded; актуальный workspace CSS
использует и границу 700 px. Эти значения нельзя выдать за спецификацию iPad Split View.
Основная навигация — три вкладки: Встречи / Чаты / Профиль; записи и папки вложенные.
Старые `four-tabs.html` и preview-картинки не задают актуальную навигацию.

## Что ещё нужно для точной реализации iOS

1. Материалы для offline/reconnecting/session-expired, server incompatible,
   403/409/429, пустых выборок и ошибок upload/download по экранам. Код реакции
   на такие ошибки можно подготовить независимо; точный визуал пока BLOCKED.
2. Нативные permissions camera/mic/photos/notifications; отказ и переход в Settings;
   CallKit lock screen и ReplayKit broadcast lifecycle.
3. iPad multiwindow/Split View, клавиатура, safe areas, Dynamic Type, VoiceOver
   и длинные строки. Наличие tablet preview не подтверждает эти сценарии.
4. Подтверждённые Inter-файлы для native и лицензия. Отдельно согласовать изменения
   экранов с AI/transcript/message reactions, не имеющими API.

Глобальная визуальная часть не заблокирована отсутствием макетов; BLOCKED относятся
к перечисленным пробелам. Независимую архитектуру можно проектировать по контрактам,
но в этапе 01 SwiftUI-экраны не создавались.

<!-- pinned-source-links -->
[D-avatars]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/avatars.js
[D-base-css]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/app.css
[D-calls]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/call-meeting.js
[D-chat]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/chat-refresh.js
[D-folders]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/folders-refresh.js
[D-gallery]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/gallery.js
[D-groups]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/groups.js
[D-meetings]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/meetings.js
[D-notifications]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/notifications.js
[D-onboarding]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/onboarding.js
[D-personal]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/personal-call.js
[D-preview]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/preview.html
[D-recordings]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/recordings-refresh.js
[D-screens]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/screens.js
[D-settings]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/account-settings.js
[D-tokens]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/workspace-refresh.css
[D-verify]: https://github.com/janickiy/mobile_maket/blob/04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3/meetspace-refresh-20261016/verify.mjs
