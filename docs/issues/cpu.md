# [Bug] CPU 과점유 - 앱 임계치 위반 종료와 OS CPU 실측 불일치

## 1. Description

2026-10-16 `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`를 고정하고 `CPU_MAX_OCCUPY`를 10에서 100으로 변경했다.
10% 실행은 600초 관찰 후 실험기가 종료했다. 100% 실행은 약 30초 후 `CpuWorker` 임계치 위반 로그와 함께 종료됐다.
프로세스 CPU 최대는 각각 2.97%, 4.95%였다. 명세의 CPU 급상승·Watchdog 종료는 입증하지 못했다.
이 문서는 조건 변경 전 실행 기록이며, 아래 수치·로그·시각은 당시 결과다.

## 2. Evidence & Logs

원본: `evidence/20261016T164019-exZ12j/{cpu-before,cpu-after}/`.
worker는 Before PID 735(launcher 728), After PID 9026(launcher 9019)였다.
둘 다 실행 파일·`agent` 소유자·현재 실행의 프로세스 그룹·리스너를 확인했다.

After의 `/proc` 관측 표본:

```text
timestamp                   elapsed_s pid  cpu_pct rss_mib
2026-10-16T16:51:19+09:00     20.19     9026 2.97    16.44
2026-10-16T16:51:22+09:00     23.21     9026 4.00    16.44
2026-10-16T16:51:25+09:00     26.25     9026 3.92    16.44
2026-10-16T16:51:28+09:00     29.29     9026 4.95    16.44
```

```text
2026-10-16 16:51:25,666 [INFO] [CpuWorker] Current Load: 43.92%
2026-10-16 16:51:28,790 [INFO] [CpuWorker] Current Load: 51.85%
2026-10-16 16:51:28,897 [CRITICAL] [CpuWorker] CPU Threshold Violated! (51.85%).
```

After의 `result.txt`는 `reason=app_exit`, `launcher_exit=143`, `monitor_exit=0`이다.
실험기의 종료 요청은 없었다. `ps`·`top` 출력은 `system.log`에 보존했다.

```text
2026-10-16T16:51:19+09:00
    PID    PPID    PGID USER     STAT ELAPSED   RSS COMMAND
   9026    9019    9019 agent    SN        21 16832 agent-leak-app-
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   9026 agent     30  10   23108  16832   8496 S   0.0   0.2   0:00.14 agent-l+
```

Before의 앱 로그와 실험기 종료 요청:

```text
2026-10-16 16:50:54,162 [INFO] [CpuWorker] Current Load: 10.00%
2026-10-16 16:50:56,279 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-10-16T16:50:57+09:00 requested SIGTERM pgid=728
```

모든 실행에서 cgroup `nr_throttled=0`, `oom_kill=0`이었다. 커널 로그는 권한 부족으로 조회하지 못했다.

## 3. Root Cause Analysis

앱이 출력한 `Current Load=51.85%`와 같은 시각 부근의 OS CPU 실측 4.95%는 일치하지 않는다.
`/proc`의 CPU 시간 증가량은 실제 프로세스 CPU 소비를 나타내므로 앱 표시값을 OS 사용률로 취급하지 않는다.
CPU 과점유는 다른 프로세스와 실행 시간 경쟁을 일으킬 수 있지만, 이번 실측으로 CPU 과점유에 따른 시스템 지연은 확인할 수 없다.

100% 설정에서 앱 CPU 보호에 관련된 종료는 시사되지만, 로그에 Watchdog 이름·긴급 종료 요청·worker에 전달한 신호 기록은 없다.
launcher 종료 코드 143만으로 Watchdog의 SIGTERM을 입증할 수 없다.
`CPU_MAX_OCCUPY=100`이 보호 임계치 자체라는 구현 근거도 없으며 내부 비교 처리는 확정하지 않는다.

## 4. Workaround & Verification

| 항목 | Before | After |
| --- | --- | --- |
| CPU_MAX_OCCUPY | 10 | 100 |
| 실행 구간（+09:00） | 16:40:57–16:50:58 | 16:50:58–16:51:30 |
| 실험기 경과 초（종료 처리 포함） | 601 | 32 |
| CPU 최대（한 코어=100%） | 2.97% | 4.95% |
| RSS 최대 | 516.68MiB | 16.44MiB |
| 종료 이유 | 600초 후 실험기 TERM | 앱 종료·CPU 임계치 위반 로그 |
| launcher / monitor 종료 코드 | 143 / 0 | 143 / 0 |

10%에서는 600초 관측 중 앱 보호에 따른 종료가 없었다. 100% 변경 후에는 짧은 시간에 종료됐으며 개선은 확인하지 못했다.
10%를 관측 기간 내의 임시 설정으로 볼 수 있으나 지속적인 정상 동작이나 근본 해결을 보장하지 않는다.
두 실행의 RSS 추이도 달라 내부 부하의 동등성에는 한계가 있다. 고정 6회 이외의 추가 실행은 하지 않았다.

다음 실험에서는 메모리 512·스레드 false를 고정하고 CPU를 100 → 30으로 비교한다.
이 조건은 실행기에 반영했으며 아직 실행하지 않았다. 30 설정의 생존 여부와 OS CPU·Watchdog 증거는 미검증이다.
