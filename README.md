# 프로세스 장애 분석

제공 앱의 OOM·CPU·Deadlock을 관측하고 환경변수 변경 전후를 비교한다.

## 실행

Docker Desktop과 `agent-app-leak/agent-leak-app-arm64`를 준비한 뒤 저장소에서 실행한다.

```bash
docker compose up -d --build
docker compose exec -T --user root agent bash /workspace/scripts/setup.sh
mkdir -p evidence
docker inspect codyssey-b4-2-agent-1 > evidence/docker-before.json
docker compose exec -T --user agent agent bash /workspace/scripts/run_experiments.sh
docker inspect codyssey-b4-2-agent-1 > evidence/docker-after.json
docker compose cp agent:/home/agent/agent-leak-app/evidence/. evidence/
```

각 실행은 약 1초 간격으로 최대 600초 관측한다. 앱이 먼저 종료되면 다음 실행으로 넘어간다.
종료는 `docker compose down`을 사용한다. 데이터 보존을 위해 `down -v`는 사용하지 않는다.

## 실험 조건

| 실행 | MEMORY_LIMIT (MB) | CPU_MAX_OCCUPY (%) | MULTI_THREAD_ENABLE |
| --- | ---: | ---: | --- |
| OOM Before | 50 | 30 | false |
| OOM After | 512 | 30 | false |
| CPU Before | 512 | 100 | false |
| CPU After | 512 | 30 | false |
| Deadlock Before | 512 | 30 | true |
| Deadlock After | 512 | 30 | false |

각 쌍에서 대상 변수 하나만 변경한다. OOM·Deadlock은 CPU 장애 간섭을 줄이기 위해 CPU 설정을 30으로 고정한다.

## 결과

2026-10-16 실행 ID: `20261016T171314-IvPGr0`.

| 보고서 | Before | After |
| --- | --- | --- |
| [OOM](docs/issues/oom.md) | 50MB: 6초 후 MemoryGuard 종료 | 512MB: 캐시 정리 후 600초 생존 |
| [CPU](docs/issues/cpu.md) | 100: 43초 후 앱 임계치 로그·종료 | 30: 600초 생존 |
| [Deadlock](docs/issues/deadlock.md) | true: PID 유지·순환 대기·로그 정체 | false: 600초 동안 작업 로그 갱신 |

CPU 실측 최대는 Before 4.95%, After 4.90%였다. OS 과점유와 Watchdog 종료는 입증하지 못했다.
600초 생존은 관측 기간 내 결과이며, 이후에는 실험기가 종료했다.

## 증거

`evidence/<실행 ID>/<case>/`에 설정·앱 출력·CPU/RSS·프로세스/스레드 상태·종료 결과를 저장한다.
CPU는 worker의 `/proc` CPU 시간 증가량을 실제 경과 시간으로 나눈 값이며 한 코어가 100%다.
RSS는 `VmRSS / 1024`로 계산한 MiB다. 앱 출력의 부하·Heap 값과 구분한다.
`app_exit`는 앱 종료, `timeout`은 600초 관측 후 실험기 종료 요청을 뜻한다.
