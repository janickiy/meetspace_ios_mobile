# Производительность и lifecycle: этап 08

Дата: 2026-11-06. **PASS** для описанных host stress assertions. **BLOCKED** для
Instruments на физическом устройстве, device CPU/memory/energy, длительного реального
звонка и физического ReplayKit. Simulator profiling CI8 — **BLOCKED** на Shutdown
preflight; CI10 — **FAIL** на ожидании boot и cleanup. В CI14 подготовка и cleanup
завершились успешно, но общий profiler result — **FAIL**: запись Time Profiler
превысила timeout, а полученная Allocations trace не предоставила allocation/heap
schema для экспорта численных метрик. CI15 на ARM runner — **FAIL** до attach:
обе `simctl launch` команды не вернули PID до timeout. Новые trace и численные
CPU/RSS/energy метрики не получены. CI16 — **FAIL** ещё на проверке
post-boot inventory: запуск приложения и capture не выполнялись.
Host-метрики ниже не являются приёмкой производительности приложения iOS.

## Фактически выполнено

Зафиксированный host baseline: 6 stress tests выполнены в трёх отдельных запусках SwiftPM: **18/18 PASS**,
по 30 циклов каждого сценария на запуск (90 в трёх измеренных запусках run03).
После исправления проверки CallKit completion дополнительно прошли один целевой
30-cycle тест и три полных suite: **176 passed / 5 opt-in skipped из 181** каждый.
Новых product source правок
для performance не понадобилось; открытых P0/P1 по проверенным сценариям не выявлено.

Первоначальный `swift test --filter stage08` прошёл 9/9 (6 stress + 3 security upload).
Однако CI2 под параллельной нагрузкой обнаружил race в самом stress assertion:
`ConferenceSession.phase = .connected` предшествует отдельно запланированному
`DirectCallCoordinator.mediaChanged` Task, который завершает CallKit action. Тест
теперь ограниченно ждёт фактический результат action через существующий `callEventually`,
затем проверяет ровно один успешный результат до end и повторно после close. Состояние
connected также проверяется; задержки фиксированной длительности не добавлены.
Это не дефект media/CallKit реализации. [Regression receipt](evidence/performance/completion-wait-regression.json)
и три полных лога находятся рядом. Старый run02 заменён новым baseline run03 с
исправленным тестом и финальной реализацией Authentication; его метрики не смешаны с новыми.

| Сценарий / тест | Что действительно проверено | Граница |
| --- | --- | --- |
| `stage08ThirtyConferenceScreenCyclesReleaseResources` | 30 connect/ready, screen consent/frame/ack, leave; закрытие media/socket/broadcast, пустые participants/videoTracks; поздний frame не оживляет media; weak references session/engine/broadcast освобождаются | Production ConferenceSession; signaling, camera/mic, ReplayKit — doubles |
| `stage08ThirtyDirectCallAnswerEndCyclesReleaseResources` | 30 answer → SFU-ready → end; ровно одно завершение answer, end на серверном double, socket/capture закрыты; coordinator/engine weak references освобождены | Production coordinator/session; CallKit, REST и RTC capture — doubles |
| `stage08ThirtyReconnectsUseFreshTicketsWithoutSocketOverlap` | 30 reconnect, 31 уникальный ticket/socket, нет одновременного открытого старого socket; один и тот же event доставлен один раз; finish закрывает все sockets и запрещает restart | Production UserRealtime, in-memory sockets; backoff wait заменён yield |
| `stage08ThirtyBroadcastSocketLeasesReleaseDescriptorsAndFenceOldFrames` | 30 настоящих Unix-socket IPC leases, передача frame, FPS drop, stop; удалены descriptor/socket files, следующая lease получает flock; старая lease отвергается | Настоящий host/extension-side IPC код в одном macOS-процессе; временный каталог, не подписанная App Group/ReplayKit |
| `stage08ThirtyRecordingDownloadAndCancelCyclesCleanFiles` | 30 download/hash/size на диск + remove; в каждом цикле pending URLSession request отменён close, файлов не осталось | URLSession и disk реальные; URLProtocol выдаёт 128 KiB fixture и pending request, не Internet/backend |
| `stage08ThirtyMaximumSizeUploadStagingCyclesCleanAccountFiles` | 30 импортов по 10 MiB (300 MiB суммарно), init/PUT/finalize; transport читает staged file порциями и сверяет hash; staged файлы удалены, source не изменён | Реальный AccountFileStore и MessagingRepository; RequestTransport double, не HTTPS throughput |

