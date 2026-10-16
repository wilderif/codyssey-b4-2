# [Bug] Deadlock - 두 작업자의 순환 자원 대기로 작업 정체

## 1. Description

2026-10-16 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=30`을 고정하고 `MULTI_THREAD_ENABLE=true → false`를 비교했다.
true에서는 PID가 유지됐지만 CPU·RSS·로그가 정체됐다. 서로 다른 자원을 보유한 두 작업자가 상대 자원을 기다리는 로그가 확인됐다.
false에서는 600초 동안 작업 로그와 CPU·RSS 변화가 이어졌다.

## 2. Evidence & Logs

원본: `evidence/20261016T171314-IvPGr0/{deadlock-before,deadlock-after}/`.
Before의 마지막 자원 보유·대기 로그:

```text
2026-10-16 17:34:13,459 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-10-16 17:34:13,459 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-10-16 17:34:15,472 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
2026-10-16 17:34:15,475 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```

`system.log`의 종료 요청 직전 프로세스·스레드 관측:

```text
2026-10-16T17:44:06+09:00
    PID    PPID    PGID USER     STAT ELAPSED   RSS COMMAND
  17376   17370   17370 agent    SNl      600 16848 agent-leak-app-
    PID    PPID     TID STAT WCHAN                                TIME COMMAND
  17376   17370   17376 SNl  futex_do_wait                    00:00:00 agent-leak-app-
  17376   17370   17490 SNl  futex_do_wait                    00:00:00 agent-leak-app-
  17376   17370   17491 SNl  futex_do_wait                    00:00:00 agent-leak-app-
/home/agent/agent-leak-app/logs/agent_app.log 65256 2026-10-16+17:34:15.4757714260
```

정체 구간의 `samples.tsv` 표본:

```text
timestamp                   elapsed_s pid   cpu_pct rss_mib
2026-10-16T17:34:46+09:00     39.37     17376 0.00    16.45
2026-10-16T17:44:05+09:00     598.02    17376 0.00    16.45
```

로그 크기와 수정 시각은 마지막 대기 로그 이후 종료 요청 직전까지 변하지 않았다.
Before는 앱 자체 종료 없이 600초를 채웠고, 실험기가 17:44:06에 현재 그룹으로 TERM을 요청했다.

## 3. Root Cause Analysis

| 작업자 | 보유 자원 | 기다리는 자원 |
| --- | --- | --- |
| Worker-Thread-1 | Shared_Memory_A | Socket_Pool_B |
| Worker-Thread-2 | Socket_Pool_B | Shared_Memory_A |

각 작업자가 자원을 보유한 채 상대 자원을 기다려 순환 대기가 형성됐다.
자원 보유·대기 로그, 지속되는 futex 대기, CPU·RSS·로그 정체와 PID 생존을 종합하면 교착상태로 판단한다.
상호 배제·점유 대기·순환 대기는 로그가 뒷받침하며, 관측 기간 내 자원 회수나 대기 해제는 없었다.
실제 락 구현과 비선점 정책까지 직접 확인한 것은 아닌 블랙박스 추론이다.

`futex_do_wait` 하나만으로 교착을 확정할 수는 없다. false 실행에서도 주 스레드 대기가 관측됐지만 보조 스레드의 poll 대기와 작업 로그 갱신이 이어졌다.

## 4. Workaround & Verification

After의 관측 종료 직전 로그:

```text
2026-10-16 17:53:54,966 [INFO] [System] Memory Cache Flushed. Process Stabilized.
2026-10-16 17:54:04,692 [INFO] [CpuWorker] Current Load: 16.85%
2026-10-16 17:54:06,050 [INFO] [MemoryWorker] Current Heap: 75MB
```

| 항목 | Before | After |
| --- | --- | --- |
| MULTI_THREAD_ENABLE | true | false |
| 실행 구간 (+09:00) | 17:34:06–17:44:07 | 17:44:07–17:54:08 |
| worker PID | 17376 | 25579 |
| 실험기 경과 (초) | 601 | 601 |
| 실제 CPU 최대 | 0.00% | 3.96% |
| RSS 범위 (MiB) | 16.39–16.45 | 16.39–516.67 |
| 로그 | 17:34:15 이후 정체 | 종료 직전까지 갱신 |
| 종료 이유 | 600초 정체 후 실험기 TERM | 600초 관측 후 실험기 TERM |
| launcher / monitor 종료 코드 | 143 / 0 | 143 / 0 |

경과 시간에는 준비·종료 처리가 포함된다. 멀티스레드 설정을 끄면 관측 기간 내 순환 대기와 작업 정체를 피했다.
이는 동시 처리 경로를 피하는 우회이며, 락 구현의 근본 수정이나 600초 이후의 안정성을 검증한 결과는 아니다.
