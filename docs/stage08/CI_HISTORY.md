# История CI этапа 08

Срез: **2026-11-06 20:55 UTC**. Полный CI15 завершился97 PASS /3 FAIL из100; все failures относятся к старому helper удаления. CI16 regression завершился54 PASS /2 FAIL из56: оба iPhone14/14, оба iPad13/14, снова только deletion helper. CI17 подтвердил1/1 deletion на iPad26; остальные3 jobs отменены автором после запуска CI18, workflow CANCELLED. CI18 завершился SUCCESS: финальный deletion helper прошёл1/1 на всех4 устройствах,0 native SKIP. Product-код `55bfcfb` / `a33a153` / `163fb79` / `16c7025` одинаков. Targeted проверки не выдаются за один полный успешный suite итогового harness.

## Прогоны

`PASS/FAIL` в колонке native означает количество успешных/неуспешных тестов, включая hosted tests, если они входили в scope. Отдельно указано, где тесты намеренно не запускались. Названия matrix jobs с `full`/`compatibility` могут сохраняться при переопределённом diagnostic scope: учитывается фактически исполненная команда.

| Попытка / run | Source commit | Package и archive | Native результат и граница |
| --- | --- | --- | --- |
| [CI1 — 42228833201](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42228833201) | `25f54fb96bd8eb8b36fb6d0ce15806039a525cb1` | 176 PASS, 5 opt-in SKIP из 181; unsigned archive SUCCESS | iPhone26: 31 PASS / 2 FAIL из 33; iPad26: 30 / 3 из 33. iPhone18 и iPad18: по 10 / 2 из 12. Общий FAIL. |
| [CI2 — 42233879641](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42233879641) | `acc193a47e9f94016ff2345f76f6294f53fcb13c` | FAIL: две assertion issues в одном 30-cycle CallKit stress test; не засчитан как successful package/Release gate | Сохранённые summaries: iPhone26 и iPad26 по 13 PASS / 2 FAIL из 15; iPhone18 11 / 4 из 15. iPad18 job также FAIL; его числовой summary не включён в сохранённый локальный набор этого отчёта. |
| [CI3 — 42240106296](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42240106296) | `586bfe875355f930a5d463214bd7860a78ac189e` | 176 PASS, 5 opt-in SKIP из 181; unsigned archive SUCCESS, 59 packaging checks PASS | iPhone26: 33 PASS / 2 FAIL из 35; iPad26: 32 / 3 из 35; iPhone18: 11 / 4 из 15; iPad18: 13 / 2 из 15. Hosted tests: 10/10 PASS на каждой платформе. Общий FAIL. |
| [CI4 — 42245061917](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42245061917) | `862c4996b01b967c51fbda52b25f006c37054433` | Package отменён; нет нового successful gate | iPad26 compilation FAIL: `implicit use of 'self' in closure` в XCTest. Его summary содержит 0 исполненных тестов. Остальные jobs отменены при запуске следующей попытки; общий conclusion `cancelled`, а не PASS. |
| [CI5 — 42246539623](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42246539623) | `afea55c2700e85457ab686bf498c117732d455e8` | 176 PASS, 5 opt-in SKIP из 181; unsigned archive SUCCESS | Только deletion UI: iPhone18 и iPad26 по 0 PASS / 1 FAIL. iPhone26 и iPad18 test steps намеренно не исполнялись; зелёный job без тестов не считается проверкой этих платформ. |
| [CI6 — 42248873526](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42248873526) | `4ec80d4493dfd0e50b1bc5d96ba8267e749ef53c` | Намеренный SKIP в deletion-only scope | Только deletion UI: iPhone18 и iPad26 по 0 PASS / 1 FAIL. Два остальных simulator test steps намеренно SKIP. Новых package, archive, hosted или full-suite результатов нет. |
| [CI7 — 42252310226](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42252310226) | `c88fe5adebe7395b4f43ab51b6c6369aa95d09f5` | Package job SUCCESS | Audit iPhone18: 13 PASS / 2 FAIL из 15, 0 SKIP; не прошли core accessibility и deletion. AX5 live flow, два прежних UI сценария и 10 hosted tests прошли. iPad26 и два inventory-only jobs iPad18/iPhone26 отменены платформой до получения runner, 16:40:57–58 UTC. Общий FAIL; ошибки исполнившегося iPhone18 отделены от инфраструктурных отмен. |
| [CI8 — 42255060641](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42255060641) | `6b6d1bbda9224d459e2a07d551db65956946f2fe`, ветка `codex/stage08-intel` | 176 PASS, 5 opt-in SKIP из 181; unsigned archive SUCCESS | Audit на `macos-15-intel`: iPhone18 12 PASS / 3 FAIL из 15; iPad26 13 / 2 из 15, 0 SKIP. Обе платформы: core AX timeout `-56` и deletion FAIL со старым вводом. Дополнительно iPhone18: camera-off assertion после закрытия conference chat. Два inventory-only jobs завершены без тестов. Общий FAIL; новый input path CI9 здесь не проверялся. |
| [CI9 — 42257624204](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42257624204) | `f1eda3a79501530dd4af86830d90837816890258` | Package SUCCESS | Full workflow: iPhone/iPad 26 full suite и iPhone/iPad 18 compatibility scope. iPhone18 и iPad18: по 12 PASS / 3 FAIL из 15, 0 SKIP — core AX timeout `-56`, camera-off assertion и deletion input helper. iPad18 остановился на двух `more` keys; iPhone18 ввёл первый пароль native taps, но не нашёл `Done` по регистрозависимому label. На обеих платформах DELETE ещё не вызывался. iPhone26 и iPad26 отменены новым CI10 через workflow concurrency; общий conclusion `cancelled`. Частичные отменённые iOS26 результаты не засчитываются как PASS. |
| [CI10 — 42263390594](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42263390594) | `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe` | 176 PASS / 5 opt-in SKIP из181; package SUCCESS | iPhone18 и iPad18: по 14 PASS / 1 FAIL из15; core AX и conference PASS. iPad остановился на keyboard tutorial до DELETE; iPhone показал подтверждённый успех, но тест ждал неверный экран. iPhone26: 30 PASS / 5 FAIL из35 — core AX `-56` и четыре сценария под поздним Passwords overlay. iPad26: deadline cancellation после 27 завершённых тестов, 26 PASS / 1 FAIL; последний failure — core AX `-56`, ещё восемь UI сценариев не завершены. Общий FAIL. |
| [CI11 — 42266911539](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42266911539) | `0216c9979a5e3763fa7453fb3878de39b7df3311`, ветка `codex/stage08-final` | Package SUCCESS; отдельный локальный host suite: 179 PASS / 5 opt-in SKIP из184 | Native jobs отменены при вытеснении CI12 через workflow concurrency; они не засчитаны как coverage. Source включает локальный push-ordering patch. CI10 продолжает прежний source на другой ветке. |
| [CI12 — 42269703023](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42269703023) | `082cef8002c4c591dc594f2a13b6477d7113bda5` | Отменён; все пять jobs CANCELLED | Full workflow с guard по точному iPad tutorial text, native `ОК` dismissal и повторным поиском нужной клавиши. Вытеснен следующим кандидатом с исправленным post-deletion login assertion; успешная native проверка здесь не объявлена. |
| [CI13 — 42270899385](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42270899385) | `a052abdacaf49d05a68b17725dda0e4b096bb86e`, ветка `codex/stage08-final` | Package SUCCESS | iPad18: 13 PASS / 2 FAIL из15, 0 SKIP — core AX `-56` (186.434с) и deletion helper (119.643с), пропустивший keyboard tutorial после `more`. DELETE не достигнут. В 18:57 UTC запрошена авторская отмена superseded workflow (HTTP202) ради CI14; остальные три native jobs завершились CANCELLED; [итоговый receipt](evidence/ci-attempt13.json). Это не timeout и не runner-capacity отмена; частичные тесты не засчитаны как PASS. |
| [CI14 — 42275177048](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42275177048) | `04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f` | Package SUCCESS; 179 PASS / 5 opt-in SKIP из184; unsigned archive59checksPASS | iPhone18: 14 PASS /1 FAIL из15; deletion PASS186.676с, единственный failure — core AX. Profile elementDetection: −56 → повтор завершён; profile dynamicType: −56 → повтор получил XCTFuture1000/65с. iPad26: 10 hosted PASS; UI runner не инициализировался, 0 UI testcases. Summary synthetic failure не считается выполненным UI-тестом. iPhone26: 32 PASS /3 FAIL — после семи успешных welcome audits переход connectServer→serverURL не состоялся (причина не установлена); settings остановились под поздним Passwords sheet; deletion — на неверном scope keyboard selector до ввода пароля. iPad18:10 PASS /1 FAIL из11 завершённых тестов; Core screenshot timeout, затем AX5 runner остался ждать launch, ещё3 теста не начаты. Job CANCELLED примерно на90-минутном лимите; inference о deadline отделён от явного API conclusion. [Receipt](evidence/ci-attempt14/iPad18-receipt.json). |
| [CI15 — 42281088607](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42281088607) | `55bfcfb1e075224eda9ed7106a669db0b55dd7e5` | Package/unsigned archive SUCCESS | Оба26:34 PASS /1 FAIL из35; iPhone18:15/15 PASS; iPad18:14 PASS /1 FAIL из15. Всего97 PASS /3 FAIL из100,0SKIP. Core AX/AX5/Settings PASS на всех4; только deletion helper FAIL. [Полный baseline](evidence/baseline-ci15-provenance/receipt.json). |
| [CI16 — 42283560617](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42283560617) | `a33a153147d6941874884357134b3fd46de7532c` | 179 PASS /5 opt-in SKIP из184; archive SUCCESS,59 packaging PASS | Regression14/device, не full. Оба iPhone14/14 PASS; оба iPad13 PASS /1 FAIL. Всего54 PASS /2 FAIL из56,0SKIP. Failures только deletion helper; [итоговый receipt](evidence/ci16-final/receipt.json). |
| [CI17 — 42287121804](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42287121804) | `163fb79059dbc0d5b2fbdbc206e74e2e3cb92e86` | Намеренный SKIP, source/product не менялись | iPad26:1/1 deletion PASS259.462с. Остальные3 jobs отменены автором после нового кандидата; workflow CANCELLED. [Подтверждённый single-device receipt](evidence/account-deletion/ci17-ipad26/receipt.json), не4×1PASS. |

