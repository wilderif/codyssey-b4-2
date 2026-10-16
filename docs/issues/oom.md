# [Bug] OOM - 50MB에서 MemoryGuard 종료, 512MB에서 캐시 정리 후 생존

## 1. Description

2026-10-16 `CPU_MAX_OCCUPY=30`, `MULTI_THREAD_ENABLE=false`를 고정하고 `MEMORY_LIMIT=50 → 512`를 비교했다.
50MB에서는 메모리 증가 후 앱이 종료됐다. 512MB에서는 캐시 정리를 반복하며 600초 관측 동안 생존했다.

## 2. Evidence & Logs

원본: `evidence/20261016T171314-IvPGr0/{oom-before,oom-after}/`.
`samples.tsv`는 실제 worker의 구간 CPU와 RSS(MiB), `application.out`은 해당 실행의 앱 출력이다.

Before의 프로세스와 메모리 증가:

```text
2026-10-16T17:13:15+09:00
    PID    PPID    PGID USER     STAT ELAPSED   RSS COMMAND
    114     108     108 agent    SN         1 16784 agent-leak-app-

timestamp                   elapsed_s pid cpu_pct rss_mib
2026-10-16T17:13:15+09:00     0.00      114 NA      16.39
2026-10-16T17:13:17+09:00     2.02      114 0.00    41.39
```

```text
2026-10-16 17:13:16,815 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-16 17:13:19,839 [INFO] [MemoryWorker] Current Heap: 50MB
2026-10-16 17:13:19,840 [CRITICAL] [MemoryGuard] Memory limit exceeded (50MB >= 50MB) / (Recommend Over 256MB)
2026-10-16 17:13:19,840 [CRITICAL] [MemoryGuard] Self-terminating process 114 to prevent system instability.
```

After의 정리 전후:

```text
2026-10-16T17:14:21+09:00     59.50     256 0.00    516.67
2026-10-16T17:14:25+09:00     63.52     256 0.00     16.59

2026-10-16 17:14:24,359 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-16 17:14:24,368 [INFO] [System] Memory Cache Flushed. Process Stabilized.
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
```

Before 종료 후 `reason=app_exit`, `launcher_exit=137`, `monitor_exit=0`이 기록됐고 PID와 리스너가 사라졌다.
두 실행의 cgroup `oom`·`oom_kill`은 전후 0, `memory.max=max`였다. 커널 로그는 권한 부족으로 조회하지 못했다.

## 3. Root Cause Analysis

RSS 상승과 MemoryGuard의 한도 초과·자기 종료 로그가 이어져 앱 메모리 보호에 따른 종료로 판단한다.
커널 OOM을 뒷받침하는 증거는 없으며, 종료 코드 137만으로 종료 신호나 커널 OOM을 단정하지 않는다.

512MB에서는 앱 내부 Heap이 525MB에 도달한 뒤 캐시를 비우고 RSS도 감소했다.
관측 결과는 메모리 누적과 설정에 따른 처리 차이를 보여준다. 소스 분석 없이 해제 누락 위치나 지속적인 메모리 누수를 확정할 수는 없다.
앱의 Heap 계산값과 OS의 상주 메모리 RSS는 서로 다른 지표다.

## 4. Workaround & Verification

| 항목 | Before | After |
| --- | --- | --- |
| MEMORY_LIMIT (MB) | 50 | 512 |
| 실행 구간 (+09:00) | 17:13:14–17:13:20 | 17:13:20–17:23:22 |
| worker PID | 114 | 256 |
| 실험기 경과 (초) | 6 | 602 |
| RSS 최대 (MiB) | 41.39 | 516.67 |
| 메모리 처리 | MemoryGuard 자기 종료 | 캐시 정리 9회 |
| 종료 이유 | 앱 종료 | 600초 관측 후 실험기 TERM |
| launcher / monitor 종료 코드 | 137 / 0 | 143 / 0 |

경과 시간에는 준비·종료 처리가 포함된다. 512MB는 관측 기간 내 종료 회피가 확인된 임시 설정이다.
장기 생존이나 근본 결함 수정까지 검증한 결과는 아니다.