Weak-release assertions проверяют конкретные Swift объекты после корректного teardown.
Они не заменяют Allocations/Leaks, не анализируют весь процесс и не покрывают native
WebRTC C++ allocations. Сохранённые ресурсы и системные ошибки удаления файлов требуют
отдельной проверки на устройстве. Изолированные циклы не заменяют непрерывный звонок.

## Host CPU/RSS/timing

Среда: macOS kernel Darwin 27.0.0, arm64, 10 logical CPU, Apple Swift 6.4,
Command Line Tools SDK MacOSX26.4. Debug binaries. Сборка исключена `--skip-build`.
Внутри IntegrationTests stress cases запускаются параллельно; BroadcastTests — отдельный
process. Каждый повтор SwiftPM запускается заново. Это показатели host-запуска
SwiftPM/test runner, а не измерение процесса MeetSpace iOS. `time` high-water RSS
из `rusage` и сумма RSS дерева в момент `ps` sample — разные величины; первая
не является суммой одновременной памяти всех процессов.

| Повтор | Wall monotonic, с | CPU user / system, с | `/usr/bin/time` peak RSS, bytes | Максимум sampled tree RSS, KiB |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3.6493 | 2.20 / 0.57 | 990183424 | 1038816 |
| 2 | 2.9913 | 1.73 / 0.40 | 990298112 | 1038704 |
| 3 | 3.0162 | 1.72 / 0.41 | 991297536 | 1039776 |

Медиана полного command wall time — **3.0162 с**. Это baseline данной машины, не
обещание launch/call latency и не performance budget. `/usr/bin/time -l` даёт CPU
и high-water RSS; отдельный `ps` sampler примерно каждые 50 мс суммирует RSS
процессов дерева и может повторно учитывать shared pages. RSS между независимыми
процессами различается; три точки не доказывают отсутствие утечки и не определяют
slope памяти приложения. Energy, thermal state, battery drain не измерялись.

