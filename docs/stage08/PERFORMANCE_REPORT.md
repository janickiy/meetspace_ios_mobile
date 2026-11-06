# Производительность и lifecycle: этап 08

Дата: 2026-11-06. **PASS** для описанных host stress assertions. **BLOCKED** для
Instruments/device CPU, memory, energy, длительного реального звонка и физического
ReplayKit. Host-метрики ниже не являются приёмкой производительности приложения iOS.

## Фактически выполнено

`swift test --filter stage08` прошёл **9/9**, включая 6 stress tests и 3 security
upload tests. Затем уже собранные 6 stress tests выполнены в трёх отдельных процессах:
**18/18 PASS**, по 30 циклов каждого сценария на запуск (90 в трёх измеренных запусках).
Первый sanity-прогон отдельно добавляет ещё 30 циклов. Новых product source правок
для performance не понадобилось; открытых P0/P1 по проверенным сценариям не выявлено.

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
process. Каждый повтор SwiftPM запускается заново. Значения относятся ко всему
командному дереву SwiftPM/test runner, а не к MeetSpace iOS.

| Повтор | Wall monotonic, с | CPU user / system, с | `/usr/bin/time` peak RSS, bytes | Максимум sampled tree RSS, KiB |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3.4562 | 2.22 / 0.63 | 889405440 | 915968 |
| 2 | 2.7849 | 1.83 / 0.49 | 990461952 | 1038704 |
| 3 | 2.8290 | 1.81 / 0.45 | 989855744 | 1038288 |

Медиана полного command wall time — **2.829 с**. Это baseline данной машины, не
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
  --filter stage08
python3 scripts/measure_host_stress.py \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  --output /tmp/meetspace-stage08-host-stress-02
```

[host-stress.json](evidence/performance/host-stress.json) содержит exact command,
source hashes проверенных тестов/основных production компонентов, рабочий commit и
`workingTreeDirty=true`: измерялся рабочий снимок до финального Stage8 commit.
После этих измерений добавлена отдельная реализация удаления аккаунта, в том числе
метод в `Authentication.swift`; её проверки приведены в [ACCOUNT_DELETION.md](ACCOUNT_DELETION.md).
Исторический hash `Authentication.swift` в performance receipt намеренно сохранён:
он описывает измеренный снимок, а не позднейший финальный исходник. Stress-сценарии
удаление аккаунта не вызывают. Это scoped snapshot, не список всего покрытия. Raw time output, sampled RSS и три
тестовых лога сохранены рядом; [filtered-tests.txt](evidence/performance/filtered-tests.txt)
содержит результаты исходных 9 tests. Первый запуск benchmark успешно исполнил tests,
но не записал итоговый JSON из-за неверного имени source path в collector; после
исправления выполнены все три измерения заново, в отчёт включён только полный run02.

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

## Instruments и device acceptance — BLOCKED

Локально `xcode-select -p` вернул `/Library/Developer/CommandLineTools`,
`xcrun --find xctrace` завершился 72 (`unable to find utility xctrace`). Полного Xcode,
подписанной установки и подключённых тестовых устройств нет. Отсутствующие Allocations,
Leaks, Time Profiler и Energy/Power Profiler traces не заменяются host RSS.
Apple описывает [Instruments performance tools](https://developer.apple.com/documentation/xcode/performance-and-metrics)
и [измерение энергии на реальном устройстве](https://help.apple.com/xcode/mac/current/en.lproj/devf7f7c5fcd.html).

Минимальный дополнительный CI шаг с полным Xcode сначала должен сохранить
`xcrun xctrace version`, `xcrun xctrace list templates`, `xcrun xctrace list devices`
и `xcrun xctrace help record`. Затем отдельная simulator recording job может привязать
доступный Time Profiler/Allocations template к PID приложения и сохранить `.trace`
при коротком воспроизводимом UI сценарии. Конкретные templates/target attach нужно
проверить на runner, а недоступность profiler отметить BLOCKED; отсутствие trace
не считать успешным profiling. Такой simulator trace не измеряет iPhone energy.
Workflow принадлежит root; этот отчёт не утверждает, что profiler job уже запускался.

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
