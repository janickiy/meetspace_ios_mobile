# CI15: визуальная проверка iPad26

Проверены **26 оригинальных PNG** из [CI15](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42281088607), исходник `55bfcfb1e075224eda9ed7106a669db0b55dd7e5`: семь основных экранов normal/AX5, дополнительные reveal-состояния и три снимка Settings. Нового перекрытия основного текста или контролов, препятствующего чтению в показанных состояниях, не обнаружено. Полная visual parity и вся accessibility-приёмка остаются **BLOCKED/PARTIAL**.

iPad Pro 13-inch (M5), iPadOS Simulator 26.2 (23C54), portrait 2064 × 2752 px, ARM runner, Xcode 26.3/17C529. AX5 задан реальным launch category `UICTContentSizeCategoryAccessibilityXXXL`. Это работающее DEBUG-приложение с изолированными fixture-данными. PNG не восстановлены из макетов и не изменены.

Suite завершился **34 PASS / 1 FAIL / 0 SKIP из 35**; failure относится к удалению аккаунта. Core accessibility (**220.497 с**), AX5 live flow (**121.054 с**) и Settings (**65.111 с**) прошли; [точный excerpt](evidence/accessibility-ci15-ipad26/test-results.txt). PASS этих тестов не превращает весь прогон в PASS и не означает ноль raw audit findings. Их отдельный разбор — в CI evidence, а здесь сохранена визуальная оценка.

Между `55bfcfb` и проверяемым в CI16 `a33a153` изменились только UI-тест, workflow и simulator runner. Product-код совпадает. Это позволяет отнести наблюдаемый внешний вид к тому же product-коду, но не подменяет полный запуск тестов на текущей ревизии.

## Основные экраны

| Экран | Оригиналы | Наблюдение и граница |
| --- | --- | --- |
| Welcome | [normal](evidence/accessibility-ci15-ipad26/normal-welcome.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-welcome.png) | Двухколоночный normal и одноколоночный AX5. Заголовок и обе основные кнопки читаются полностью. AX5 переносит «Сообщения» внутри слова; буквы не потеряны. Гостевой вход виден у нижнего края. |
| Сообщения | [normal](evidence/accessibility-ci15-ipad26/normal-messages.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-messages.png) | Normal: sidebar и пустая правая область «Выберите чат». AX5: список на всю ширину, название собеседника и subtitle читаются. Аватар показывает «…» вместо инициалов. Полное имя остаётся рядом. |
| Профиль | [normal](evidence/accessibility-ci15-ipad26/normal-profile.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-profile.png) | Normal: уведомления, appearance, licenses и удаление видны. AX5: имя/email/server и четыре ссылки навигации читаемы; начало карточки уведомлений уходит под нижнюю границу viewport. Отдельного снимка нижней части AX5 профиля нет. |
| Календарь | [normal](evidence/accessibility-ci15-ipad26/normal-calendar.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-calendar.png) | Normal: часы 09:00–18:00 читаемы. AX5: фильтр, GMT, месяц и неделя не перекрываются; поздние часы требуют прокрутки. Дополнительный снимок 18:00 подтверждает полностью видимую подпись. |
| Записи | [normal](evidence/accessibility-ci15-ipad26/normal-recordings.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-recordings.png) | Normal: четыре строки и notice читаются. AX5: фильтры и статусы разнесены, четвёртая карточка сначала у границы viewport. После прокрутки вся карточка, обновление и полный notice видны. |
| Личные папки | [normal](evidence/accessibility-ci15-ipad26/normal-folders.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-folders.png) | Оба снимка показывают пустое состояние. Кнопка создания, сортировка и пояснение приватности не накладываются; в AX5 пояснение переносится на две строки. Созданная папка/меню этим набором не проверены. |
| Настройки | [normal](evidence/accessibility-ci15-ipad26/normal-settings.png) · [AX5](evidence/accessibility-ci15-ipad26/ax5-settings.png) | Normal показывает sidebar и форму профиля; имя, email, подписи и disabled Save читаются. AX5 показывает только список четырёх разделов. Это не визуальная проверка формы профиля или уведомлений при AX5. |

