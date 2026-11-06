# Реальная готовая аудиозапись: SFU → recorder → FFmpeg → S3

Дата: 2026-11-06. **PASS** на одноразовом стенде: неизменённый backend создал
готовую запись `audio_only`, выдал подписанную ссылку и сохранил фактический
медиафайл. Этот прогон отдельный от [базового Swift API contract run](RUNTIME_CONTRACT.md).

```sh
python3 scripts/run_recording_pipeline.py \
  --backend /tmp/meetspace-ios-stage03/backend \
  --output /tmp/meetspace-stage07-recording-pipeline-01
```

Runner собирает API, SFU (`media-worker`) и `record-worker` из backend commit
`0bd1248a2411842515af4e02f1e95821616748fb`. Для запуска FFmpeg используется локально
кешированный arm64 runtime image `go-recorder-worker:latest`, ID
`sha256:d37e4a93b60ce872d856eb2accfcf9626a082a14a28e36eb80881a70ff54660d`.
Его штатный backend binary **не исполняется**: entrypoint заменён только что
собранным pinned `record-worker`, миграции также берутся из pinned checkout.
Для повторения нужен Docker, Go и доступный образ с `/usr/bin/ffmpeg` и
`/usr/bin/ffprobe`; образ можно указать через `--worker-image`.

PostgreSQL, Redis, RabbitMQ, MinIO, API, SFU и worker изолированы новой Docker-сетью;
пароли, JWT/internal secrets, аккаунты и опубликованные loopback-порты создаются
заново. Существующие сервисы и данные пользователя не меняются. Никаких изменений
backend, прямого создания `ready` в БД или предварительно загруженного медиа нет.

| Проверка | Наблюдение |
| --- | --- |
| Источник | Pion передаёт валидные Opus-пакеты синтетической тишины каждые 20 мс через настоящий WebRTC/SFU; публикация microphone подтверждена сигналингом |
| Работа записи | Фактическая цепочка API `starting → recording → stopping → processing → ready`; остановка владельцем после 8 секунд |
| Обработка | Настоящий recorder получает SFU egress, FFmpeg формирует AAC, результат загружается в S3/MinIO |
| Готовый файл | `audio/mp4`, 4 775 байт, один AAC audio stream, 48 000 Hz, 2 канала, 8.252333 с; ffprobe прочитал 389 кадров |
| Декодирование | Полный `ffmpeg -v error -i … -f null -` завершился с кодом 0 |
| Скачивание | Свежая server-signed URL: HTTP 200; размер и SHA-256 совпадают с metadata backend. Download не использует account bearer/cookies |
| Доступ | Допущенный участник видит готовую запись; 3 запросам metadata постороннего/исключённого участника отказано с 403; остановка записи обычным участником также 403 |
| Приватность объекта | GET того же объекта после удаления подписи возвращает 403 |
| Завершение | SFU: 0 peers/tracks/subscriptions/recording outputs; 0 failures, 1 direct connection. После runner: 0 созданных контейнеров и сетей |

SHA-256 actual artifact:
`fa17629d8db9171410af5fdbf58b74a2f344a3e363c6a88af8d33da1d3f79d69`.
Backend назвал объект `final.mp4`; локальная копия аудиоконтейнера сохранена как
`/tmp/meetspace-stage07-recording-pipeline-01/recording.m4a` (4 775 байт).
Она содержит только синтетическую тишину и может использоваться как DEBUG fixture.
Передача этих же байт в DEBUG UI fixture — отдельная проверка AVPlayer;
результаты hosted/UI тестов на момент этого отчёта ещё ожидаются. Этот pipeline
сам по себе не проверяет iOS playback.

## Границы результата

Источник синтетический: не проверялись реальный микрофон, камера, видео,
физические iPhone или запись содержимого экрана. SFU/worker и signed object
проверены внутри одноразовой Docker-сети через HTTP/WS и DTLS/SRTP. API возвращает
HTTPS signed URL; только тестовый Go probe заменяет схему на HTTP для точно
проверенного внутреннего MinIO hostname, сохраняя host/path/query подписи.
Production HTTPS/WSS, публичный TLS и iOS UI → production API → signed download
end-to-end этим прогоном не подтверждены.

После исключения участника проверен отказ в **новом** metadata/signed URL запросе.
Отзыв ранее выданной URL до истечения её TTL не проверялся. `partial_ready`,
recording failure/retry, видео, большие файлы, TURN и конкурентные записи также
не входят в этот прогон.

## Свидетельства

[runtime.json](evidence/recording-pipeline/runtime.json) содержит pinned source,
image IDs, hashes runner/probe и результат; оба source hash повторно сверены после
прогона. [recording-probe.log](evidence/recording-pipeline/recording-probe.log)
фиксирует реальные переходы состояний; [artifact.json](evidence/recording-pipeline/artifact.json)
содержит только безопасные media metadata без подписанных URL.
[ffprobe.json](evidence/recording-pipeline/ffprobe.json) и
[decode.txt](evidence/recording-pipeline/decode.txt) подтверждают чтение контейнера
и полное декодирование; [access-denials.json](evidence/recording-pipeline/access-denials.json)
содержит только агрегированные method/route/status из API logs.
[sfu-cleanup.json](evidence/recording-pipeline/sfu-cleanup.json) и
[cleanup.json](evidence/recording-pipeline/cleanup.json) фиксируют очистку.
Private logs, credentials, токены, подписанные URL и исполняемые backend binaries
в репозиторий не добавлялись.