Команды:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
swift test --package-path Packages/MeetSpaceKit \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  --filter stage08ThirtyDirectCallAnswerEndCyclesReleaseResources
# После сборки три полных swift test --skip-build; затем измерения:
python3 scripts/measure_host_stress.py \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  --output /tmp/meetspace-stage08-host-stress-03
```

[host-stress.json](evidence/performance/host-stress.json) содержит exact command,
source hashes проверенных тестов/основных production компонентов, рабочий commit и
`workingTreeDirty=true`: измерялся рабочий снимок до финального Stage8 commit.
Snapshot run03 включает актуальный `Authentication.swift` и исправленный call stress test;
отдельная проверка удаления аккаунта приведена в [ACCOUNT_DELETION.md](ACCOUNT_DELETION.md).
Stress-сценарии удаление аккаунта не вызывают. Это scoped snapshot, не список всего покрытия. Raw time output, sampled RSS и три
тестовых лога сохранены рядом; [filtered-tests.txt](evidence/performance/filtered-tests.txt)
содержит только исторические результаты исходных 9 tests. Текущие измерения и hashes
относятся к run03; raw logs run-1…run-3 заменены вместе с JSON. Первые run01/run02
не используются как текущий performance baseline.

## Аудит ограничений ресурсов

- ConferenceSession прекращает generation, consumer/deadline/heartbeat tasks,
  останавливает broadcast, отключает screen, закрывает media/socket и очищает tracks
  до завершения leave. DirectCallCoordinator отменяет polling/actions и прекращает media.
- Screen pipeline использует newest-frame buffering(1), IPC не ставит кадры в очередь
  при backpressure, ограничивает frame rate 10 fps; native screen pool ограничен.
  Эти пределы видны в коде, но их CPU/energy эффект на устройстве не измерен.
- Recording download пишет chunks 64 KiB, предел 512 MiB; chat import имеет предел
  10 MiB, хотя stage намеренно удерживает bounded Data. Нет измерения одновременных
  больших загрузок на iPhone и filesystem-full recovery в этом stress run.
- Предыдущие настоящие backend/SFU/record-worker сценарии остаются свидетельством
  соответствующих этапов, включая [готовый AAC pipeline](../stage07/RECORDING_PIPELINE.md).
  Они не переименованы в iOS device performance или текущие 30-cycle network tests.

## Instruments: device acceptance — BLOCKED, simulator CI14 — FAIL

Локально `xcode-select -p` вернул `/Library/Developer/CommandLineTools`,
`xcrun --find xctrace` завершился 72 (`unable to find utility xctrace`). Полного Xcode и подписанной установки нет; доступный путь запуска на физическом
устройстве не установлен. Наличие подключённых устройств без devicectl не проверено. Отсутствующие Allocations,
Leaks, Time Profiler и Energy/Power Profiler traces не заменяются host RSS.
Apple описывает [Instruments performance tools](https://developer.apple.com/documentation/xcode/performance-and-metrics)
и [измерение энергии на реальном устройстве](https://help.apple.com/xcode/mac/current/en.lproj/devf7f7c5fcd.html).

В [.github/workflows/ios.yml](../../.github/workflows/ios.yml) добавлен отдельный шаг
`Diagnostic Instruments baseline (reported separately)` после нативных тестов.
Он запускается только для `iPhone18`, при `scope != deletion`, включая случай
неуспешных тестов (`always()`). `continue-on-error: true` сохраняет результат
нативных тестов независимо от диагностического шага: зелёный job не означает
успешное profiling. Статус profiler определяется отдельным `receipt.json`.

Первый запуск этого шага выполнен в
[CI8 / 42255060641](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42255060641),
source `6b6d1bbda9224d459e2a07d551db65956946f2fe`, runner `macos-15-intel`,
`DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`.
Фактические версии: Xcode 26.3 / build 17C529, xctrace 26.0 (17C529).
[Receipt](evidence/profiling-attempt08/receipt.json) зафиксировал **BLOCKED** после
**13.959 с preflight**, `captures=[]`, exit code диагностического шага 2.
Это длительность подготовки profiler, не launch latency приложения.

[simctl inventory](evidence/profiling-attempt08/simctl-devices.log) показывает
`4E62D48E-A75F-4AF3-BDC2-1C74916B5810` в состоянии Shutdown. Тот же UUID указан
в [test summary](evidence/profiling-attempt08/iPhone18-summary.json) и environment:
гипотеза выбора другого клонированного устройства этими данными не подтверждается.
Первый вариант скрипта требовал уже Booted simulator и остановился до проверки
app container, запуска приложения или attach. `.trace`, TOC и таблиц измерений нет.
[Template inventory](evidence/profiling-attempt08/xctrace-templates.log) действительно
содержит Time Profiler и Allocations, а также Leaks и Power Profiler; это подтверждает
наличие templates, но не поддержку attach или device energy на данном runner.
Неизменённые receipt/inventory/help/environment/summary сохранены с SHA-256 в
[manifest](evidence/profiling-attempt08/manifest.json). Ожидание runner capacity
в предыдущем CI7 на ARM не является измерением или доказательством недоступности Instruments.

Исправление source `92357498a693f82000e3df90ac637df3e9971c5e` требует подтверждения
точного единственного iOS Simulator UUID через `xcresulttool` summary. С явным
`--boot-if-needed` оно запускает именно этот симулятор при Shutdown, ограниченно
ждёт `bootstatus`, повторно проверяет inventories и существующий app container.
Другой simulator, установка найденного через glob приложения или host fallback
не используются. Boot/bootstatus errors сохраняются как FAIL; отсутствие app — BLOCKED.
Если скрипт сам включил симулятор, cleanup пытается вернуть его в Shutdown;
результат этой команды проверяется отдельно и не предполагается успешным.

[CI10 / 42263390594](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42263390594),
source `e0a37748eb865b84dddf3da6339d16e0d8e1a0fe`, действительно выполнил новый
boot path, но завершился **FAIL**, а не BLOCKED или RECORDED.
[Receipt](evidence/profiling-attempt10/receipt.json) содержит **108.01 с** общей
подготовки/cleanup, `captures=[]`; `simctl boot` завершился 0 за 2.104 с.
Последующий `bootstatus` с timeout 45 с получил `timedOut=true`, exit −15,
наблюдаемое elapsed 74.449 с. В [логе bootstatus](evidence/profiling-attempt10/simulator-bootstatus.log)
видны BackBoard → Data Migration → System App и terminal Finished при внутреннем
elapsed **58 с**. Эта строка не отменяет timeout/сигнал завершения команды и не
доказывает успешный preflight. `simctl shutdown` с timeout 5 с также истёк:
elapsed **11.296 с**, exit −2; финальное состояние Shutdown не подтверждено.
Приложение, attach и экспорт таблиц не запускались: `.trace`, TOC, CPU/RSS/energy
метрик нет. Это сбой ограниченного ожидания подготовки симулятора; недоступность
Instruments на этом runner им не установлена. Нативные тесты этой job также
завершились неуспешно, но их причина и приёмка ведутся отдельно в [TEST_REPORT.md](TEST_REPORT.md).

Неизменённые CI10 логи, receipt, summary/environment и воспроизводимый анализ
сохранены в [manifest](evidence/profiling-attempt10/manifest.json) и
[inspection](evidence/profiling-attempt10/inspection.json): 14 исходных profiler
файлов, 0 несовпадений их receipt-хешей, 0 captures. SHA-256 ZIP совпал с digest
GitHub artifact. Новый вариант ожиданий ниже подготовлен по наблюдённым 58 с boot;
его реальная проверка в CI14 приведена далее. Кандидат `a052abdacaf49d05a68b17725dda0e4b096bb86e` включает новые пределы;
исторические CI11/CI12 не подтверждают этот вариант и не переименовываются
в успешное profiling.

[CI14 / 42275177048](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42275177048),
source `04f70a3d80bfd8cd9314c798f0eb3fc7e58b343f`, дошёл до настоящего attach
двух инструментов на том же iPhone SE / iOS 18.6. [Receipt](evidence/profiling-attempt14/receipt.json)
сохраняет общий **FAIL**, elapsed **174.383 с**. `bootstatus` завершился 0 за
45.402 с; проверены установленный Debug fixture marker, bundle ID, PID и executable.
Это подтверждает подготовку конкретного simulator app; длительность подготовки
не является launch latency, а fixture idle UI не является сценарием звонка.

- **Time Profiler — FAIL.** PID 44698, requested recording 15 с, command timeout
  40 с. Команда превысила timeout: observed 43.14 с, exit 1, `timedOut=true`.
  [Лог](evidence/profiling-attempt14/cpu-record.log) заканчивается `Stopping recording…`;
  `cpu.trace` содержит только RunIssues store размером 53 248 bytes. Завершённой
  CPU trace, TOC или численных CPU метрик нет. Причина незавершённого stop отдельно
  не установлена; завершение по timeout не переименовано в успешную запись.
- **Allocations — raw trace получена, численная приёмка BLOCKED.** PID 46601,
  record exit 0 за 34.635 с, trace 7 326 360 bytes. [TOC](evidence/profiling-attempt14/allocations-toc.xml)
  подтверждает точный simulator/PID, duration 16.526096 с, завершение по time limit
  и tracks `Allocations` (Statistics / Allocations List), `VM Tracker` (Regions Map).
  Однако доступные CLI data schemas не включают allocation/heap table:
  `tableExports=[]`, `measurementGate=NO_RECOGNIZED_SCHEMA`. Это ограничение
  полученного экспорта, а не доказательство отсутствия allocation data в raw trace.
  Allocation bytes, peak memory и RSS не вычислялись и не подменялись размером trace.
- **Cleanup commands завершились успешно:** `simctl terminate` — exit 0 за
  0.448 с, `simctl shutdown` — exit 0 за 1.249 с, оба без timeout. Отдельного
  process/state inventory после cleanup нет; подтверждён результат команд.

[Manifest](evidence/profiling-attempt14/manifest.json) связывает результат с artifact
13534592310: SHA-256 ZIP совпал с GitHub API digest, ZIP CRC проверен. Все 25
receipt-хешей совпали. [Воспроизводимый анализ](evidence/profiling-attempt14/inspection.json)
включает хеши 95 raw trace files; исходные бинарные traces находятся в CI artifact
и частном временном каталоге, а в репозитории сохранены неизменённые логи/TOC/receipt
и анализ. Native tests этой job завершились FAIL и ведутся отдельно; ни
`continue-on-error`, ни успешная запись Allocations не делают их или performance gate
успешными. Physical-device Instruments и energy по-прежнему **BLOCKED**.

[CI15 / 42281088607](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42281088607),
source `55bfcfb1e075224eda9ed7106a669db0b55dd7e5`, проверен отдельно на ARM runner,
iPhone SE (3rd generation) / iOS18.6, Xcode26.3/17C529. Native compatibility suite
завершился **15 PASS / 0 FAIL / 0 SKIP**, но profiler step — **FAIL**, exit1,
elapsed **94.038 с** ([неизменённый receipt](evidence/profiling-attempt15/receipt.json),
[независимый разбор](evidence/profiling-attempt15/inspection.json),
[step excerpt](evidence/profiling-attempt15/native-profiler-step-excerpt.txt)).

- Exact UUID совпал с native summary/environment, `bootstatus` завершился0 за
  **34.903 с**, последующий simctl inventory показал этот simulator Booted.
  App container найден, fixture marker подтверждён preflight.
- `cpu-launch` и `allocations-launch` (`simctl launch --terminate-running-process … -uitesting`)
  оба превысили свой command deadline: exit **−2**, `timedOut=true`, elapsed
  **12.043 с** и **12.034 с**. Оба stdout/stderr пусты. PID не получен;
  PID/executable validation, `xctrace record` и `xctrace export` не были вызваны.
  Это failure команды запуска, не измерение launch latency и не доказательство
  отсутствия позднего асинхронно запущенного процесса.
- В скачанном artifact нет `.trace`/TOC/экспортированных таблиц. CPU, RSS,
  allocated bytes, Leaks и energy не измерены. Успешный native suite не заменяет
  отсутствующие результаты Instruments.
- Cleanup `simctl shutdown` завершился0 за **4.158 с**, без timeout.
  Отдельного `terminate` нет, поскольку PID не был получен; post-cleanup
  process/state inventory не сохранён.

[Manifest CI15](evidence/profiling-attempt15/manifest.json) сохраняет происхождение
artifact 13539480023, совпавшие SHA-256/size и ZIP CRC; проверены все18
хешей из receipt, сохранены19 исходных profiler файлов. Анализ не запускал
симулятор или profiler повторно.

[CI16 / 42283560617](https://github.com/janickiy/meetspace_ios_mobile/actions/runs/42283560617),
source `a33a153147d6941874884357134b3fd46de7532c`, снова завершил profiler
**FAIL**, elapsed **67.293 с**, до запуска приложения. Native iPhone18
targeted regression отдельно прошёл **14/14**, без SKIP; он не является full suite.
[Receipt](evidence/profiling-attempt16/receipt.json),
[независимый разбор](evidence/profiling-attempt16/inspection.json),
[manifest с provenance/hashes](evidence/profiling-attempt16/manifest.json).

- UUID и hash native summary совпали. `simctl boot` вернул0, `bootstatus` —0
  за **21.806 с**; его log содержит terminal status4294967295/Finished.
  Следующий `simctl list devices available --json` превысил command timeout:
  exit **−2**, elapsed **13.794 с**, stdout/stderr пусты. Exact Booted state
  после boot не подтверждён; reason — `Cannot verify simulator state after boot`.
- App container/fixture-marker, launch, PID validation, record и export
  не достигнуты; `captures=[]`. В artifact нет trace. CPU/RSS/allocated bytes,
  Leaks и energy не измерены; это не доказательство недоступности Instruments.
- Cleanup shutdown вернул0 за **15.026 с**. Отдельный terminate не вызывался
  без полученного PID; post-cleanup inventory отсутствует.

API digest/size и ZIP CRC совпали; проверены14 log-хешей исходного receipt,
сохранены15 исходных profiler файлов. Успешный native regression и
`continue-on-error` шага не меняют profiler FAIL.

Текущая команда шага после исправления:

```sh
meetspace_profile_udid=$(python3 -c 'import json; print(json.load(open("artifacts/iPhone18-environment.json"))["udid"])')
python3 scripts/profile_simulator.py \
  --simulator "$meetspace_profile_udid" \
  --test-summary artifacts/iPhone18-summary.json --boot-if-needed \
  --output artifacts/iPhone18-profiling
