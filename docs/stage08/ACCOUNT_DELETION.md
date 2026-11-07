# Удаление аккаунта в приложении

В профиль добавлено отдельное необратимое действие «Удалить аккаунт на сервере»: пароль текущего аккаунта, предупреждение о сохранении анонимной общей истории и второе подтверждение. Подтверждение реализовано нативным alert с явной отменой на iPhone и iPad. При открытии alert сохраняется снимок введённого пароля: изменение жизненного цикла формы не подменяет подтверждённый запрос. Обычный выход с устройства остаётся самостоятельным действием. Пароль не записывается в настройки, журнал или Keychain; состояние поля очищается при подтверждении и закрытии формы.

## Дополнение P2 от 7 ноября 2026 года

Исходник iOS: `5c4e3dcf49c64ab28b55231c5c02da16dca377b0`. После DELETE200
подтверждение точной пары `origin + userID` сохраняется в отдельном защищённом
Keychain ledger до очистки push-журнала. Сбой записи journal теперь допускает
повторную очистку после перезапуска, без активного аккаунта и без нового DELETE.
`IdentityModel` не восстанавливает подтверждённо удалённый аккаунт из оставшихся
credentials/index, включая offline-путь. Другие scopes сохраняются; 401 и
неизвестный результат не создают подтверждения. Если все durable-записи не удались
и процесс завершился, неизвестная привязка остаётся заблокированной.

В этот iOS-репозиторий также включён серверный patch, который согласует блокировки
`SaveDevice` и `DeleteAccount` и проверяет действующий аккаунт перед UPSERT.
Независимое применение к pinned backend и проверка на PostgreSQL дали **9/9 PASS**
с `-race`; [receipt](evidence/p2-backend-reproduction/receipt.json).
**Patch ещё требуется интегрировать и выпустить на backend**: его присутствие
в iOS-репозитории не означает изменения работающего сервера.

Локально: **38/38 focused PASS**, полный пакет **193 PASS / 5 opt-in SKIP из 198**;
[команды и hashes](evidence/p2-local/receipt.json). Новый
[CI42326199451](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42326199451)
завершён: scope `push-recovery`, **52/52 native PASS**, 0 FAIL/SKIP,
по 11 hosted + 2 UI tests на четырёх конфигурациях; [receipt](evidence/p2-ci/receipt.json).
Package завершён с теми же 193 PASS / 5 SKIP; независимая проверка нового unsigned
archive дала **59 PASS + signing.distribution BLOCKED**
([receipt](evidence/p2-release-product/receipt.json)). Полная семантика восстановления,
границы и текущая приёмка описаны в [P2_FIXES.md](P2_FIXES.md).

Аудиты и CI1–CI18 ниже сохранены как история прежних исходников. Их результаты
не переносятся на новый product source; прежний OPEN P2 серверной гонки относится
к backend без опубликованного patch.

## Исправление прежнего вывода аудита

У backend уже есть защищённый `DELETE /api/v1/auth/me`. Его отсутствие в прежних описаниях возможностей iOS было пропуском аудита, а не отсутствием серверного маршрута. Маршрут найден и в исходном Stage3/Stage7 checkout `0bd1248a2411842515af4e02f1e95821616748fb`, и в актуальном Stage8 `9e6058c31cc07bff0f48d8f7f6a40106c55c4881`. Backend не изменён.

Источники backend: `internal/transport/http/platform_routes.go`, `internal/app/auth/accounts.go`, `internal/usecase/auth/accounts.go`, `internal/infrastructure/postgres/account_repository.go`. Важно учитывать HTTP mapping ошибок: фактический неверный пароль даёт **422**, хотя usecase возвращает общий `ErrInvalidInput`. Это проверено реальным одноразовым сервером, см. [API_CONTRACT.md](API_CONTRACT.md).

## Контракт и результат

Запрос содержит bearer выбранного аккаунта и JSON `{"password":"…"}`. Идентификатор пользователя берётся сервером из авторизации; клиент не передаёт другой user ID или cookie. Единственный подтверждённый успех — HTTP200 и JSON `status: "success"`.