## Дополнительные состояния

- [messages-conversation](evidence/accessibility-ci15-ipad26/ax5-messages-conversation.png) показывает целиком строку списка после `revealEntireText`. Диалог в этом тесте не открывается. Этот PNG нельзя выдавать за AX5-проверку сообщения, composer или клавиатуры.
- Календарь: [09:00](evidence/accessibility-ci15-ipad26/ax5-calendar-hour-9.png), [12:00](evidence/accessibility-ci15-ipad26/ax5-calendar-hour-12.png), [18:00](evidence/accessibility-ci15-ipad26/ax5-calendar-hour-18.png). В последнем кадре 18:00 целиком выше tab bar. Верхний контент при прокрутке проходит под системной navigation bar; это не обрезка самой подписи часа.
- Записи: [строка 1](evidence/accessibility-ci15-ipad26/ax5-recording-1.png), [строка 2](evidence/accessibility-ci15-ipad26/ax5-recording-2.png), [строка 3](evidence/accessibility-ci15-ipad26/ax5-recording-3.png), [строка 4](evidence/accessibility-ci15-ipad26/ax5-recording-4.png), [footer](evidence/accessibility-ci15-ipad26/ax5-recordings-footer.png). Первые три reveal-кадра сохраняют близкое положение списка; четвёртый и footer показывают целиком аудиозапись, «Обновить записи» и трёхстрочное пояснение retention/access. Фильтры в этих нижних кадрах находятся под navigation bar после прокрутки; начальный кадр отдельно показывает их полностью.
- Settings normal: [сохранённый профиль](evidence/accessibility-ci15-ipad26/settings-profile.png) содержит «Имя iOS» и «Профиль сохранён»; [уведомления](evidence/accessibility-ci15-ipad26/settings-notifications.png) показывает полные подписи, четыре включённых переключателя и выключенный push; [возможности сервера](evidence/accessibility-ci15-ipad26/settings-server.png) показывает fixture capabilities, пояснение и disabled SSH action. Соседние строки/переключатели не перекрываются. Сам PNG не доказывает сохранение после перезапуска; это отдельные assertions успешного Settings-теста.

## Touch targets и незакрытые области

У helper `openProfileFeature` на проверенном исходнике есть assertion `frame.height >= 44` для ссылок Calendar/Recordings/Folders/Settings; AX5 live flow прошёл все четыре перехода. Это ограниченное подтверждение **высоты этих navigation rows**, а не измерение ширины или всех hit regions. PNG хранит пиксели, не интерактивный frame: соответствие каждого контрола 44 × 44 pt здесь не заявляется. Новые численные размеры и контраст по уменьшенному preview не вычислялись.

В AX5 инициалам декоративных аватаров Messages/Profile не хватает места: визуально остаётся «…», при этом полное имя рядом не обрезано. На welcome «Сообщения» разрывается внутри слова. Эти наблюдения сохранены без объявления их нулём; они не скрывают основное имя или действие в показанном состоянии.

Нижняя часть AX5 профиля, внутренние формы Settings при AX5, открытый диалог, экранная клавиатура, landscape/Split View, другие размеры iPad, ручной VoiceOver/Switch Control и все состояния 21 макета этим набором не приняты. Обычное отсечение прокручиваемого контента краем viewport не считается доказанным clipping-дефектом, но и невидимый контент не получает visual PASS.

## Происхождение

[Manifest с SHA-256 всех 26 PNG, именами xcresult attachments и scope](evidence/accessibility-ci15-ipad26/manifest.json); [неизменённый полный каталог xcresult](evidence/accessibility-ci15-ipad26/xcresult-export-manifest.json); [environment](evidence/accessibility-ci15-ipad26/environment.json); [summary](evidence/accessibility-ci15-ipad26/summary.json). Каталог exporter также перечисляет вложения, не выбранные для этого review; они здесь не сохраняются. Все выбранные PNG проверены побайтово против локального CI export. Архивы, видео и raw audit attachments в эту папку не добавлялись.
