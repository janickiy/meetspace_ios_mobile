# Проверка интерфейса этапа 7

**PASS в описанном ниже объёме:** просмотрены все 26 финальных PNG из
[успешного CI](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42220964006),
source commit `4075edf78b92fb991a341ba057fbf2aaac63bc23`. На каждом симуляторе
прошли 7 hosted и 22 UI теста. В проверенных состояниях нет обрезки значимых
контролов, перекрытий и скрытых ошибок доступа. Полная пиксельная идентичность
web-макетам и проверка всех условий использования не заявляются.

## Условия и границы

Проверяются iPhone SE (3rd generation), 375×667 pt, и iPad mini (A17 Pro),
744×1133 pt, в portrait, русском интерфейсе, светлой теме и стандартном размере
текста. Это симуляторы iOS/iPadOS 26.2. Физические устройства, landscape и все
уровни Dynamic Type новых экранов здесь не проверены. Существующий отдельный
large-text/dark UI regression относится к демо-навигации предыдущих этапов.

Основа — доступные макеты commit `04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`:
calendar в `screens.js`/`app.css`, `recordings-refresh.js/css`, settings handoff.
Точные источники и ограничения описаны в [контрактах календаря](CALENDAR_CONTRACT.md),
[записей](RECORDINGS_CONTRACT.md), [папок](FOLDERS_CONTRACT.md) и
[настроек](SETTINGS_SSH_CONTRACT.md).

Сохранены типографика Inter, цветовая система, карточки, недельная полоса/agenda,
библиотека записей и разделение sidebar/editor настроек на планшете. Native
navigation, date picker, menus, confirmation dialogs и sheets отличаются от web.
Month/list не имеют отдельного состояния в опубликованном макете. Настройки
используют отдельную sidebar-card вместо общей панели, круглые аватары и кнопки
сохранения на ширину редактора; audio/video управляются в звонке, масштаб — через
системный Dynamic Type. Полная пиксельная идентичность не заявляется.

## Исправления по фактическому CI и снимкам

- Строки перехода из профиля реагируют всей областью 44 pt; UI-тест проверяет её размер.
- Done закрывает клавиатуру в профиле и форме календаря; прокрутка не направляется в клавиатуру.
- Ошибка доступа к записи закреплена над содержимым, её видимость проверяется отдельно.
- Новая запись и возврат в каталог сбрасывают прокрутку; title/back должны быть видны.
- Календарный тест выбирает действие подтверждения отдельно от перекрытой кнопки формы.

На прогонах системное окно Passwords перекрывало приложение, но его текст
иногда отсутствовал в app accessibility tree. В UI-тестах обычный поиск кнопки
дополнен узким [Vision OCR](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
fallback: только при заблокированном workspace текущий снимок должен содержать
точные “Save Password?” и “Not Now” с confidence ≥ 0.8, причём отказ расположен
ниже заголовка. Координата нажатия вычисляется из распознанной области текста,
не задаётся константой. Перед нажатием сохраняется screenshot attachment.
Другие системные окна этим helper не подтверждаются. Распознавание отдельно
проверено на сохранённых кадрах iPhone/iPad; обычные экраны не принимаются за диалог.
Финальный CI сохранил по 2 таких attachments на каждом симуляторе; соответствующие
сценарии завершились успешно. Счётчик попыток нажатия находится в [receipt](evidence/ci-run.json).

Эксперимент с метаданными fixture-поля не устранил окно и полностью отменён.
Продуктовое поле пароля не менялось в итоговом diff. Проверки успешного login и
доступности рабочего экрана сохранены. Системное хранение credentials и AutoFill
не входят в этот suite: предложение сохранить фиктивный пароль отклоняется.

История выявленных проблем: [CI attempts](evidence/ci-attempts.json).

## Кадры

PNG копируются из XCTest attachments без редактирования. Manifest связывает каждый
кадр с тестом, source commit, run и SHA-256. Отдельный week-header кадр показывает
переключатели/дни; agenda — положение после прокрутки к встрече. Частичный контент
за границей ScrollView сам по себе не означает обрезание layout. На iPad встреча
уже помещается в исходной позиции, поэтому week и agenda совпадают по SHA-256.

| Сценарий | iPhone | iPad |
| --- | --- | --- |
| Календарь: неделя | [PNG](evidence/screenshots/iPhone-stage07-calendar-week.png) | [PNG](evidence/screenshots/iPad-stage07-calendar-week.png) |
| Почасовая agenda | [PNG](evidence/screenshots/iPhone-stage07-calendar-agenda.png) | [PNG](evidence/screenshots/iPad-stage07-calendar-agenda.png) |
| Календарь: месяц | [PNG](evidence/screenshots/iPhone-stage07-calendar-month.png) | [PNG](evidence/screenshots/iPad-stage07-calendar-month.png) |
| Календарь: список | [PNG](evidence/screenshots/iPhone-stage07-calendar-list.png) | [PNG](evidence/screenshots/iPad-stage07-calendar-list.png) |
| Личные папки | [PNG](evidence/screenshots/iPhone-stage07-folders.png) | [PNG](evidence/screenshots/iPad-stage07-folders.png) |
| Содержимое папки | [PNG](evidence/screenshots/iPhone-stage07-folder-contents.png) | [PNG](evidence/screenshots/iPad-stage07-folder-contents.png) |
| Профиль после сохранения | [PNG](evidence/screenshots/iPhone-stage07-settings-profile.png) | [PNG](evidence/screenshots/iPad-stage07-settings-profile.png) |
| Уведомления аккаунта | [PNG](evidence/screenshots/iPhone-stage07-settings-notifications.png) | [PNG](evidence/screenshots/iPad-stage07-settings-notifications.png) |
| Возможности сервера / SSH | [PNG](evidence/screenshots/iPhone-stage07-settings-server.png) | [PNG](evidence/screenshots/iPad-stage07-settings-server.png) |
| Каталог записей | [PNG](evidence/screenshots/iPhone-stage07-recordings.png) | [PNG](evidence/screenshots/iPad-stage07-recordings.png) |
| MP4 / AVPlayer | [PNG](evidence/screenshots/iPhone-stage07-recording-player.png) | [PNG](evidence/screenshots/iPad-stage07-recording-player.png) |
| AAC настоящего recorder / AVPlayer | [PNG](evidence/screenshots/iPhone-stage07-recording-server-audio.png) | [PNG](evidence/screenshots/iPad-stage07-recording-server-audio.png) |
| Отказ доступа к записи | [PNG](evidence/screenshots/iPhone-stage07-recording-denied.png) | [PNG](evidence/screenshots/iPad-stage07-recording-denied.png) |
