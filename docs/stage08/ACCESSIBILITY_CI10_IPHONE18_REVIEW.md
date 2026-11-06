# CI10 iPhone18: CoreAX, visible retests и compact visual review

Проверено 2026-11-06 по [CI10 42263390594](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42263390594), source **`e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`**. Устройство — iPhone SE (3rd generation), simulator iOS 18.6, Xcode 26.3 (17C529), scope `compatibility`, portrait **375×667 pt / 750×1334 pixels**. [Environment](evidence/accessibility-attempt10/iPhone18-environment.json), [summary](evidence/accessibility-attempt10/iPhone18-summary.json), [точные строки лога](evidence/accessibility-attempt10/iPhone18-review-test-results.txt).

**CoreAX PASS — 592.715 s; AX5 live flow PASS — 237.005 s; conference PASS — 136.549 s; demo large text PASS — 24.961 s. Весь job — FAIL, 14 PASS / 1 FAIL из 15:** последнее assertion теста удаления аккаунта не прошло. Успешное удаление с возвратом на login и несовпадавшее ожидание welcome разбираются отдельно в [ACCOUNT_DELETION](ACCOUNT_DELETION.md). Это не PASS всего CI10 или последующего кандидата `a052abd`.

## Raw findings и выполненные retests

Финальный [raw JSON](evidence/accessibility-attempt10/iPhone18-stage08-accessibility-issues.json) содержит **24 findings: 16 reviewed, 3 verified после собственного visible retest, 5 вне retest viewport без измерения contrast**. [Производные счётчики](evidence/accessibility-attempt10/iPhone18-audit-counts.json) сохраняют полное разбиение и пять неизмеренных записей.

| Категория | Количество | Решение |
| --- | ---: | --- |
| Partial Dynamic Type (`65536`) | 14 | 12 exact custom-font cases и 2 menu-title cases; независимое измерение масштабирования и отдельная AX5 layout-проверка. |
| Contrast (`1`) | 9 | 1 reviewed decorative avatar; 3 первоначальных targets повторены полностью видимыми без нового finding; 5 других findings вне viewport повторного прохода — не измерены. |
| Text clipping (`131072`) | 1 | Exact `welcome.heading`; полная строка видна в normal и AX5 снимках. |

`unresolved = 0`, незавершённых `deferred = 0`; финальный assert прошёл. У всех записей сохранены label/frame; три пустых identifier относятся к avatar, прокрученному за верх профиля «Календарь» и верхнему recording title. Cumulative progress counts welcome/messages/profile/calendar/recordings/folders/settings: **1, 2, 4, 18, 23, 24, 24**. Это накопительные snapshots, их нельзя суммировать.

В отличие от [iPad18 CI10](ACCESSIBILITY_CI10_IPAD18_REVIEW.md), эта конфигурация исполнила очередь deferred targets и три дополнительных `.contrast` audit:

| Target | Исходный frame, pt | Наблюдение после reveal |
| --- | --- | --- |
| `addAccount`, «Добавить аккаунт» | `(24, 654, 327, 44)` | В [visible retest PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-accessibility-profile-visible-addAccount.png) вся кнопка и надпись находятся в середине экрана, над tab bar. Повторный audit не сообщил target. |
| `calendar.weekday.5`, «Сб» | `(344.25, 369.25, 13.5, 12.5)` | Первоначально правый край за горизонтальным viewport; [retest PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-accessibility-calendar-visible-calendar.weekday.5.png) показывает целые «Сб» и дату после горизонтальной прокрутки. Повторный audit не сообщил target. |
| `recording.status.…777773`, «Не удалось записать» | `(146, 602.5, 113.5, 13.5)` | Первоначально под tab bar; [retest PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-accessibility-recordings-visible-recording.status.77777777-7777-4777-8777-777777777773.png) показывает полный статус, дату и title третьей карточки. Повторный audit не сообщил target. |

Пять **других** findings в этих retests не стали рекурсивной очередью. Их решение — буквально `outside retest viewport: no contrast measurement`, не reviewed/verified:

