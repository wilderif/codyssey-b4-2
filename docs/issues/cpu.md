# [Bug] CPU - 100 설정에서 앱 임계치 종료, 30 설정에서 생존

## 1. Description

2026-10-16 `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`를 고정하고 `CPU_MAX_OCCUPY=100 → 30`을 비교했다.
100 설정은 약 43초 후 `CPU Threshold Violated` 로그와 함께 종료됐다. 30 설정은 600초 동안 생존했다.
실제 프로세스 CPU 최대는 각각 4.95%, 4.90%로, OS CPU 급상승과 Watchdog 종료는 입증하지 못했다.

## 2. Evidence & Logs

원본: `evidence/20261016T171314-IvPGr0/{cpu-before,cpu-after}/`.
CPU는 `/proc` CPU 시간 증가량으로 계산하며 한 코어가 100%다.

Before의 관측 표본과 앱 출력:

```text
timestamp                   elapsed_s pid  cpu_pct rss_mib
2026-10-16T17:23:59+09:00     36.32     8513 4.95    16.43
2026-10-16T17:24:04+09:00     41.37     8513 0.00    16.43

2026-10-16 17:23:24,134 [INFO] [CpuWorker] Current Load: 5.00%
2026-10-16 17:24:04,778 [INFO] [CpuWorker] Current Load: 50.36%
2026-10-16 17:24:04,884 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.36000000000001%).
```

`system.log`의 프로세스·top 출력:

```text
2026-10-16T17:23:53+09:00
    PID    PPID    PGID USER     STAT ELAPSED   RSS COMMAND
   8513    8507    8507 agent    SN        31 16824 agent-leak-app-
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   8513 agent     30  10   23108  16824   8488 S   0.0   0.2   0:00.28 agent-l+
```

After의 부하 조절 로그와 실험기 종료 요청:

```text
2026-10-16 17:33:58,650 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-10-16 17:33:59,659 [INFO] [CpuWorker] Current Load: 30.00%
2026-10-16 17:34:02,786 [INFO] [CpuWorker] Current Load: 24.60%
2026-10-16T17:34:05+09:00 requested SIGTERM pgid=9145
```

Before는 `reason=app_exit`이며 실험기의 종료 요청은 없었다.
After는 `reason=timeout`이며 `cleanup.log`에 현재 실험 그룹의 TERM 요청이 기록됐다.
두 실행 모두 cgroup CPU 제한은 `max 100000`, `nr_throttled=0`이었다. 커널 로그는 권한 부족으로 조회하지 못했다.

## 3. Root Cause Analysis

앱 표시 부하는 5.00%에서 50.36%로 증가했지만, OS 실측 CPU는 최대 4.95%였다.
앱 표시값을 실제 CPU 사용률로 볼 수 없으며, CPU 과점유에 따른 시스템 지연도 확인되지 않았다.

임계치 위반 로그 직후 앱이 종료되어 앱 CPU 보호 동작에 따른 종료로 판단한다.
다만 Watchdog 이름이나 긴급 종료 신호 로그는 없고, launcher 종료 코드 143만으로 worker의 SIGTERM을 입증할 수 없다.
`CPU_MAX_OCCUPY`와 내부 종료 임계치의 정확한 관계는 소스 분석 없이 확정하지 않는다.

## 4. Workaround & Verification

| 항목 | Before | After |
| --- | --- | --- |
| CPU_MAX_OCCUPY | 100 | 30 |
| 실행 구간 (+09:00) | 17:23:22–17:24:05 | 17:24:05–17:34:06 |
| worker PID | 8513 | 9151 |
| 실험기 경과 (초) | 43 | 601 |
| 실제 CPU 최대 | 4.95% | 4.90% |
| RSS 최대 (MiB) | 16.43 | 516.67 |
| 종료 이유 | 앱 임계치 로그 후 종료 | 600초 관측 후 실험기 TERM |
| launcher / monitor 종료 코드 | 143 / 0 | 143 / 0 |

경과 시간에는 준비·종료 처리가 포함된다. 30 설정은 관측 기간 내 앱 임계치 종료를 피한 임시 설정이다.
After에서는 메모리 증가와 캐시 정리도 발생해 두 실행의 내부 부하가 동등하다고 가정할 수 없다.
OS 과점유·Watchdog의 필수 증거는 미확보이며, 장기적인 안정성이나 근본 수정까지 검증한 결과는 아니다.