```

[scripts/profile_simulator.py](../../scripts/profile_simulator.py) использует по
умолчанию `--seconds 15 --wall-budget 240`: две последовательные записи по 15 секунд
(Time Profiler и Allocations), общий бюджет планирования команд 240 секунд плюс
завершение процессов по сигналам и отдельный cleanup. Каждая запись имеет timeout
40 секунд; boot/bootstatus ограничены 15/90 секундами в пределах общего бюджета;
cleanup приложения — 5 с, shutdown симулятора — 30 с. Это запрошенные deadlines,
а не гарантия точного wall time: CI10 показал превышение; причины дополнительной
задержки отдельно не измерялись. Версия CI10 ещё использовала бюджет 180 с и пределы 45/5 с;
её сохранённый receipt не изменён. Новый вариант прошёл `py_compile` и пять mock
проверок ошибок/границ target. Эти mock-проверки не заменяют фактический
profiler runs CI14/CI15/CI16, результаты которых разобраны выше.
Скрипт сохраняет версии, templates/devices и справку CLI, проверяет
точный booted simulator UUID и fixture marker приложения. Для каждого template
он запускает `com.meetspace.ios -uitesting`, сверяет PID/executable и выполняет:

```sh
xcrun xctrace record --template "$template" --device "$meetspace_profile_udid" \
  --attach "$pid" --time-limit 15s --output "$trace"
