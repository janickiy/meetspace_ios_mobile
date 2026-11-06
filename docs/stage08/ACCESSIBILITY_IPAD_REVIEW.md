# iPad: визуальная проверка максимального Dynamic Type

Проверка выполнена 2026-11-06 по **семи реальным PNG**, просмотренным через `view_image`. Это доказательство видимости конкретных текстов, а не общий PASS accessibility audit и не проверка VoiceOver на физическом устройстве. UI-код в рамках этой проверки не изменялся; raw findings не удалялись.

## Происхождение доказательств

- CI2: [run 42233879641](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42233879641), source `acc193a`.
- Artifact `results-iPad26`, сценарий `testAccessibilityStage08LargeTextLiveFlow`, launch category `UICTContentSizeCategoryAccessibilityXXXL` (AX5).
- Environment JSON: [iPad26-environment.json](evidence/accessibility-attempt02/iPad26-environment.json). Он сообщает iPad Pro 13-inch (M5), iPadOS simulator 26.2, Xcode 26.3 (17C529), scope `audit`.
- Manifest: `/tmp/meetspace-stage08-ci-42233879641/results-iPad26/iPad26-screenshots/manifest.json`.
- Все PNG — **2064 × 2752 pixels**, portrait. Ниже `y` — приблизительная доля высоты полного изображения, отсчитанная сверху; это визуальные границы, **не измеренные AX frames или hit regions**.

Важно: `/tmp/iPad26-issues.json` содержит 53 записи и после JSON-декодирования **полностью совпадает** с `evidence/accessibility-attempt01/iPad26-issues.json`. Это raw **CI1**, а не новый аудит CI2. Его локальный SHA256 — `060141277c1bf4cb7a57b24959b3dd9962ecf56afda258cfdcdda82f46fb45d3` (форматирование отличается от файла в Git). В просмотренном CI2 manifest не найдено attachments с issues/progress. Поэтому документ сопоставляет CI1 findings с более поздними CI2 AX5 screenshots; он **не утверждает повторение или исчезновение findings в CI2**.

Все семь просмотренных PNG сохранены без изменений в репозитории; [manifest](evidence/accessibility-attempt02/manifest.json) связывает их имена с исходными attachment filenames и SHA256.

| Экран | Exported filename в указанной папке screenshots | SHA256 |
| --- | --- | --- |
| Welcome | `1CC5D02E-8E3C-4E8C-937D-BE60588D5419.png` | `c8066808041c8c8126d266d78371c9f7799fdfd8fd1f416ff5d393cb54f60e0a` |
| Messages | `4DA956AC-B709-4322-BF9E-438437E81EB2.png` | `929cdd5fda88ee8c77c9f3ff4123ff43baa613a23791e7d5c6b93711cdff5b34` |
| Profile | `0D6EDEED-2A65-4BC6-A562-2FBC17083D68.png` | `22debf63101fc01fbc0677fc5700462c812165cd5e0b40aa59eee5275fa529bd` |
| Calendar | `C066CCBE-CB5D-435A-A136-FA71561A8D2D.png` | `8030804889c939ae6169b379baf176db627a2b80b3fd2bbcc45bef6128e4fa44` |
| Recordings | `60C278BF-7E5B-4440-BF7D-C82BB681BBC1.png` | `f51282da6f1e06750681942536d0e980cb1e6d3b71819e6c45cb5703296dfcc7` |
| Folders | `EDAFEE20-DC93-4F69-8C49-A78B171D425A.png` | `9d8bf69b2f532f12cb3589eedbee80dd0d3b72c1d9a53fbbfa69e1e1f5f39673` |
| Settings | `E97C69E9-EE88-4207-B78D-02ADA7BC1D8C.png` | `c804e6434ac8c855e06d453112576fac765bfb74e35cefeac9c43f90f817681d` |

## Наблюдения по конкретным текстам

### Welcome

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-welcome.png).