| Finding | Frame, pt | Граница покрытия |
| --- | --- | --- |
| Profile, anonymous «Календарь» | `(41.5, -14, 98.5, 17)` | Выше экрана после прокрутки к Add account. |
| `calendar.weekday.1`, «Вт» | `(18.25, 369.25, 11.5, 12.5)` | Частично за левым краем горизонтального scroll после reveal «Сб». |
| `recordings.filterHint` | `(24, -9.5, 307.5, 13.5)` | Выше viewport после reveal третьей записи. |
| `recordings.retentionNotice` | `(24, 564, 327, 72)` | Нижние строки закрыты tab bar; **в CI10 iPhone18 нет собственного полностью видимого contrast retest footer**. |
| Recording, anonymous «Обсуждение проекта» | `(146, 36, 93.5, 34)` | Верхняя карточка частично за navigation bar. |

Отдельный AX5 [footer PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-large-text-recordings-footer.png) показывает весь retention text над tab bar, но подтверждает layout, **не contrast**. Эти пять findings нельзя включать в число успешных измерений. Правила и ограничения метода: [ACCESSIBILITY_POLICY](ACCESSIBILITY_POLICY.md).

## Просмотренные изображения и границы

Просмотрены **все 26 PNG: 7 normal, 3 visible retest, 16 AX5**. Они скопированы без crop/resize/изменения байтов. [Review manifest](evidence/accessibility-attempt10/iPhone18-review-manifest.json) содержит source filenames, timestamps, testIdentifier и SHA-256 для 39 файлов; [оригинальный export manifest](evidence/accessibility-attempt10/iPhone18-export-manifest.json) сохранён отдельно. Final raw и семь cumulative progress JSON также сохранены неизменёнными.

- **Normal:** welcome hero и две основные actions полностью видны; messages header/search/filters и fixture conversation читаются целиком. Profile показывает account и feature links; нижние account/notification действия доступны на retest PNG. License/deletion actions не показаны. Calendar header, period и controls целые; два normal/retest кадра вместе показывают все семь weekdays, а первоначальный viewport — только час 09. Recordings normal/retest вместе показывают четыре title/date/status; footer ограничен, как указано выше. Folders показывает полный empty state/privacy text. Settings — четыре section rows целиком; profile editor на iPhone этим сценарием не открыт.
- **AX5 messages:** [initial PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-large-text-messages.png) сохраняет весь «Сообщения», перенося последнюю «я» на следующую строку. [Conversation PNG](evidence/accessibility-attempt10/screenshots/iPhone18-stage08-large-text-messages-conversation.png) после прокрутки показывает полный row и preview. Heading и row не обязаны помещаться одновременно. Переносы внутри слов остаются визуально неидеальными, но символы не потеряны.
- **AX5 recordings:** полный heading и обе filter labels видны; четыре target PNG показывают полный title, mode «Общий вид» / «Только аудио», дату и statuses «Готова», «Обрабатывается», «Не удалось записать», «Готова». Error переносится на две строки без потери слов. Footer целиком виден в собственном кадре; длинное «воспроизведением» переносится внутри слова. Это продолжает подтверждение исправления узких карточек из [CI9 compact review](ACCESSIBILITY_COMPACT_REVIEW.md).
- **AX5 calendar:** initial PNG показывает полный heading, subtitle, scope и time-zone labels; period начинает выходить за нижний viewport. Target PNG 9/12/18 вместе показывают целые часы 09…18. Weekday labels и весь period/today block при AX5 этими кадрами не подтверждены: при переходе к часам они уходят за верх, отдельного AX5 day/period screenshot здесь нет.
- **AX5 profile/folders/settings:** видимые title/account и первые три settings sections читаются, хотя слова переносятся внутри. Четвёртый settings section, profile actions ниже account и нижний privacy text folders вне снятого viewport. Welcome hero полностью виден, brand переносится `MeetSpa`/`ce`; lower choices не видны в AX5 welcome кадре.

Новых visual blockers в просмотренных областях не найдено. Все три tab labels и icons сохранены, крайние labels при AX5 занимают две строки; demo large-text test прошёл. PNG не использовались для повторного вычисления pixel contrast или измерения hit targets. CoreAX с documented exceptions, тремя retests и пятью явно неизмеренными findings не доказывает WCAG conformance, физическое VoiceOver acceptance, все runtime/device combinations или полную visual parity 21 DESIGN screen. Последующий исправленный кандидат требует собственного native результата.