xcrun xctrace export --input "$trace" --toc --output "$toc"
```

`--no-prompt` добавляется только при наличии в справке установленного `xctrace`.
Далее скрипт экспортирует обнаруженные CPU/allocation tables, проверяет PID в TOC
и считает фактические строки XML. Сохраняются `.trace`, inventory, stdout/stderr,
точные argv/exit codes, TOC, таблицы и `receipt.json`; их загружает общий artifact
`results-iPhone18`. Если setup шага не дошёл до создания receipt, это тоже требует
разбора лога, а не трактуется как успешная запись.

Receipt различает `RECORDED`, `BLOCKED` и `FAIL`. Непустая trace сама по себе
недостаточна: отсутствие подходящей schema или строк получает `NO_RECOGNIZED_SCHEMA`
либо `NO_RECORDS`; неуспешные record/export сохраняют ошибку. Даже `RECORDED` с
`measurementGate=NONEMPTY_TABLES_REVIEW_REQUIRED` означает только получение данных,
которые ещё нужно изучить, а не performance PASS. У CI8 фактический итог —
**BLOCKED**, у CI10 — **FAIL** до capture, у CI14 — **FAIL** после attach:
Time Profiler не завершил корректную trace, а raw Allocations trace не дала
экспортируемой таблицы измерений. CI15 — **FAIL** до attach из-за двух
`simctl launch` timeouts; CI16 — **FAIL** на post-boot inventory, до launch.
Trace этих попыток не получены. CPU/RSS/allocated bytes не установлены;
физические устройства и energy остаются **BLOCKED**.

Это короткая запись уже запущенного Debug fixture UI в покое. Она не измеряет
launch latency, 30 звонков, непрерывный звонок, ReplayKit, reconnect, transfer,
Leaks, Release performance или энергию физического iPhone. Эти границы сохраняются
даже при успешном attach. Отсутствие локального `xctrace` также не закрывает
доступную CI-проверку внешним статусом BLOCKED.

Для физической приёмки после появления signing/device/HTTPS deployment:

1. На iPhone и iPad выполнить 30 входящих/исходящих звонков с camera/mic и 30
   screen-share start/stop, включая отмену системного picker и смену ориентации.
2. Непрерывный 60-минутный звонок: baseline после прогрева, затем CPU/RSS/allocations
   каждые 5 минут; screen share ≥10 минут, foreground/background/lock и Wi-Fi recovery.
3. Upload/download на лимитах, cancellation/logout/switch, обрыв сети и недостаток
   места; проверить отсутствие retained sessions/capture/sockets и чужих local files.
4. Сохранить Allocations generations, Leaks, Time Profiler и доступный Energy Log/
   Power Profiler trace, device/OS/build/network/thermal metadata, фактические max/median
   и причину каждого отклонения. Численные budgets утвердить по device baseline;
   произвольные host thresholds здесь не назначаются.

До получения этих traces/device результатов criterion «измерения памяти/CPU/энергии
и тесты на устройствах» имеет статус **BLOCKED**, а не PASS.