`Команда ближе.\nИдей больше.` полностью виден примерно в области `y=0.17…0.31`: строки «Команда», «ближе.», «Идей больше.». Нет обрезанных букв, наложения соседнего текста или многоточия. Весь заголовок расположен внутри контента, далеко от нижней границы viewport. Это прямое визуальное подтверждение для узкого случая `welcome.heading + textClipped` на данном iPad/runtime/AX5.

Видны целиком бренд, «ЕДИНОЕ ПРОСТРАНСТВО», описание продукта и оба connection choice. Слово «Сообщения» в нижнем перечне функций переносится внутри слова, но его буквы видны; это менее удачная типографика, а не доказанный clipping. Доступность нижней guest action подтверждается только её видимой частью/контекстом снимка, не отдельной проверкой нажатия из этого review.

Нельзя переносить вывод о заголовке на любой `textClipped`, на brand label или на анонимный `Potentially inaccessible text`: они требуют отдельного сопоставления. Замечание contrast у «Создать пространство на своём VPS» не закрывается одной визуальной оценкой.

### Calendar

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-calendar.png).

Полностью видны:

- Заголовок «Календарь» и subtitle, примерно `y=0.08…0.16`.
- Период «Ноябрь 2026», `y≈0.29…0.32`.
- Семь weekday/day labels недели 2–8 ноября, `y≈0.35…0.43`; выбранный день 6 также показан полностью.
- Подзаголовок «6 ноября», `y≈0.46…0.49`.
- Часовые подписи **09:00–15:00**, `y≈0.55…0.92`. У видимых часов нет обрезанных нулей/двоеточий; колонка оставляет достаточно места для увеличенного шрифта.

**Не проверены** подписи 16:00 и далее: они ниже viewport. Не проверены month grid, meeting cards при наличии событий, side panel (скрыт в AX layout), альтернативные timezone/period strings. Native segmented picker показан с собственным системным оформлением; этот снимок не доказывает его полное font scaling.

В CI1 iPad26 raw list нет partial-Dynamic-Type finding, однозначно привязанного к этим часам/дням/heading: calendar partial findings относятся к словам нижних tabs. Здесь есть положительное визуальное наблюдение для конкретных текстов, но **нет основания ретроспективно приписать им другой raw finding**. Calendar contrast findings без label/ID остаются несопоставленными.

### Recordings

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-recordings.png).

Заголовок, поиск и оба menu filters видны целиком. Caption «Поиск и фильтры применяются к загруженным записям.» полностью помещается около `y=0.28…0.30`.

Все **четыре** fixture cards полностью видны, приблизительно в диапазонах `y=0.32…0.44`, `0.45…0.57`, `0.58…0.71`, `0.72…0.84`. В каждой целиком показаны название «Обсуждение проекта» и дата «6 нояб. 2026 г.». Статусы сверху вниз: «Готова», «Обрабатывается», «Не удалось записать», «Готова». Ни одна из этих строк не обрезана/не перекрыта соседней строкой. Эти наблюдения пригодны для конкретных CI1 partial-Dynamic-Type findings дат, статусов и caption при дополнении соответствующим hosted scaling evidence.

Последнее пояснение о сроке хранения начинается около `y=0.90` и продолжается **ниже нижней границы scroll viewport/за tab bar**. Полнота этого текста данным PNG не проверена. Не проверены другие названия/даты, recording detail, playback, export и содержимое ниже текущей позиции. Contrast findings статусов требуют численной проверки реальных foreground/background и сопоставления элемента; визуальный review не заменяет её.

### Folders

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-folders.png).

Целиком видны eyebrow «Личное пространство» (`y≈0.08…0.10`), subtitle «Соберите встречи и чаты в удобные папки.» (`y≈0.12…0.15`), create action, empty state и пояснение «Папки видны только вам. Удаление папки не удаляет встречи и чаты.» (`y≈0.28…0.34`, две строки). Нет обрезанных окончаний.

CI1 partial-Dynamic-Type finding относится **к eyebrow «Личное пространство»**, а не к subtitle. Эти два элемента должны иметь разные IDs/правила. Скриншот показывает пустую библиотеку: folder cards, count labels, menus и folder contents на нём **не проверены**.

