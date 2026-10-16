# Linux 프로세스 장애 분석

Ubuntu 22.04 ARM64에서 제공 앱의 OOM·CPU·Deadlock을 관측하고 환경변수 변경 전후를 비교한다.
보고서는 [OOM](docs/issues/oom.md), [CPU](docs/issues/cpu.md), [Deadlock](docs/issues/deadlock.md) Markdown 파일로 제출한다.

## 실행

Docker Desktop을 실행하고 `agent-app-leak/agent-leak-app-arm64`를 준비한다. 호스트의 저장소 디렉터리에서 실행한다.

```bash
docker compose build
docker compose up -d
docker compose exec --user root agent bash /workspace/scripts/setup.sh
mkdir -p evidence
docker inspect codyssey-b4-2-agent-1 > evidence/docker-before.json
docker compose exec --user agent agent bash /workspace/scripts/run_experiments.sh
docker inspect codyssey-b4-2-agent-1 > evidence/docker-after.json
docker compose cp agent:/home/agent/agent-leak-app/evidence/. evidence/
```

실행기는 최대 600초씩 6회를 순차 관측한다. 앱이 먼저 종료되면 기록·정리 후 다음 실행으로 넘어간다.
컨테이너 시작 시 setup·앱은 자동 실행되지 않는다. 접근은 `docker compose exec --user agent agent bash`를 사용한다.

```bash
docker compose down
```

종료 후에도 `codyssey-b4-2_app_data` 볼륨의 키·업로드·로그·증거는 남는다. 재생성 후 setup을 다시 실행한다. `down -v`는 사용하지 않는다.

## 환경과 스크립트

컨테이너에는 호스트 공개 포트·추가 capability·SSH·cron이 없다. 앱·monitor·실험은 일반 계정 `agent`로 실행한다.
setup만 계정·디렉터리·파일 설치에 관리자 권한을 사용한다. 원본 ARM64·x86 파일은 변경하지 않으며 ARM64만 실행한다.

| 변수 | 값 |
| --- | --- |
| `AGENT_HOME` | `/home/agent/agent-leak-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` |
| `AGENT_LOG_DIR` | `$AGENT_HOME/logs` |

키는 `api_keys/secret.key`의 테스트 값 `agent_api_key_test` 한 줄이다.
setup은 기존 키·설치 바이너리가 일치하면 보존하고, 다르면 덮어쓰지 않고 중단한다.
공통 경로는 Compose에서 지정하며 스크립트는 해당 환경을 사용한다.

| 스크립트 | 역할 |
| --- | --- |
| [setup.sh](scripts/setup.sh) | OS·도구·의존성 확인, 계정·경로·키·바이너리 준비, 일반 계정 접근 확인 |
| [monitor.sh](scripts/monitor.sh) | `monitor.sh <pid> <evidence_dir>`로 CPU·RSS와 프로세스·스레드 상태 관측 |
| [run_experiments.sh](scripts/run_experiments.sh) | 실행별 환경 지정, worker 식별, 관측·종료·증거 보존 |

## 다음 실험 조건 (미실행)

| 실행 | MEMORY_LIMIT (MB) | CPU_MAX_OCCUPY (%) | MULTI_THREAD_ENABLE |
| --- | ---: | ---: | --- |
| OOM Before | 50 | 30 | false |
| OOM After | 512 | 30 | false |
| CPU Before | 512 | 100 | false |
| CPU After | 512 | 30 | false |
| Deadlock Before | 512 | 30 | true |
| Deadlock After | 512 | 30 | false |

기존 로컬 기록에서도 10 설정은 cooldown을 반복했고 100 설정은 CPU 임계치 위반 로그 후 종료됐다.
이에 OOM·Deadlock에서는 CPU 장애 간섭을 줄이도록 30을 고정하고, CPU에서는 100과 30을 비교한다.
30 설정의 효과는 아직 이 환경에서 검증하지 않았다. 앱 표시 부하와 실제 OS CPU 사용률은 계속 구분한다.

## 측정과 증거

