# CI10 iPad18: завершённый CoreAX и visual review

Проверено 2026-11-06 по [CI10 42263390594](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42263390594), source **`e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`**. Устройство — iPad mini (A17 Pro), simulator iOS 18.6, Xcode 26.3 (17C529), scope `compatibility`, portrait **744×1133 pt / 1488×2266 pixels**. [Environment](evidence/accessibility-attempt10/iPad18-environment.json), [summary](evidence/accessibility-attempt10/iPad18-summary.json), [точные строки лога](evidence/accessibility-attempt10/iPad18-review-test-results.txt).

**CoreAX PASS — 434.632 s; AX5 live flow PASS — 195.451 s; conference PASS — 134.474 s. Весь job — FAIL, 14 PASS / 1 FAIL из 15:** тест удаления аккаунта завершился ошибкой. Эти результаты не являются PASS всего CI10, текущего кандидата `0216c99` или всех device/runtime combinations.

## Raw findings сохранены

Финальный [stage08-accessibility-issues JSON](evidence/accessibility-attempt10/iPad18-stage08-accessibility-issues.json) содержит **21 finding; все 21 получили конкретное reviewed-решение**. Это не ноль исходных замечаний Apple. [Производный счётчик](evidence/accessibility-attempt10/iPad18-audit-counts.json) воспроизводит разбиение:

| Категория | Количество | Применённые границы |
| --- | ---: | --- |
| Partial Dynamic Type (`65536`) | 16 | Calendar weekdays 0…6 и hours 9…15 — 14; `recordings.filterHint` и `folders.subtitle` — 2. Exact IDs/subtype, независимый font-hosting test и отдельные AX5 screenshots. |
| Contrast (`1`) | 4 | Декоративный avatar «ТЕ» внутри fixture conversation; `calendar.weekday.0` / `.4` по ранее измеренным glyph cases; `saveProfile` в disabled state. |
| Text clipping (`131072`) | 1 | Exact `welcome.heading` с полным установленным label; целый heading виден на normal/AX5 PNG. |

`unresolved = 0`, незавершённых `deferred = 0`, `outside retest viewport = 0`. В этом запуске **не было deferred targets и visible contrast retests**: отсутствие таких records/PNG не доказывает исполнение retest-ветки. Все 21 записи имеют label/frame; у единственного анонимного avatar ID пустой, как и ожидается для этого reviewed case. Metadata не утеряны при snapshot. Cumulative progress counts по welcome/messages/profile/calendar/recordings/folders/settings: **1, 2, 2, 18, 19, 20, 21**; их нельзя складывать как независимые findings.

CoreAX завершил все семь экранов с новым immutable-snapshot callback. Timeout `Code=-56` в этом сценарии не повторился; это фактический результат одной конфигурации. Новый postprocessing cache для этого review не вводился; категории и predicates не ослаблялись. Правила и ограничения: [ACCESSIBILITY_POLICY](ACCESSIBILITY_POLICY.md).

## Нативные изображения

Просмотрены **7 normal-size и 16 AX5 PNG**, скопированные без crop/resize/изменения байтов. [Review manifest](evidence/accessibility-attempt10/iPad18-review-manifest.json) содержит исходные filenames, timestamps, testIdentifier и SHA-256; [оригинальный export manifest](evidence/accessibility-attempt10/iPad18-export-manifest.json) сохранён отдельно. Все PNG и raw/progress JSON остаются доступными, включая reviewed findings.

- **Normal:** [welcome](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-welcome.png) показывает полный hero и choices; [messages](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-messages.png) — весь header/search/filters и fixture row; [profile](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-profile.png) — account/actions/notification explanation до theme picker. Видимого наложения или обрезания этих надписей нет; нижние license/deletion actions в profile не показаны.
- **Normal calendar/recordings:** [calendar](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-calendar.png) показывает period, все семь weekdays и часы 09…15; поздние часы вне initial viewport. [Recordings](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-recordings.png) целиком показывает четыре cards с title/date/status, controls и retention notice. [Folders](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-folders.png) показывает весь empty-state/privacy text.
- **Normal settings:** [sidebar и profile form](evidence/accessibility-attempt10/screenshots/iPad18-stage08-accessibility-settings.png) не перекрываются; имя, email, пояснения, registration и refresh видны целиком. Save визуально приглушён и неактивен, как отражено в reviewed finding. Другие editor forms не открыты этим кадром.
- **AX5:** [messages/conversation](evidence/accessibility-attempt10/screenshots/iPad18-stage08-large-text-messages-conversation.png) содержит весь heading, row и preview. Полные даты/statuses и mode «Общий вид» / «Только аудио» видны в совокупности четырёх target-recording PNG; новая широкая карточка сохранена. [Footer](evidence/accessibility-attempt10/screenshots/iPad18-stage08-large-text-recordings-footer.png) целиком выше tab bar. Calendar target PNG 9/12/18 вместе показывают часы 09…18; initial AX5 weekdays только Пн…Пт, остальные за горизонтальным viewport не просмотрены. Settings показывает четыре section labels, но не AX5 editor; profile ниже Add account и welcome footer выходят за исходный viewport.

Новых visual blockers в просмотренных областях не найдено; слова и иконки tabs сохранены. Pixel-contrast заново не вычислялся, touch targets не измерялись по PNG. Успех CoreAX с documented exceptions не равен WCAG conformance, физическому VoiceOver acceptance или полной visual parity 21 DESIGN screen. CI11 и прочие конфигурации требуют собственных результатов.
