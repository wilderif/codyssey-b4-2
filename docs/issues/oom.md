# [Bug] OOM - 50MB 설정에서 MemoryGuard 종료, 상향 후 CPU 장애 간섭

## 1. Description

2026-10-16 Ubuntu 22.04.5 ARM64 컨테이너에서 일반 계정 `agent`로 실행했다.
`MEMORY_LIMIT=50`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false`에서 MemoryGuard 로그 후 앱이 종료됐다.
512MB 실행은 더 오래 실행됐지만 CPU 임계치 위반으로 먼저 종료되어 OOM 우회 검증은 불완전하다.

## 2. Evidence & Logs

원본: `evidence/20261016T164019-exZ12j/{oom-before,oom-after}/`.
각 디렉터리에 환경설정·앱 출력·CPU/RSS·시스템 관측·종료 결과·cgroup 진단을 보존했다.

```text
2026-10-16T16:40:20+09:00
    PID    PPID    PGID USER     STAT ELAPSED   RSS COMMAND
     92      85      85 agent    SN         1 16780 agent-leak-app-
```

리슨 PID 92의 실행 파일은 `/home/agent/agent-leak-app/agent-leak-app-arm64`, 소유자는 `agent`였다.
아래는 `samples.tsv`의 실제 표본이다. CPU는 구간 사용률, RSS는 MiB다.

```text
timestamp                   elapsed_s pid cpu_pct rss_mib
2026-10-16T16:40:20+09:00     0.00      92  NA      16.39
2026-10-16T16:40:22+09:00     2.02      92  0.00    41.39
2026-10-16T16:40:24+09:00     4.04      92  0.00    41.39
```

```text
2026-10-16 16:40:21,464 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-16 16:40:24,489 [INFO] [MemoryWorker] Current Heap: 50MB
2026-10-16 16:40:24,489 [CRITICAL] [MemoryGuard] Memory limit exceeded (50MB >= 50MB) / (Recommend Over 256MB)
2026-10-16 16:40:24,490 [CRITICAL] [MemoryGuard] Self-terminating process 92 to prevent system instability.
```

종료 후 `result.txt`:

```text
end=2026-10-16T16:40:25+09:00
elapsed_s=6
reason=app_exit
launcher_exit=137
monitor_exit=0
```

두 실행 모두 cgroup `memory.events`의 `oom`·`oom_kill`은 전후 0이고 `memory.max=max`였다.
실험 전체 전후 Docker의 컨테이너 `OOMKilled=false`도 확인했지만 이 값만으로 worker의 종료 원인을 판단하지 않는다.
커널 로그는 `dmesg: read kernel buffer failed: Operation not permitted`로 조회하지 못했다.

## 3. Root Cause Analysis

RSS는 16.39에서 41.39MiB로 증가했고 앱 내부 Heap은 25에서 50MB로 증가했다.
MemoryGuard의 임계치 도달·자기 종료 로그가 종료 직전에 있어 앱 메모리 보호에 따른 종료로 판단한다.
RSS는 상주 물리 메모리이며 앱 내부 Heap의 계산값과 일치한다고 가정하지 않는다.

관측한 cgroup의 OOM 증가가 없어 Linux OOM killer 종료를 나타내는 증거는 없다.
137은 launcher의 종료 결과이며 단독으로 worker의 종료 신호나 커널 동작을 단정하지 않는다.
소스 미분석 상태이므로 해제 누락의 구현 위치나 장기적인 증가율은 확정할 수 없다.

## 4. Workaround & Verification

CPU·스레드 설정을 고정하고 `MEMORY_LIMIT`만 50에서 512로 변경했다.

| 項目 | Before | After |
| --- | --- | --- |
| worker / launcher PID | 92 / 85 | 231 / 224 |
| 실행 구간(+09:00, 종료 검출·기록까지) | 16:40:19–16:40:25 | 16:40:25–16:40:57 |
| 실험기 경과 초 | 6 | 32 |
| RSS最大（MiB） | 41.39 | 16.45 |
| 마지막 장애 로그 | MemoryGuard: 50MB >= 50MB | CpuWorker: CPU Threshold Violated! (50.81000000000001%) |
| launcher 종료 코드 | 137 | 143 |

After의 최종 로그는 `2026-10-16 16:40:55,982`이다. Before보다 오래 실행됐지만 CPU 장애가 간섭했다.
After에서 같은 메모리 증가를 관측하지 못해 메모리 상한 변경에 따른 OOM 회피의 충분한 비교 증거는 없다.
상한 변경은 해제 누락을 수정하지 않으며 근본 수정에는 앱의 할당·해제 처리 확인이 필요하다.
