# [Bug] Deadlock - CPU 장애 간섭으로 교착상태 미재현

## 1. Description

2026-10-16 `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=100`을 고정하고 `MULTI_THREAD_ENABLE=true/false`를 비교했다.
true는 24초, false는 27초 만에 CPU 임계치 위반 로그 후 종료됐다. PID가 남는 무응답 상태는 재현되지 않았다.
600초를 관측하기 전에 다른 장애가 먼저 발생했으므로 Deadlock 진단과 회피 효과의 비교는 미검증이다.
이 문서는 조건 변경 전 실행 기록이며, 아래 수치·로그·시각은 당시 결과다.

## 2. Evidence & Logs

원본: `evidence/20261016T164019-exZ12j/{deadlock-before,deadlock-after}/`.
true의 worker는 PID 9504, launcher는 9497이다. 실행 파일·`agent` 소유자·부모 관계·리스너를 확인했다.

`ps -L`의 실제 출력:

```text
2026-10-16T16:51:51+09:00
    PID    PPID     TID STAT WCHAN                                TIME COMMAND
   9504    9497    9504 SN   poll_schedule_timeout.constprop. 00:00:00 agent-leak-app-
```

`system.log`에 기록된 앱 로그 상태:

```text
/home/agent/agent-leak-app/logs/agent_app.log 41473 2026-10-16+16:51:38.4164730060
/home/agent/agent-leak-app/logs/agent_app.log 41729 2026-10-16+16:51:50.9394730120
```

로그는 계속 갱신됐고 마지막에 CPU 임계치 위반이 기록됐다.

```text
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
2026-10-16 16:51:47,810 [INFO] [CpuWorker] Current Load: 38.60%
2026-10-16 16:51:50,940 [INFO] [CpuWorker] Current Load: 43.30%
2026-10-16 16:51:54,067 [INFO] [CpuWorker] Current Load: 52.02%
2026-10-16 16:51:54,173 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.02%).
```

16:51:54의 최종 `ps`에는 worker가 없고 `top`의 대상 태스크도 0개였다.
`result.txt`는 `reason=app_exit`, `launcher_exit=143`, `monitor_exit=0`이다.
실험기의 종료 요청은 없었으며 cgroup OOM·CPU throttling 증가도 없었다.

## 3. Root Cause Analysis

낮은 CPU와 일정한 RSS만으로 Deadlock을 판단할 수 없다. 이번 스레드 관측은 poll 대기였으며,
서로의 락 소유·획득 대기나 순환 대기를 나타내는 증거는 없다. 앱 로그도 계속 갱신되다가 PID가 사라졌다.
부팅 시의 `POTENTIAL DEADLOCK`은 경고이며 발생 증거가 아니다.

Deadlock에는 상호 배제·점유 대기·비선점·순환 대기가 관련되지만 이번 관측에서는 확인하지 못했다.
CPU 임계치 위반에 따른 종료 간섭으로 관측이 끝났으므로 Deadlock 자체의 근본 원인은 분석할 수 없다.

## 4. Workaround & Verification

| 항목 | Before | After |
| --- | --- | --- |
| MULTI_THREAD_ENABLE | true | false |
| worker / launcher PID | 9504 / 9497 | 9891 / 9884 |
| 실행 구간（+09:00） | 16:51:30–16:51:54 | 16:51:54–16:52:21 |
| 실험기 경과 초 | 24 | 27 |
| CPU 최대（한 코어=100%） | 3.96% | 4.95% |
| RSS 범위（MiB） | 16.39–16.45 | 16.38–16.44 |
| 마지막 장애 로그 | CPU Threshold Violated! (52.02%) | CPU Threshold Violated! (52.059999999999995%) |
| Deadlock 진단·회피 | 미검증（CPU 장애 간섭） | 미검증（CPU 장애 간섭） |

false 변경 후의 지속적인 정상 동작이나 Deadlock 회피는 확인하지 못했다.
기존 실행에서는 고정 조건을 변경하지 않았다.

다음 실험에서는 메모리 512·CPU 30을 고정하고 스레드만 true → false로 비교한다.
이 조건은 실행기에 반영했으며 아직 실행하지 않았다. CPU 간섭 감소·교착상태 재현·회피 효과는 미검증이다.