| [CI18 — 42288899326](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42288899326) | `16c702529f70ce675276d58f5d6334f0ba323fa7` | Намеренный SKIP; package/archive не запускаются в deletion scope | Только deletion: **4 PASS /0 FAIL /0 SKIP**, по1 тесту на каждом устройстве. Latin-layout guard → native typeText → bounded submit predicate, без binding injection. [проверенный CI18 receipt](evidence/account-deletion/final-ci18/receipt.json). |

Все simulator проверки используют DEBUG fixture dependencies. Hosted tests исполняют настоящие framework-компоненты в симуляторе. Подписанная сборка, физические устройства, APNs, системный ReplayKit и Instruments этим не подтверждены: [TEST_REPORT.md](TEST_REPORT.md), [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

## CI14: выполненный deletion flow и сбои XCTest

[iPhone18 deletion receipt](evidence/account-deletion/attempt14-iphone18.json)
сохраняет native PASS186.676с и четыре оригинальных PNG. Success screen — login
на сохранённый сервер с сообщением «Аккаунт удалён на сервере.»; форма/workspace
отсутствуют. Cancel/confirmation подтверждены test assertions и event log, отдельного
alert PNG нет. Default push intent выключен: это не проверка конкурентной регистрации.

[iPhone18 audit receipt](evidence/accessibility-attempt14/iPhone18-receipt.json),
[все22 attempt records](evidence/accessibility-attempt14/iPhone18-audit-attempts.json)
и [raw issues](evidence/accessibility-attempt14/iPhone18-raw-issues.json) показывают:

- Profile / elementDetection: attempt1 engine −56 за15.019с, 0 callbacks/findings;
  attempt2 завершился за13.062с, тоже без findings. Первый timeout не скрыт.
- Profile / dynamicType: attempt1 engine −56 за15.012с; attempt2 после2с ожидания
  получил `com.apple.dt.XCTest.XCTFuture` code1000 за65.023с, 0 callbacks/findings.
  Ошибка проброшена, testcase FAIL240.911с. Этот результат не доказывает, что
  двухсекундное ожидание восстанавливает состояние audit engine.
- Из трёх raw findings два ранее reviewed; `addAccount` contrast отложен из-за
  положения вне viewport, его собственный retest не достигнут. Только welcome/messages
  завершили все семь категорий. Profile textClipped и следующие четыре экрана не
  исполнены до результата; их доступность этим тестом не подтверждена.

[iPad26 receipt](evidence/ci-attempt14/iPad26-receipt.json) и
[исходный event excerpt](evidence/ci-attempt14/iPad26-init-events.txt) фиксируют
10/10 hosted PASS, затем `XCTDaemonErrorDomain Code=18` / `Timed out waiting for AX loaded notification`.
UI runner не инициализировался, ни один `FoundationUITests` testcase не начался.
Summary показывает10 PASS +1 synthetic infrastructure failure =11 entries;
это **0 выполненных UI testcases**, а не один неуспешный прикладной UI-сценарий.
Summary/attachments/diagnostics exports завершились, не заменяя native FAIL.
Artifact hashes и ZIP CRC обоих завершённых jobs проверены.

### CI14 iPhone26: три разных остановки UI-сценариев

[Сводный receipt](evidence/ci-attempt14/iPhone26-receipt.json),
[ограниченный native event excerpt](evidence/ci-attempt14/iPhone26-failure-events.txt)
и исходный summary подтверждают **32 PASS /3 FAIL из35**,0 SKIP.

- **Core accessibility / readiness — FAIL93.735с.** Все семь welcome categories
  завершились с первой попытки; raw progress содержит один reviewed heading finding.
  После terminate/relaunch нажатие `connectServer` не привело к появлению `serverURL`.
  Failure AX остаётся на welcome, overlay в нём не виден. Причина неприменённого
  нажатия не установлена; это не наблюдённый audit-engine timeout или новый finding.
  [Audit/readiness receipt](evidence/accessibility-attempt14/iPhone26-readiness-receipt.json),
  [семь attempt records](evidence/accessibility-attempt14/iPhone26-audit-attempts.json),
  [welcome raw progress](evidence/accessibility-attempt14/iPhone26-welcome-progress.json),
  [failure AX excerpt](evidence/ci-attempt14/iPhone26-core-readiness-AX.txt).
  Остальные шесть audit screens не достигнуты; их readiness/доступность не подтверждены.
- **Settings — FAIL115.786с.** Прямое нажатие `tab.profile` ожидало animation idle
  около60с; затем `openAccountSettings` не найден. Failure AX показывает выбранный
  Messages и системный `Save Password?` с `Not Now`/`Save`.
  [AX excerpt](evidence/ci-attempt14/iPhone26-settings-passwords-AX.txt).
  Persistence assertions не достигнуты. В CI16 этот testcase использует уже
  существующий bounded navigation helper; этот testcase прошёл на всех4 устройствах CI16.
- **Deletion — FAIL72.245с до ввода пароля.** Поле показывает placeholder без value,
  submit отключён. Реальный Button `Следующая клавиатура` находится в контейнере,
  соседнем с контейнером `Keyboard`, а lookup ограничен descendants Keyboard.
  [Точная иерархия](evidence/ci-attempt14/iPhone26-deletion-keyboard-AX.txt),
  [неуспешный query chain](evidence/ci-attempt14/iPhone26-deletion-keyboard-query.txt).
  CI16 ищет этот native button через `app.buttons`; пароль/fixture guard/production
  ввод не меняются. Это не API-отказ или подтверждённое удаление.

CI16 целенаправленно запускает **14 тестов на каждой платформе**, включая четыре
названных UI-сценария, после двух test-only исправлений. Он не подменяет полный
CI15 и не объявлен полным regression suite35/15. Исторические FAIL остаются в evidence;
неустановленная причина Core readiness не приписывается Passwords без свидетельств.

CI15 проверяет другой поддерживаемый runner pool и прекращает немедленные повторы
Dynamic Type после engine timeout. Это сохраняет fail-closed поведение; неизвестный
результат, raw finding или ошибка движка не превращаются в PASS из-за смены окружения.

## Инфраструктурная отмена CI7 и переход CI8 на Intel

В CI7 jobs iPad18 `128010330915`, iPhone26 `128010331043` и iPad26 `128010331142` завершились `cancelled` до acquisition hosted runner. Annotation: `The job was not acquired by Runner of type hosted even after multiple attempts`. Она сопровождалась сообщением об ограниченной доступности macOS arm64 runners. Исходники и тесты этих jobs не успели исполняться; такое завершение не подтверждает ошибку приложения и не засчитывается как PASS. Package SUCCESS и фактический iPhone18 FAIL (job завершён 16:45:49 UTC) учитываются отдельно.

Для CI8 выбран другой поддерживаемый pool: GitHub перечисляет `macos-15-intel` среди стандартных Intel runners для public/private repositories. [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). В опубликованном software inventory macOS 15 указаны Xcode 26.3, iOS SDK 26.2 и simulator runtimes 18.6/26.2. [Официальный macOS 15 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md). Эти сведения проверены 2026-11-06; они обосновывают выбор runner, но не заменяют environment receipt и итог конкретного запуска.

CI8 сохраняет input path CI7. Изменение profile helper касается XCTest-прокрутки в нужную сторону при сохранённом scroll offset, не подмены ввода пароля. Optional Instruments diagnostic имеет отдельный результат и не превращает неуспешный UI suite в успешный; данный отчёт не засчитывает его как успешную native приёмку. Даже полученный simulator trace не будет измерением физического устройства или его энергопотребления.

## Что исправляли и что действительно проверено

| Наблюдение | Изменение / проверка | Подтверждённый результат |
| --- | --- | --- |
| CI1: accessibility findings, отказ финального удаления после повторного ввода; iPad conference field focus | Работа с размерами и подписями элементов, фокусом; пароль подтверждения отделён от редактируемого поля | Локальная компиляция проходила. Само удаление в последующих native runs продолжало падать; гипотеза о жизненном цикле формы не доказана. |
| CI2: completion assertion проверял CallKit action сразу после media `.connected` | Stress test ограниченно ждёт фактический callback завершения, затем проверяет ровно один успешный результат, в том числе после закрытия | Три полных host suite: по 176 PASS / 5 SKIP; CI3 package PASS. Это исправление порядка наблюдения в тесте, не доказанный production resource leak. [Regression receipt](evidence/performance/completion-wait-regression.json), [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md). |
| CI2: native confirmation dialog не предоставлял ожидаемый явный Cancel action на всех платформах | Перевод подтверждения удаления на native alert с явными Cancel/Delete, сохранение снимка пароля | В CI3 iPhone18 cancellation, неверный пароль и очистка поля прошли; финальное удаление после нового ввода — FAIL. Alert не объявлен причиной оставшегося сбоя. |
| CI2/CI3: реальные layout проблемы, accessibility findings и системное Passwords окно | Исправлены обнаруженные наложения/обрезка; reviewed accessibility cases подтверждаются исходными findings, PNG и измерениями. Login helper учитывает реально наблюдаемое Passwords окно | Исторические ошибки не исключены из результатов прогонов. CI15/CI16 Core AX завершены на всех4 конфигурациях; правила и границы — [ACCESSIBILITY_POLICY.md](ACCESSIBILITY_POLICY.md), [ACCESSIBILITY_REVIEW.md](ACCESSIBILITY_REVIEW.md), [ACCESSIBILITY_IPAD_REVIEW.md](ACCESSIBILITY_IPAD_REVIEW.md). |
| CI4: escaping XCTest closures требовали явного `self` | Добавлено явное обращение к instance helper в `afea55c` | CI5 native target собрался и запустил тест. Это подтверждает устранение данной compiler error, не прохождение сценария. |
| Предположение: SecureField автоматически меняет регистр / коррекцию | Явно отключены автокапитализация и автокоррекция; добавлены только DEBUG enum diagnostics | CI5 всё ещё FAIL. Этого изменения недостаточно; причина в автокапитализации не подтверждена. |
| CI5: оба ввода уже `other` на `onSubmit` | Расширена безопасная классификация; XCTest больше не передаёт Return вместе со строкой, а нажимает настоящую клавишу Done отдельно | CI6 всё ещё FAIL; оба ввода `ascii-other` уже до alert. Отдельный Done не исправил сбой. |
| CI6: нераспознанное ASCII значение до подтверждения | CI7 и CI8 ждут существования клавиатуры и передают каждый символ отдельно; DEBUG `stage=edit` различает известные префиксы, пропуски, замены, повторы и redaction placeholder | CI7 и CI8 FAIL: обе попытки уже до alert классифицированы `known-dropped-characters`; CI7 AX показывает один mask character после полного ввода при русской клавиатуре. Ожидание клавиатуры и посимвольный `typeText` недостаточны. Production пароль не триммится, fixture guard не ослаблялся. |
| CI7: наблюдаемая русская клавиатура и потерянные Latin символы | В CI9 тест выбирает Latin раскладку наблюдаемой native globe-кнопкой `emoji` / Next keyboard, ждёт key `f` и нажимает реальные клавиши; numeric `more` используется для дефиса, затем возвращаются буквы | iPad18 остановился на двух одинаковых `more` keys. iPhone18 завершил все taps первого ввода: AX содержит 18 масок, затем lookup Done завершился FAIL. Mask count не доказывает побайтовое совпадение; DELETE ещё не отправлялся. Strict fixture guard сохранён, текст не присваивается напрямую. Временная диагностика удалена. |
| CI8 iPhone18: camera-off проверка после закрытия conference chat | Выявлено нажатие во время keyboard-dismiss/layout transition; предложено ждать исчезновения keyboard/chat перед новым camera tap | На source `6b6d1bb` line 777 тест нажал в точке `(90.55, 272.50)` pt; после окончания перехода camera frame — `(84.5, 524.0, 60.5, 62.5)` и значение осталось «Включён». Видео показывает перемещение controls во время нажатия. Media API failure не наблюдался. Последующий CI10 выполнил conference testcase на обеих iOS18 платформах; это не перенос результата на старый CI8. |
| CI9 iPad18: два зеркальных keyboard mode keys | В `0c773472c9a3a4e98b5f6e1a1a94532c01d3e5dc` используется `keyboard.keys.matching(identifier: "more").firstMatch` | Последующий CI10 прошёл этот выбор и остановился дальше на tutorial. Failure summary CI9 содержит два native Key с identifier `more`, label «цифры». Это остановка XCTest до отправки DELETE, не API-отказ и не доказательство успешного удаления. Выбирается один из эквивалентных настоящих controls; fixture guard не менялся. |
| CI9 iPhone18: Return button не найден по label | В `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe` используется наблюдаемый native identifier `Done` | В CI10 iPhone18 Done tap уже выполнен; весь testcase затем завершился ошибкой другого final assertion. Failure AX CI9 содержит Button identifier `Done`, label `done` строчными буквами; старый predicate `label IN ["Done", "Готово"]` его пропускал. [Receipt](evidence/account-deletion/attempt09.json) и [маскированный AX excerpt](evidence/account-deletion/attempt09/iPhone18-keyboard-and-masked-field.txt). |
| CI10 iPad18: после `more` отсутствует key `-` | Failure AX и видео выявили системный onboarding о доступе к альтернативным буквам, Button label `ОК` внутри Keyboard | Native `more.firstMatch` уже выполнен, но tutorial заменил обычные keys. Это не доказательство другого имени дефиса. Подготовлен точный guard по наблюдаемому tutorial text и native `ОК` tap; последующие CI13/CI15/CI16 сохранили пропуск tutorial, после чего CI18 заменил ручной цикл на native typeText при подтверждённой Latin раскладке. [Receipt](evidence/account-deletion/attempt10.json), [AX](evidence/account-deletion/attempt10/iPad18-keyboard-onboarding.txt), [кадр видео](evidence/account-deletion/attempt10/iPad18-keyboard-onboarding.png). |

CI8 core accessibility audit на обеих выбранных платформах завершился XCTest error `-56` («Audit failed to complete in time»). Это не положительный accessibility результат и не равно новому конкретному contrast finding. Все три iPhone18 failure и оба iPad26 failure сохранены в [CI8 receipt](evidence/ci-attempt08.json); AX5 live flow и legacy appearance прошли, conference-сценарий на iPhone18 — нет.

Кандидат CI10 `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe` включает исправления `more` из `0c77347` и `92357498a693f82000e3df90ac637df3e9971c5e`: сокращение работы внутри accessibility callback и ожидание завершения conference keyboard/layout transition. CI9 исполнял более старый `f1eda3a`, поэтому повторные AX/camera ошибки на нём не проверяют эти исправления. CI10 iPad18 уже подтвердил PASS core AX и conference, но deletion FAIL означает, что полный сценарий ещё не принят; результаты других платформ не предполагаются. CI9 завершился `cancelled`: iPad26 отменён в 17:38:54 UTC, iPhone26 — в 17:41:28 UTC при вытеснении новым workflow. Это не отмены CI7 до runner acquisition из-за capacity; package SUCCESS и два завершённых compatibility FAIL учитываются отдельно.

## CI10: фактический успех удаления на iPhone18 и неверный final assertion

Оба iOS18 jobs имеют исторический итог **14 PASS / 1 FAIL из15**, но разные
причины failure. На iPhone18 оба native keyboard inputs и Done taps завершились;
после второго подтверждения форма исчезла. Final AX и кадр видео +250с показывают
login, пустые поля email/password и сообщение «Аккаунт удалён на сервере.».
Fixture продолжает строго сравнивать пароль перед возвратом success.
`AppModel.sessionEnded()` явно выбирает `.login`; тест ошибочно ждал welcome
button `connectServer`. Это подтверждённый дефект итогового XCTest assertion,
а не повторный отказ пароля. [Receipt](evidence/account-deletion/attempt10-iphone18.json),
[AX](evidence/account-deletion/attempt10/iPhone18-deletion-confirmed-login.txt),
[неизменённый кадр видео](evidence/account-deletion/attempt10/iPhone18-deletion-confirmed-login.png).

Снимок `stage08-account-deletion` сделан **до** второго submit и содержит прежнюю
ошибку первой попытки; его нельзя считать финальным ответом. Обновлённый assertion
в `a052abd` проверяет login, точный success text и отсутствие формы удаления/workspace.
Последующие native результаты указаны в таблице выше. Исторический suite не переименовывается
в PASS; успех относится к synthetic fixture flow и не заменяет реальный API
probe. Core AX iPhone18 прошёл за592.715с; iPad18 — за434.632с. Conference прошёл
на обеих платформах; это не результат iOS26 и не проверка push-ordering patch.

## CI10 iOS26: поздний Passwords prompt и исчерпание времени job

iPhone26 завершил **30 PASS / 5 FAIL из35**: все 10 hosted tests прошли,
из25 UI tests не прошли core accessibility (`-56`) и четыре сценария:
accepted-on-other-device, ordinary-push opt-in, screen-conflict и account deletion.
Во всех четырёх final AX присутствует системный sheet `Save Password?` с native
`Not Now`/`Save`. В двух call-сценариях остался экран входящего звонка с кнопкой
ответа; в двух profile-сценариях выбран Messages. Нажатия не выполнили ожидаемый
переход. Deletion form и DELETE на iPhone26 не были достигнуты.
[Общий receipt](evidence/ci-attempt10.json),
[четыре AX excerpts](evidence/ci-attempt10/iPhone26-passwords-overlay-excerpts.txt).

В accepted-on-other-device видео +55с и +116с prompt отсутствует, а на +118с он
виден. Tap начинается на +56.32с; XCTest ждёт idle около60с и сообщает
`App animations complete notification not received, will attempt to continue`
на +116.42с, затем синтезирует нажатие. Такой же idle warning есть у всех четырёх
failures. Поэтому только предварительная проверка окна перед tap недостаточна.
Candidate CI14 проверяет наблюдаемый prompt и невыполненное postcondition после
действия, закрывает его native action и ограниченно повторяет нужный UI-переход.
Это не автоматический повтор backend mutation. Последующие CI15/CI16 выполнили затронутые навигационные сценарии; точный объём указан выше.
[Кадр до prompt](evidence/ci-attempt10/iPhone26-before-late-password-prompt.png),
[кадр с prompt](evidence/ci-attempt10/iPhone26-late-password-prompt.png).

iPad26 job `128050749435` остановлен **55-минутным deadline**. Завершились 27
тестов: **26 PASS / 1 FAIL**, где failure — core AX `-56`. Последний завершённый
screen-share start/stop/restart прошёл за158.568с в18:37:56 UTC. Calendar начался
в18:37:56.541; последнее сообщение — `Setting up automation session`
в18:38:00.463; job отменён в18:38:03.166. Это около6.6с следующего теста,
а не наблюдаемое зависание. Восемь UI сценариев, включая незавершённый Calendar,
не имеют итогового результата. Artifact upload после deadline прошёл.

Оценка бюджета основана на завершённых native jobs: оставшиеся восемь сценариев
заняли на iPhone26 12.20мин; отношение времени общих завершённых tests iPad/phone
1.352 даёт ориентир ещё16.49мин для iPad. С учётом полного core audit и export
обоснован bounded budget **90мин**, а75мин остаются тесными. Это оценка времени CI,
не измерение скорости или энергии приложения. Частичная отменённая серия не
превращается в полный PASS; формулы и исходные времена сохранены в общем receipt.

## CI13 iPad18: краткая проверка пропустила tutorial

Завершённый iPad18 compatibility job содержит **13 PASS / 2 FAIL из15**:
core AX `-56` и deletion helper. В deletion после native `more` краткий exact-label
lookup tutorial вернул false, после чего тест пять секунд искал только отсутствующий
key `-`. Оба собранных AX snapshots содержат единственный Keyboard, точный прежний
tutorial с тем же newline и один Button `ОК`; сравнение label со строкой исходника
совпало. На видео +110с tutorial уже виден, позднейший AX snapshot фиксирует его
в18:48:29.295. Это подтверждает пропуск состояния короткой проверкой, но не
доказывает задержку именно визуального появления или внутреннюю причину AX lag.
Первый submit/confirm/DELETE ещё не достигнут.
[Receipt](evidence/account-deletion/attempt13-ipad18.json),
[keyboard-only AX](evidence/account-deletion/attempt13/iPad18-keyboard-tutorial.txt),
[неизменённый кадр видео](evidence/account-deletion/attempt13/iPad18-keyboard-tutorial.png).

CI14 сохранял exact label и strict fixture guard, заменяя разовую проверку
ограниченным ожиданием «нужная клавиша или tutorial» до10с. Это исторический кандидат; его итог указан выше;
CI13 не подтверждает прохождение account deletion на iPad. Запрос отмены оставшихся
CI13 jobs в18:57 UTC сделан автором работы для нового кандидата, не GitHub deadline.

## Локальная проверка push ordering перед CI11

В commit `0216c9979a5e3763fa7453fb3878de39b7df3311` очередь push mutations
останавливается и дожидается прежних операций до DELETE. Три новых теста проверяют
порядок позднего POST/revoke/DELETE, допустимость DELETE после failed revoke,
сохранение journal до200, восстановление прежнего enabled intent при422/409/503/
timeout без permission prompt, запрет восстановления после disable или смены
server/user scope. Локальный focused run: **11/11 PASS**; полный host suite:
**179 PASS / 5 opt-in SKIP из184**. [Receipt с source hashes и safe test logs](evidence/account-deletion/push-ordering/receipt.json).
Все восемь source hashes receipt сверены с committed `0216c99`; первоначально
receipt записан до commit и честно сохраняет `workingTreeDirty: true`.

Это macOS SwiftPM с контролируемыми transport/APNs doubles. Native CI11 отменён;
полная native приёмка patch и доставка APNs не подтверждены. CI10 не включает patch. Серверная гонка уже авторизованной
записи другого клиента или запроса с потерянным ответом остаётся отдельным OPEN P2,
см. [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

## Граница доказательств по вводу пароля

[CI5 receipt](evidence/account-deletion/attempt05.json) и [CI6 receipt](evidence/account-deletion/attempt06.json) сохраняют только enum traces и hashes исходных attachments. Сами пароли, их длины и hashes паролей не сохранялись. Hash в receipt относится к файлу evidence, а не к введённому значению.

В CI5 последовательность для обеих попыток: `submit=other`, затем `prepare=other`, `confirm=other`, `transport=other`. В CI6 на iPhone18 и iPad26 на этих этапах получено `ascii-other`. Это доказывает, что неверное значение уже существовало **до alert**. Совпадение категории на разных этапах **не доказывает побайтовое равенство** значений.

В serialized synthesized events CI6 запрошенные XCTest строки совпадали с известными valid/invalid fixtures без LF. Вход модели на `onSubmit` при этом не совпал с ними. Таким образом, подтверждённая граница расследования — передача запрошенного текста через native input в SecureField binding. Это ещё не доказывает, что неисправен только fixture или только XCTest, и не исключает production UI-дефект. Успешные unit и реальные backend проверки [ACCOUNT_DELETION.md](ACCOUNT_DELETION.md) не заменяют этот native UI-сценарий.

В app stdout есть RTI-предупреждения о невалидной input session для `UIEmojiSearchOperations` перед вводом. Они зафиксированы как наблюдение; причинная связь с изменённым паролем не установлена. Содержимое secure field намеренно не восстанавливается по изображению: iOS скрывает его при захвате.

**CI7 уточнил характер потери ввода.** [Receipt](evidence/account-deletion/attempt07.json), [enum trace](evidence/account-deletion/attempt07/iPhone18-trace.txt), [минимальный AX excerpt](evidence/account-deletion/attempt07/iPhone18-keyboard-and-masked-field.txt) и [кадр перед вводом](evidence/account-deletion/attempt07/iPhone18-keyboard-before-input.png) привязаны к исходным attachments hashes. Видео показывает русскую ЙЦУКЕН; AX globe button имеет identifier `emoji`, label «Следующая клавиатура», value `English (UK)`. Все 18 и 16 отдельных XCTest событий соответствуют символам двух известных synthetic fixtures. После каждого полного ввода AX отображает ровно один скрытый символ. Единственное непустое `stage=edit` в каждой попытке — `known-dropped-characters`; та же категория наблюдается на submit/prepare/confirm/transport, а после подтверждения поле очищается.

Первое непустое изменение — 16:43:27.377092 UTC при requested hyphen event с attachment timestamp 16:43:27.570; второе — 16:43:50.390399 при hyphen attachment 16:43:50.593. Это сильно поддерживает объяснение, что при Latin `typeText` на русской secure keyboard вводится только дефис. **Сам сохранённый символ не логировался; этот вывод остаётся inference по таймингу, а не чтением пароля.** Запущенный CI9 использует только native UI: переключение наблюдаемой globe-кнопкой на English, проверку key `f` и реальные `key.tap()` с native numeric/letter переключением; он ещё не засчитан как успешный. Production keyboard и проверка пароля на сервере не меняются. Enum traces выше — исторические evidence CI5–CI8; в исходнике кандидата `f1eda3a` временной диагностики уже нет.

## Источники истории

- CI1/CI2: сохранённые `run.json`, `jobs.json`, package/simulator logs и доступные `*-summary.json` в `/tmp/meetspace-stage08-ci-<runID>/`. Числа CI1 iOS26 получены из отдельных итогов 9 hosted tests и 24 UI tests; для iOS18 есть summaries. Локальные временные файлы не являются бессрочным опубликованным архивом; run links выше указывают на оригинальные jobs.
- CI3: [receipt с четырьмя summaries и artifact digests](evidence/accessibility-attempt03/ci-attempt.json), [iPhone26 summary](evidence/accessibility-attempt03/iPhone26-summary.json), [iPad26 summary](evidence/accessibility-attempt03/iPad26-summary.json), [iPhone18 summary](evidence/accessibility-attempt03/iPhone18-summary.json), [iPad18 summary](evidence/accessibility-attempt03/iPad18-summary.json).
- CI4: сохранённые compiler logs и `run.json`/`jobs.json` в `/tmp/meetspace-stage08-ci-42245061917/`; отсутствующий тестовый результат не засчитан как PASS.
- CI5/CI6: receipts и enum-only traces в [evidence/account-deletion](evidence/account-deletion/). Источником служат `StandardOutputAndStandardError-com.meetspace.ios.txt` из exported xcresult diagnostics. Отдельный `*-fixture-diagnostics.txt` от `simctl log show` оказался пустым; он не использован как подтверждение отсутствия событий.
- CI7: [минимальный receipt с hashes исходного summary, app stdout, видео и retained evidence](evidence/account-deletion/attempt07.json); `run.json`/`jobs.json` в `/tmp/meetspace-stage08-ci-42252310226/`, annotation трёх инфраструктурных отмен. Сохранён mask count только известного synthetic input, без реального пароля.
- CI8: [receipt с фактическими summaries, историческим enum trace и conference transition evidence](evidence/ci-attempt08.json), исходные `run.json`/`jobs.json` и ZIP attachments в `/tmp/meetspace-stage08-ci-42255060641/`. Summary/app-output/video/event hashes привязаны к старому `6b6d1bb`; результат не переносится на CI9.
- CI9: [receipt двух завершённых compatibility jobs и безопасный AX excerpt](evidence/account-deletion/attempt09.json); исходные summaries и attachments в `/tmp/meetspace-stage08-ci-42257624204/results-iPhone18/` и `results-iPad18/`. По 12 PASS / 3 FAIL относятся к `f1eda3a`, не к CI10. Сохранены только маски поля известного synthetic input и native keyboard metadata, без значения пароля.
- CI10: [общий receipt](evidence/ci-attempt10.json) с завершённым iPhone26 и частичным deadline-cancelled iPad26; [iPad18 receipt](evidence/account-deletion/attempt10.json) и [iPhone18 receipt](evidence/account-deletion/attempt10-iphone18.json) с summary/AX/video hashes. Source `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`, итог workflow FAILURE.
- CI11: full dispatch `42266911539` на `0216c9979a5e3763fa7453fb3878de39b7df3311` в `codex/stage08-final`; package SUCCESS, native jobs отменены CI12 и не засчитаны как coverage. Локальный [push-ordering receipt](evidence/account-deletion/push-ordering/receipt.json) также не заменяет native CI.
- CI12: full dispatch `42269703023` на `082cef8002c4c591dc594f2a13b6477d7113bda5`; исправляет observed iPad keyboard tutorial. Все5 jobs завершились CANCELLED; это не успешный тестовый результат.
- CI13: full dispatch `42270899385` на `a052abdacaf49d05a68b17725dda0e4b096bb86e`; [iPad18 receipt](evidence/account-deletion/attempt13-ipad18.json) сохраняет13 PASS /2 FAIL и keyboard evidence. Package SUCCESS; в18:57 UTC запрошена отмена оставшихся jobs, без предположения их результатов.
- CI14: full dispatch `42275177048` на `04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f`,18:56 UTC; iPhone18 14 PASS /1 FAIL (deletion PASS), iPhone26 32 PASS /3 FAIL; iPad26 10 hosted PASS /0 UI executed и runner initialization failure. iPad18 CANCELLED после10 PASS /1 FAIL завершённых тестов; [receipt](evidence/ci-attempt14/iPad18-receipt.json).
- CI15: full dispatch `42281088607` на `55bfcfb1e075224eda9ed7106a669db0b55dd7e5`,19:36 UTC; ARM simulator pool/max-parallel2; итог97 PASS /3 FAIL из100, [baseline receipt](evidence/baseline-ci15-provenance/receipt.json).

Полная текущая визуальная приёмка также не объявляется завершённой: [VISUAL_REVIEW.md](VISUAL_REVIEW.md).

- CI16: regression dispatch `42283560617` на `a33a153147d6941874884357134b3fd46de7532c`, ветка `codex/stage08-regression`; 14 тестов ×4платформы, не full. Итог54 PASS /2 FAIL из56; [receipt](evidence/ci16-final/receipt.json).