### Messages

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-messages.png).

Полностью видны heading, server, connection status, search, два фильтра и одна conversation row. Текст «Переподключение…» содержит штатное многоточие в самом localized string; его наличие не доказывает truncation. Название и preview чата видны полностью. Это не проверка history/composer или списка других разговоров.

В круге decorative avatar видны точки вместо исходных инициалов. Не следует объявлять весь экран свободным от визуальной truncation на основании полноты названия чата. Avatar скрыт от accessibility и дублирует имя; замечания о нём требуют отдельного документированного решения, а не общей фильтрации text issues.

### Profile

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-profile.png).

Видны полностью heading, имя/email/server, настройки аккаунта, три feature links, heading аккаунтов, одна account row, add action и подсказка лимита. Заголовок уведомлений виден, но следующий toggle/текст начинается у нижней границы и обрезается viewport. **Не проверены** нижние notification descriptions, appearance picker, licenses и delete account action. Decorative avatar также показывает точки; этот review не утверждает полноту его инициалов.

### Settings

[Просмотренный PNG](evidence/accessibility-attempt02/screenshots/iPad26-stage08-large-text-settings.png).

При AX5 используется компактный section list; все четыре названия полностью видны, примерно `y=0.08…0.34`. Sidebar отсутствует по адаптивному правилу. **Не проверены** формы внутри этих четырёх разделов, profile input, Save, device metadata и server capabilities; данный снимок их не содержит.

## Границы будущих исключений

Снимки подтверждают только перечисленные видимые состояния. Изолированный hosted font test подтверждает масштабирование шрифта, но не снимает ограничения произвольного view. На момент этого исторического review расширенная matrix из 24 размеров/semantic styles ещё ожидала отдельного CI result. Последующие font/Core результаты — [ACCESSIBILITY_POLICY.md](ACCESSIBILITY_POLICY.md), текущий общий статус — [TEST_REPORT.md](TEST_REPORT.md); более поздним изменениям не приписывается результат старого CI.

Предлагаемые стабильные IDs — **mapping для следующего source revision**, не утверждение, что все они присутствуют в этих artifacts:

| Case | Предлагаемый ID | Допустимая узкая связь |
| --- | --- | --- |
| Welcome headline | `welcome.heading` | Exact heading + `textClipped`; этот PNG показывает полный текст на iPad26.2/AX5 |
| Calendar heading / period / selected date | `calendar.heading`, `calendar.period`, `calendar.selectedDate` | Только отдельно сопоставленное finding и соответствующий font style; без общего calendar exception |
| Week date / hour | `calendar.day.<yyyy-MM-dd>`, `calendar.hour.<HH>` | Видимые 2–8 ноября и часы 09–15; остальные не разрешать по данному review |
| Recording caption | `recordings.filterExplanation` | Exact caption + partial-Dynamic-Type subtype |
| Recording date/status | `recording.<UUID>.date`, `recording.<UUID>.status` | Четыре конкретных fixture rows; дата/status не должны совпадать только по тексту между разными строками |
| Folders eyebrow / explanatory sentence | `folders.subtitle` (строка «Личное пространство»), предлагаемый `folders.description` (строка «Соберите встречи…») | По согласованному naming `folders.subtitle` присвоен именно eyebrow; raw partial finding относится только к нему, не к explanatory sentence |

Все видимые в этих AX5 screenshots нижние tabs имеют **иконки без слов**. Следовательно, эти PNG **не подтверждают масштабирование или отсутствие clipping у возвращаемых текстовых tab labels**. Нельзя закрывать CI1 partial findings «Встречи», «Чаты», «Профиль» этими снимками; требуется новый snapshot после возврата слов.

Handler должен сохранять raw finding, ID/version сопоставленного reviewed case и ссылки на evidence. Неизвестный issue type, пустой/неоднозначный ID, другой экран/элемент, новая layout revision, runtime без проверки или missing hosted evidence остаются FAIL. Этот документ не содержит blanket exemption для `.dynamicType`, `.textClipped`, `.contrast` или всех Inter labels.