| Ответ | Поведение приложения |
| --- | --- |
| 400/422 | Пароль отклонён; аккаунт, работающий клиент и локальные данные сохранены |
| 401/403 | Удаление отклонено; этот ответ не запускает refresh/replay и не объявляет прежнюю сессию завершённой |
| 409 | Предложено завершить звонки, закрыть свои встречи и передать владение групповыми чатами |
| 404/405/501 | Сервер не поддерживает действие |
| Ошибка связи, 5xx, неподтверждённый HTTP200 | «Удаление не подтверждено»; локальный аккаунт сохранён, результат сервера не угадывается |

Скоро истекающий access token обновляется **до** отправки DELETE. Сам DELETE автоматически не повторяется: у маршрута нет ключа идемпотентности. Даже если параллельный фоновый GET уже увидел отзыв сессии, полученный затем подтверждённый DELETE200 остаётся успехом. На время операции блокируются повторное удаление, переключение аккаунтов и локальные действия начала/ответа звонка. Уже активный звонок или подключённая встреча не позволяют начать удаление; дополнительная серверная проверка 409 покрывает внешние изменения состояния.

Перед DELETE приложение останавливает новые OS token callbacks и дожидается прежних операций своей push-очереди, пока credentials ещё действуют. Подготовка сохраняет journal и прежний enabled intent; ошибка предварительного revoke сама по себе не блокирует authoritative DELETE. При отказе или неизвестном результате scoped token разрешает восстановление только прежнего **server + userID + epoch**, без нового permission prompt. Явное выключение уведомлений или смена scope отменяет право такого восстановления. Если cleanup/разрешение по-прежнему недоступны, intent сохраняется, но регистрация не объявляется восстановленной.

После подтверждения закрываются модели, WebSocket/медиа/звонки и загрузчик записей; закрытие клиента дожидается записи refresh, чтобы она не восстановила уже удалённые credentials. Удаляются ключ credentials, индекс и каталог временных файлов только выбранной пары **server + userID**. Только после server200 забывается соответствующий scope локального push-журнала; другие записи сохраняются. Ошибка локального хранилища показывается отдельно и не превращает подтверждённое удаление на сервере в предложение повторить DELETE.