- CPU: `/proc/<pid>/stat`의 `utime + stime` 증가량 ÷ `CLK_TCK` ÷ `/proc/uptime` 경과 초 × 100. 한 코어가 100%이며 멀티스레드는 초과할 수 있다. 첫 표본은 `NA`다.
- RSS: `/proc/<pid>/status`의 `VmRSS`(KiB) ÷ 1024 = MiB. 앱 내부 메모리 한도 계산과 다를 수 있다.
- 측정은 약 1초 간격이며 실제 간격으로 CPU를 계산한다. `ps`·`top`·`ps -L`·앱 로그 상태는 시작·10초 간격·마지막 가능한 시점에 저장한다. `top`은 보조 증거다.
- 리슨 PID의 실행 파일·소유자·프로세스 그룹과 부모 관계를 확인한다. worker 한 개의 RSS를 측정하며 launcher와 합산하지 않는다.
- 날짜·시각은 `+09:00`으로 기록한다. 원본 증거는 볼륨의 `evidence/<session>/<case>`와 호스트의 ignored `evidence/`에 보존한다.
- 실행별 `settings.txt`, `samples.tsv`, `application.out`, `system.log`, `result.txt`, 진단 파일을 보존한다. 앱 로그도 실행 종료마다 복사한다.
- `app_exit`, `timeout`, `interrupted`, `startup_failure`, `automation_failure`를 구분한다. timeout·중단 시 현재 실험 그룹에만 TERM을 요청하고 5초 후 필요하면 KILL한다.
- 실행기 성공은 관측·기록·정리 완료를 뜻한다. 장애 재현·우회 효과는 보고서의 증거로 별도 평가한다.

## 기존 실행 기록과 이번 변경의 검증 범위

아래는 변경 전 코드(`49c6cda`)의 실행 기록이다. 보고서의 기존 설정·수치·시각은 보존했다.
이번 변경은 `bash -n`과 `git diff --check`로 정적 확인만 했으며 Docker·setup·앱·실험은 실행하지 않았다.

기존 기록에서는 2026-10-16 Ubuntu 22.04.5·aarch64·`agent`(UID 2001)로 검증했다.
세 스크립트의 `bash -n`, Compose 설정, 라이브러리 해결, 실제 앱의 6단계 Boot·로그 초기화·리스너 확인을 통과했다.
setup 재실행·컨테이너 재생성 전후, 실험 로그·증거·키를 포함한 모든 파일의 SHA-256이 일치했다. 키 충돌 시 보존·중단은 별도 임시 컨테이너에서 확인했다.

| 검증 | 결과 |
| --- | --- |
| 고정 6회 기록·정리 | 완료. monitor는 전부 종료 코드 0, 최종 앱 PID·15034 리스너 없음 |
| OOM (CPU 설정 100 고정) | 50MB에서 MemoryGuard 종료. 512MB는 CPU 장애 간섭으로 회피 비교 불완전 |
| CPU (설정 10 → 100) | 10 설정은 600초 관측 후 실험기가 종료. 100 설정은 앱 CPU 임계치 로그 후 종료. OS 과점유·Watchdog 미입증 |
| Deadlock (CPU 설정 100 고정) | true/false 모두 CPU 장애로 먼저 종료. 교착상태·회피 효과 미검증 |

앱 자체 종료와 timeout 처리는 실제 실행으로 확인했다. 중단·강제 KILL·수집 실패 처리는 코드 검토만 했으며 고의 장애 주입은 하지 않았다.
CPU Before의 `elapsed_s=601`은 600초 관측과 종료 처리를 포함한다. 경과 초는 종료 검출·기록까지의 값이며 정밀한 종료 신호 시각은 아니다.

| 증상 | 확인·조치 |
| --- | --- |
| Docker 연결 실패 | Docker Desktop과 `docker context show` 확인 |
| OS·아키텍처·라이브러리 오류 | 이미지 재빌드, `uname -m`, `ldd` 확인 |
| 키 충돌·접근 실패 | 기존 파일을 보존한 채 내용·소유자·권한 확인 후 재준비 |
| 15034 사용 중 | `ss -ltnp`로 해당 프로세스 확인. 이름·포트 기준 일괄 종료 금지 |
| 부팅·수집·기록·정리 실패 | 해당 실행의 출력·증거 확인 후 중단 원인 해결 |

컨테이너별 CPU·메모리 한도는 추가하지 않는다. Docker Desktop VM 자원을 공유하므로 호스트의 `docker inspect`와 컨테이너 cgroup 진단을 함께 확인한다.
커널 로그 조회가 거부되면 그 한계를 기록한다. 종료 코드만으로 커널 OOM이나 특정 종료 신호를 단정하지 않는다.
다음 실행에서도 표의 설정을 도중에 바꾸지 않는다. 다른 장애가 먼저 발생하거나 600초 내 재현되지 않으면 간섭·미재현으로 보고하며 자동 추가 실행하지 않는다.
