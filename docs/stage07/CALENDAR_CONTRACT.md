# Календарь: контракт и границы реализации

Сверено 2026-11-06 с backend `0bd1248a2411842515af4e02f1e95821616748fb`,
Android `b8f289983e60671d415a128734c2e5bb6e93a29d` и макетами
`04d6a8ecdac75ae568459bbed0f3f6647bf8cbb3`. Backend не изменяется.

## Фактические операции

| Операция | Контракт |
| --- | --- |
| Лента | `GET /api/v1/me/conferences`, `view=upcoming/active/past`, `scope=all/owned/participating`, `sort=oldest`, `from`, `to`, `limit=100`, opaque `cursor` |
| Создание | `POST /api/v1/conferences`, `title`, `waitingRoomEnabled`, `scheduledAt`, optional `plannedDurationMin` |
| Перенос | `PUT /api/v1/conferences/:id/schedule`, `scheduledAt`, optional `plannedDurationMin`; только owner и только `scheduled` |
| Отмена | `POST /api/v1/conferences/:id/cancel`, ответ `item`; окончательное разрешение принимает сервер |

Источники backend: `internal/transport/http/platform_routes.go`,
`internal/app/conferences/product_handler.go`, `internal/domain/conferences/product.go`,
`internal/infrastructure/postgres/conference_product_repository.go`.
Android: `core/data/.../MeetingsApi.kt`, `core/model/.../MeetingsModels.kt`,
`app/.../ui/CalendarDashboard.kt`.

Backend сортирует/фильтрует по `finishedAt ?? scheduledAt ?? createdAt`, а не всегда
по времени начала. iOS использует ту же семантику. Timeline скрывает приглашения;
для входа существующий ConferenceWorkspace повторно читает конференцию. Частично
неуспешная загрузка трёх видов ленты отображается явно; страницы подгружаются отдельно,
без ложного сообщения о полностью пустом календаре при ошибке или следующем cursor.

## Время и сохранение

Сервер принимает будущий RFC3339 instant с явным timezone; длительность 1–1440 минут.
Клиент отправляет UTC. Выбор IANA timezone меняет отображение, но не дату/время встречи
на сервере. `DatePicker` работает в выбранной зоне, а форма показывает полный UTC offset
выбранного instant. Timezone и week/month/list сохраняются в UserDefaults отдельно
для server + user; credentials не входят в эту запись.

Границы недели/месяца строятся Gregorian Calendar в выбранной зоне календарной
арифметикой, а не прибавлением 86400 секунд. Верхняя граница backend включительна;
iOS отсекает события точно на начале следующего периода, сохраняя server cursor.
Неделя начинается в понедельник. При закрытии аккаунта epoch запрещает поздней
загрузке вернуть данные в модель. POST create не имеет idempotency key: если результат
не подтверждён, повторное создание требует явного подтверждения проверки списка.

## Макеты

`meetspace-refresh-20261016/screens.js`, экран `calendar`, и `app.css` задают заголовок,
недельную полосу с выделенным днём, почасовой agenda, карточки событий и правую колонку
на широком экране. Эти элементы использованы в SwiftUI через существующий MSTheme.
Месячная сетка, список, timezone picker, формы ошибки/переноса — iOS-адаптация:
отдельных состояний month/list в опубликованном макете нет. Полная пиксельная
идентичность не заявляется. Внешняя синхронизация Google/других календарей не добавлена:
это отдельный OAuth/provider contract и не требуется для локального календаря встреч.

## Проверки

Добавлены `CalendarTests`, `CalendarPreferencesTests`, `CalendarContractTests`:
недели DST 167/169 часов, високосный февраль, разные локальные даты одного instant,
повторяющийся час, UTC serialization, exclusive end, per-server/account preferences,
смешанные ошибки/pagination, owner/status visibility, отзыв in-flight load и защита
от повтора неоднозначного создания. Фактический результат общего Swift/CI прогона,
runtime-проверок и визуальной приёмки приведён в основном отчёте этапа.