Эта очередь упорядочивает завершённые операции данного клиента. Она не сериализует другой клиент и не доказывает завершение серверного запроса с потерянным ответом. Backend может сохранить поздний `SaveDevice` у tombstone-пользователя после DELETE: внешняя транзакционная гонка остаётся **OPEN P2**, подробности и необходимые серверные условия приведены в [SECURITY_AUDIT.md](SECURITY_AUDIT.md#p2-регистрация-push-одновременно-с-удалением-аккаунта). Backend не изменён; глобальная гарантия удаления всех конкурентных push-привязок не заявляется.

Сервер отзывает сессии, очищает личные настройки и связанные личные данные. Общие сообщения/встречи могут сохранить анонимного автора при ссылочной зависимости, поэтому UI не обещает физического удаления всей общей истории. Экспортированные пользователем копии файлов находятся вне временного каталога приложения. Настройки представления календаря (режим/часовой пояс) не содержат содержимого аккаунта и не входят в очистку существующего механизма выхода.

## Проверки

Первый сфокусированный прогон SwiftPM (снимок исходников указан в receipt): **8/8 PASS**, сборка 12.74с, тесты 0.052с. [Receipt и source hashes](evidence/account-deletion/receipt.json), [вывод тестов](evidence/account-deletion/focused-tests.txt). Проверены одиночный запрос и предшествующий refresh; 400/422/401/403/409/405 без replay; неизвестные результаты; пустой/слишком длинный пароль; подтверждённый результат при параллельном отзыве сессии; сохранение второго аккаунта с тем же UUID на другом сервере; удаление своего временного файла при сохранении чужого; закрытие моделей/загрузок; блокировка конкурентных identity mutations; завершение опоздавшей push-регистрации до очистки scoped journal.

Дополнительное исправление push-порядка проверено на рабочем снимке поверх `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`: **11/11 focused PASS**; полный пакет **184 tests: 179 PASS / 5 opt-in SKIP**. [Новый receipt, команды и source hashes](evidence/account-deletion/push-ordering/receipt.json), [focused excerpt](evidence/account-deletion/push-ordering/focused-tests.txt), [full-suite excerpt](evidence/account-deletion/push-ordering/full-suite.txt). Три новых теста проверяют delayed POST → revoke → DELETE через production IdentityModel/API; failed revoke с сохранением journal до200; enabled/off × 422/409/503/timeout с восстановлением без prompt/replay; отклонение чужого origin и устаревшего pause token после disable/switch. В тестах controlled transport и platform doubles; это не воспроизведение серверной транзакционной гонки. CI14 ниже подтвердил native iPhone18 UI-поток на исходнике с этим исправлением. Его push intent по умолчанию выключен, поэтому успешный UI-сценарий не выдаётся за нативную проверку конкурентных push-ветвей.

Отдельный настоящий backend-прогон подтвердил 422 неверного пароля с сохранением сессии, 409 владельца запланированной встречи, 200 после отмены встречи, отзыв двух bearer/двух refresh cookies и отказ нового входа, сохранение другого аккаунта, папок и notification preferences. Подробные сетевые evidence принадлежат [API_CONTRACT.md](API_CONTRACT.md).

UI IDs: `openDeleteAccount`, `deleteAccount.password`, `deleteAccount.submit`, `deleteAccount.confirm`, `deleteAccount.cancelConfirmation`, `deleteAccount.error`. DEBUG fixture использует `fixture-password`; предусмотрены явные сценарии `-delete-account-conflict` и `-delete-account-unconfirmed`. Эти doubles не проверяют production TLS или серверное хранение. Итог iPhone/iPad UI и hosted Keychain-проверок учитывается отдельно в общем отчёте CI; локальный SwiftPM не заменяет их.

## CI14: подтверждённый native iPhone18 UI-поток

В [CI14 `42275177048`](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42275177048),
source `04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f`,
`testStage08AccountDeletionRequiresPasswordAndConfirmation` прошёл за **186.676 с**
на iPhone SE, iOS 18.6. [Receipt](evidence/account-deletion/attempt14-iphone18.json)
связывает source hashes, GitHub artifact digest, четыре оригинальных PNG и
[native event excerpt](evidence/account-deletion/attempt14/iPhone18-events.txt).

Проверены пустое поле/disabled submit, отмена подтверждения, отказ неверного
пароля с очисткой поля и повторный native ввод правильного fixture-пароля.
[Retry PNG](evidence/account-deletion/attempt14/iPhone18-stage08-account-deletion-keyboard-retry.png)
показывает читаемую ошибку и пустое поле. После повторного подтверждения
[success PNG](evidence/account-deletion/attempt14/iPhone18-stage08-account-deletion-success.png)
показывает вход на сохранённый сервер и точное сообщение «Аккаунт удалён на сервере.»;
формы удаления и workspace tabs нет. Строгий fixture guard сохранён.
Отдельного alert PNG в успешном тесте нет: cancellation/confirmation подтверждены
assertions и event log, но отдельная визуальная приёмка alert не заявляется.

Вся iPhone18 job при этом **FAIL: 14 PASS / 1 FAIL из15** — единственная ошибка
относится к движку core accessibility audit. UI-проверка использует DEBUG doubles,
не подтверждает production TLS, настоящий DELETE на сервере, APNs delivery или
задержанную регистрацию push. Реальный API проверен отдельно выше.
У CI14 iPad26 UI runner не инициализировался: **0 UI testcases выполнено**;
успех удаления на iPad из этого job не выводится.

## История native UI-проверки ввода

CI7 `42252310226`, source `c88fe5adebe7395b4f43ab51b6c6369aa95d09f5`: iPhone18 audit завершился **13 PASS / 2 FAIL из 15**. Сценарий удаления снова не дошёл до welcome после правильного requested input. Cancel, обработка отказа и очистка поля после подтверждения прошли; весь сценарий удаления **не считается успешным**. Отдельный core accessibility failure и runner-capacity отмены других jobs описаны в [CI_HISTORY.md](CI_HISTORY.md).

Для обеих попыток DEBUG trace уже на первом непустом изменении SecureField содержит `known-dropped-characters`, до открытия alert. Такой же enum наблюдается на submit/prepare/confirm/transport; совпадение категорий не является доказательством побайтового равенства. Serialized XCTest events содержат все отдельные символы двух известных synthetic fixtures, а native AX после полного ввода показывает **один скрытый символ**. На видео активна русская ЙЦУКЕН; globe-кнопка предоставляет следующую `English (UK)`. [Receipt и hashes](evidence/account-deletion/attempt07.json), [AX excerpt](evidence/account-deletion/attempt07/iPhone18-keyboard-and-masked-field.txt), [enum trace](evidence/account-deletion/attempt07/iPhone18-trace.txt), [неизменённый кадр перед вводом](evidence/account-deletion/attempt07/iPhone18-keyboard-before-input.png).

Единственное непустое изменение каждого ввода совпадает по времени с requested hyphen event. Наиболее поддержанное объяснение — потеря Latin букв при XCTest `typeText` на русской secure keyboard с сохранением одного дефиса. Сам символ не сохранялся в журнале; это **вывод по корреляции**, пока не доказанное внутреннее поведение UIKit. Повторять ожидания или менять alert на основании этих данных не требуется.

В [CI9 `42257624204`](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42257624204), source `f1eda3a79501530dd4af86830d90837816890258`, XCTest выбирает реальную Latin клавиатуру через наблюдаемый globe control `emoji` / Next keyboard, ждёт key `f` и нажимает сами клавиши. Для дефиса используется native numeric key `more`, затем возврат к буквам. Прямого присвоения пароля и ослабления fixture guard нет; production клавиатура не переключается тестовым обходом.

CI9 iPhone18 и iPad18 завершились каждый с **12 PASS / 3 FAIL из 15**; deletion-сценарий на обоих остановился **до отправки DELETE**. На iPad18 single-element lookup нашёл два зеркальных native `more` keys. На iPhone18 все клавиши первого ввода были нажаты, AX показывает 18 масок вместо одного символа в CI7; это подтверждает изменение результата ввода, но не побайтовое совпадение пароля. Затем тест не нашёл Return button: фактический identifier — `Done`, label — `done`, а старый регистрозависимый predicate искал labels `Done`/`Готово`. [Receipt и source hashes](evidence/account-deletion/attempt09.json), [безопасный AX excerpt](evidence/account-deletion/attempt09/iPhone18-keyboard-and-masked-field.txt). Значение пароля не экспортируется; успех strict fixture guard ещё не проверен этим запуском.

В [CI10 `42263390594`](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42263390594), source `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`, iPad18 завершился с **14 PASS / 1 FAIL из15**. Core AX и conference прошли, единственный failure — deletion. Выбор одного mirrored `more` через `.firstMatch` выполнен; затем появился native iPad keyboard tutorial: «Для доступа к альтернативным буквам на клавиатуре\nпотяните вниз на клавише и отпустите.». Он заменил обычные keys, поэтому поиск `-` не завершился. AX содержит один Button label `ОК` (U+041E U+041A) внутри Keyboard, без identifier; дочерний StaticText имеет тот же label. Это не подтверждение другого символа или имени дефиса. [Receipt](evidence/account-deletion/attempt10.json), [точный AX excerpt](evidence/account-deletion/attempt10/iPad18-keyboard-onboarding.txt), [неизменённый кадр видео](evidence/account-deletion/attempt10/iPad18-keyboard-onboarding.png).

Сценарий CI10 iPad18 остановился на первом вводе до submit/confirm/DELETE. Строгая проверка fixture не менялась и не была достигнута. Исправление тестового helper должно распознавать именно наблюдаемый tutorial и нажимать его native `ОК`, затем повторно искать нужную клавишу; на этом историческом этапе успешной проверки ещё не было. CI13/CI15/CI16 не подтвердили этот guard, текущая замена описана в разделе CI18 ниже. Оставшиеся iPhone26/iPad26 jobs CI9 отменены новым запуском через workflow concurrency; общий CI9 conclusion `cancelled`, package SUCCESS. Частичные отменённые результаты не засчитаны как PASS; это не runner-capacity отмена CI7.

CI10 iPhone18 также имеет исторический итог **14 PASS / 1 FAIL**, но сам
synthetic deletion flow достиг подтверждённого успеха. После обоих native inputs
и второго подтверждения final AX и видео показывают login с пустыми полями,
`authenticationSubmit` и сообщением «Аккаунт удалён на сервере.»; формы удаления
уже нет. Strict fixture guard не ослаблялся и был пройден. Причина единственного
failure — ожидание welcome `connectServer`: существующий
`AppModel.sessionEnded()` выбирает `.login`. [Receipt и source hashes](evidence/account-deletion/attempt10-iphone18.json),
[безопасный final AX](evidence/account-deletion/attempt10/iPhone18-deletion-confirmed-login.txt),
[неизменённый final video frame](evidence/account-deletion/attempt10/iPhone18-deletion-confirmed-login.png).
Пред-confirm PNG с прежним сообщением неверного пароля был снят до второго submit
и не является его итогом. Исправление теста проверяет login, точное сообщение
успеха и отсутствие формы/workspace; собственный native результат получен в CI14 выше.
Исторический suite остаётся FAIL, production TLS/реальный сервер этим UI не проверены.

CI10 iPhone26 завершился с **30 PASS / 5 FAIL из35**. Deletion-сценарий здесь
остановился ещё при переходе из Messages к profile entry: final AX содержит
системный sheet `Save Password?` с native `Not Now`/`Save`, Messages остаётся
выбранным. Форма удаления и DELETE не достигнуты. Тот же поздний prompt виден
в трёх других failures; это отдельная причина от успешного iPhone18 flow.
На iPad26 job достиг55-минутного deadline во время следующего Calendar test
после27 завершённых tests (26 PASS /1 FAIL); deletion не исполнялся до результата.
Эти результаты не засчитаны как успешная native приёмка удаления.
[Общий receipt и четыре безопасных AX excerpts](evidence/ci-attempt10.json),
[разбор времени и prompt](CI_HISTORY.md#ci10-ios26-поздний-passwords-prompt-и-исчерпание-времени-job).

В CI13 `42270899385`, source `a052abdacaf49d05a68b17725dda0e4b096bb86e`,
iPad18 завершился с **13 PASS /2 FAIL из15**. Deletion снова остановился до
первого submit: после `more` односекундный lookup tutorial вернул false, затем
helper искал только отсутствующий `-`. Actual AX содержит единственный Keyboard,
точно прежний текст tutorial включая newline и один Button `ОК`. На video +110с
tutorial уже виден; позднее собранный AX snapshot фиксирует его в18:48:29.295.
Таким образом, подтверждён пропуск состояния короткой проверкой, а не изменение
label; задержка визуального появления и точный внутренний механизм AX не доказаны.
[Receipt](evidence/account-deletion/attempt13-ipad18.json),
[keyboard-only AX](evidence/account-deletion/attempt13/iPad18-keyboard-tutorial.txt),
[кадр видео](evidence/account-deletion/attempt13/iPad18-keyboard-tutorial.png).

Исторический candidate CI14 `42275177048` на
`04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f` запущен18:56 UTC. XCTest ждёт
нужную клавишу **или** точный observed tutorial до10с и учитывает позднее системное
Passwords окно после невыполненного UI-перехода. Строгий пароль fixture и
production ввод не меняются. iPhone18 deletion PASS описан выше; общий job FAIL
из-за accessibility engine. В18:57 UTC запрошена
авторская отмена оставшейся CI13 работы ради нового кандидата; такие незавершённые
результаты не являются timeout приложения или successful coverage.

Полный CI15 `42281088607`, source `55bfcfb1e075224eda9ed7106a669db0b55dd7e5`,
повторяет матрицу на ARM simulator runners с максимум двумя параллельными jobs.
Отдельный CI16 `42283560617` проверяет `a33a153147d6941874884357134b3fd46de7532c`
в scope regression (14 тестов на каждом из четырёх устройств), не full.
CI14 iPhone26 остановился до ввода пароля: globe-кнопка оказалась соседним
элементом Keyboard, а helper искал её внутри Keyboard. В a33a153 исправлена
область поиска на `app.buttons` при сохранении точного наблюдаемого selector.
[Receipt и AX evidence](evidence/ci-attempt14/iPhone26-receipt.json).
Production-код удаления не менялся; последующие scoped native результаты приведены ниже.

Начиная с `f1eda3a` полностью удалены временные enum diagnostics во view/fixture и пустой `simctl log show` dump в CI runner. Сохранённые traces и mask-count evidence выше — исторические наблюдения только известных synthetic fixtures на одноразовом симуляторе с `-uitesting`; пользовательские пароли не журналировались. CI9 также содержит отдельные AX/layout изменения PageHeader, messages scrolling и записей; успешная общая приёмка ими не объявлена. CI8 на `6b6d1bb` завершился FAIL с прежним input path на iPhone18 и iPad26: обе попытки удаления по-прежнему классифицированы `known-dropped-characters`. [CI8 receipt](evidence/ci-attempt08.json). Это не результат нового native-keyboard сценария CI9 или исправлений CI10.

## CI15–CI17: отдельная клавиша iPad abc

CI15 iPhone26 и iPad26 завершились34 PASS /1 FAIL из35; CI16 iPad26 —13/14.
В обоих iPad видео виден цикл RU → Emoji → RU → Emoji → RU. Final AX содержит
отдельную видимую клавишу abc с label `Переключиться с латинских клавиш`; она не
нажималась. Это не доказательство отсутствия установленной английской клавиатуры:
меню языков и Settings не открывались. [CI15 receipt](evidence/ci-attempt15/receipt.json),
[CI16 AX](evidence/ci-attempt16/iPad26-keyboard-AX-excerpt.txt).

В `163fb79` при отсутствии f helper сначала нажимает эту exact key и ограниченно
ждёт f. Если f не появился, тест завершается ошибкой. На клавиатурах без этого
контрола сохранён прежний native language switch. Production ввод и строгие fixture
пароли не менялись. CI17 `42287121804` завершил iPad26 **1/1 PASS**259.462с;
остальные3 jobs отменены автором после CI18. [Single-device receipt](evidence/account-deletion/ci17-ipad26/receipt.json) сохраняет проверенные ZIP/source/digest/CRC и4оригинальных PNG. Package намеренно SKIP; это не полный успешный workflow.

## Последующий native ввод CI18

CI17 iPad26 job прошёл: выбор наблюдаемой abc клавиши позволил завершить сценарий.
Остальные jobs superseded CI17 отменены автором; их отсутствие не считается PASS.
В полном CI15 iPad18 Latin letters уже вводились; после `more` tutorial был виден
на видео внутри10с ожидания, но exact StaticText query его не нашёл. Final AX имеет
ровно один Keyboard, ожидаемый StaticText с полностью совпадающим87-символьным
label и один native ОК. Поэтому wrong label/ancestry или простая нехватка timeout
не заявлены доказанной причиной. [Сохранённый разбор](evidence/ci15-ipad18/receipt.json).

`16c7025` использует стандартный `password.typeText(value)` после подтверждения
Latin f, затем ограниченно ждёт enabled submit и нажимает native Done. Это ввод
через настоящий SecureField; injection в binding/fixture отсутствует. Неизменные
assertions проверяют cancel, неверный пароль с очисткой поля/сохранностью аккаунта,
повтор правильного пароля и возврат к server login. Появление f само по себе не
доказывает приём текста: пропущенный ввод должен дать обычный FAIL.
CI18 `42288899326`, source `16c702529f70ce675276d58f5d6334f0ba323fa7`,
завершился **4/4 PASS**, без native FAIL/SKIP. По одному точному deletion testcase:

| Симулятор | Runtime | Длительность testcase |
| --- | --- | --- |
| iPhone 17 Pro Max | 26.2 | 101.921с |
| iPad Pro 13-inch (M5) | 26.2 | 141.060с |
| iPhone SE (3rd generation) | 18.6 | 145.534с |
| iPad mini (A17 Pro) | 18.6 | 118.813с |

[проверенный CI18 receipt](evidence/account-deletion/final-ci18/receipt.json) связывает API/source/ZIP hashes, CRC,
четыре summaries/environments, native assertions и16оригинальных PNG.
Package намеренно SKIP; archive, Core AX, AX5 и Settings не запускались в CI18.
Это завершённая целевая проверка ввода/отмены/отказа/повтора/успеха, не новый full suite.
Просмотр PNG фиксируется отдельно: [iPhone review](evidence/account-deletion/final-ci18/iphone-visual-review.json),
[iPad review](evidence/account-deletion/final-ci18/ipad-visual-review.json).
Retry-снимки показывают полный текст неверного пароля и очищенное поле; success —
login сохранённого сервера с сообщением удаления. Keyboard и защищённое содержимое
поля не отображаются в app screenshot; отдельного alert PNG нет. Cancel/confirm
подтверждены native assertions. Перенос «Отме/на» в navigation button iOS26 остаётся
визуальным недостатком; весь дизайн не объявляется принятым. Push intent по умолчанию
выключен: concurrent enabled push по-прежнему не проверен этим UI-сценарием.
