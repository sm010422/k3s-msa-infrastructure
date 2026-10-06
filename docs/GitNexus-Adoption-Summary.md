# GitNexus 도입 요약 — 왜 했고, 뭘 얻었나 (2026-10-06)

세부 삽질 기록은 `docs/GitNexus-Code-Intelligence-Server.md`, `docs/GitNexus-MCP-Tools-Reference.md`, `docs/GitNexus-Web-UI-Guide.md` 세 문서에 다 있다. 이 문서는 **그걸 다 다시 읽지 않아도 "결국 왜 했고 뭘 얻었는지"가 바로 잡히게** 하려고 따로 뺀 요약.

## 왜 시작했나 — 솔직한 경위

처음 동기는 "토큰을 아끼자"나 "서비스 간 의존성을 추적하자" 같은 거창한 계획이 아니었다. 단순히 **GitNexus의 웹 UI 서버를 k3s 클러스터에 상시 서비스로 띄우고 싶다**는 인프라 구축 요청에서 시작했다. 배포하고, 디스크 장애를 겪고 VM을 키우고, MCP를 연결하고, 레포 그룹을 묶어보면서 — 하다 보니 "이게 실제로 꽤 쓸모 있다"는 게 나중에 드러난 것에 가깝다. 처음부터 ROI를 계산하고 시작한 프로젝트는 아니었다는 걸 분명히 해둔다.

## 전체 여정 (한 줄 요약 + 상세 문서 링크)

1. **웹 UI 서버를 `tools` 네임스페이스에 배포** — NodePort(내부 전용), `k3s-master`에 의도적 배치. (`GitNexus-Code-Intelligence-Server.md` 1~6번)
2. **디스크 100% 장애** → 원인은 "쌓이는 구조"가 아니라 VM 디스크가 애초에 너무 작았던 것 → 세 노드 전부 10~13GB에서 29GB로 리사이즈. (같은 문서 7~8번)
3. **MCP를 Claude Code에 연결** — `claude mcp add`로 등록, 예전에 남아있던 별개의 로컬 stdio 등록과의 스코프 충돌 정리. (`GitNexus-MCP-Tools-Reference.md`)
4. **웹 UI는 기본적으로 로컬 전용이라는 걸 발견** — 포트포워딩 없이 쓰려고 리버스 프록시까지 고려했다가, `localStorage`에 서버 주소 한 번만 저장하면 읽기(그래프 열람)는 포트포워딩 없이 된다는 걸 알아내서 프록시는 안 만들기로 함. 쓰기(새 레포 분석)만 여전히 로컬 전용. (`GitNexus-Code-Intelligence-Server.md` 12~13번)
5. **레포 3개(k3s-msa-infrastructure, target-tracking-service, threat-intel-ai-service)를 auto-sync로 묶어서 상시 자동 인덱싱**.
6. **`group_sync`로 서비스 간 API 계약 교차 링크** — 아래 요약 참고.
7. **깊게 중첩된 파일이 가끔 안 열리는 업스트림 버그 발견·기록** (우리가 고칠 수 있는 부분 아님). (`GitNexus-Code-Intelligence-Server.md` 15번)
8. **웹 UI 전체를 직접 눌러보고 사용법 문서화** — 그래프/Cypher 콘솔/Processes 탭/Nexus AI 챗봇. (`GitNexus-Web-UI-Guide.md`)

## `group_sync` 과정 요약

**목적**: 레포 여러 개에 흩어진 HTTP/Kafka 등 API 계약을 자동으로 추출해서, "이 레포의 엔드포인트를 저 레포의 어떤 코드가 호출하는지"를 교차 링크하는 기능.

**1차 시도 (레포 3개, 전부 백엔드)** — 두 번 걸림:
- `OOMKilled`(메모리 1Gi 한도 초과, 레포 전체를 동시에 열어서 분석하니 단일 레포 analyze보다 더 씀) → **2Gi로 상향**
- `target-tracking-service` 인덱스가 "읽기 전용 복구" 상태로 막힘(아마 위 OOM이 쓰기 도중 터져서 WAL이 덜 커밋됨) → `gitnexus analyze --force`로 재인덱싱해서 복구

결과: **계약 13개 추출, 교차 링크 0개.** 버그 아님 — 묶은 3개가 전부 API를 "제공"하는 쪽이라 서로 연결될 상대가 없었다. 실제 호출자(`c4i-dashboard-frontend`)가 빠져있었음.

**2차 — `c4i-dashboard-frontend` 추가**: 전용 배포키 새로 생성·등록, auto-sync 대상에 추가, 그룹에 합류 → 재sync.

결과: **계약 19개, 교차 링크 5개 성공.** 프론트엔드의 실제 fetch 호출이 백엔드의 실제 라우트와 정확히 매칭됨(`runSwarmScenario`→`/api/simulator/swarm` 등, 이번 세션에서 만든 기능 포함). `/chat`↔`/ai/chat`(Traefik이 런타임에 붙이는 접두사라 정적 분석으론 못 봄) 하나만 알려진 한계로 남음.

## 실제로 얻은 것 — 우선순위대로

### 1순위 — 서비스 경계를 넘는 의존성 추적 (가장 큰 소득)
레포 4개로 쪼개진 이 프로젝트(프론트엔드/백엔드 2개/인프라)에서, "이 API 고치면 프론트엔드 어디가 깨지는지"를 **사람이 레포 여러 개를 직접 열어서 대조하지 않고도 구조적으로 확인**할 수 있게 됐다. 5개 교차 링크로 실증까지 끝냄. 이건 단일 레포 안에서의 코드 이해(grep으로도 어느 정도 되던 것)와는 성격이 다른, **레포 경계를 넘는 건 원래 수동으로 잘 안 되던 작업**이라 가장 가치가 크다.

### 2순위 — Claude Code(나)가 구조적으로 질의 가능
`context`/`impact`/`query`/`trace` 등으로, 여러 번의 Grep/Read를 거쳐 추론하던 걸 한 번의 질의로 받는다. 부수적으로 토큰도 아끼지만, 더 중요한 건 **정확도** — grep이 놓치는 간접 호출/동적 디스패치 관계를 그래프는 구조적으로 잡는다.

### 3순위 — 변경 전 안전성 체크
`impact`/`detect_changes`/`api_impact`로 "이거 고치면 뭐가 깨지는지"를 리팩토링/커밋 전에 미리 확인 가능.

### 4순위 — 사람이 직접 탐색 가능한 웹 UI
그래프 시각화, Processes 탭(자동 감지된 실행 흐름 — DMZ 스웜 기능도 자동으로 하나의 흐름으로 잡힘), Cypher 콘솔, 자체 챗봇(Nexus AI, 본인 LLM 키로).

### 5순위 — 유지보수 부담이 거의 없음
auto-sync가 30분마다 4개 레포를 전부 자동 재동기화 — 수동으로 재인덱싱할 일이 거의 없다.

## 아직 못 받은 것 / 한계 (정직하게)

- **보안 취약점(taint) 분석 비어있음** — `gitnexus analyze --pdg`로 별도 재분석해야 채워지는데 아직 안 돌림
- **`/chat`↔`/ai/chat` 교차 링크 안 잡힘** — Traefik 프록시 접두사 때문에 정적 분석 한계
- **threat-intel-ai-service의 Kafka 토픽 구독 관계 안 잡힘** — 왜 안 잡혔는지는 아직 조사 안 함
- **웹 UI 쓰기 작업(새 레포 분석)은 여전히 포트포워딩 필요** — 다만 auto-sync가 기존 4개를 다 관리하고 있어서 실제로 이 제약에 부딪힐 일은 거의 없음
- **깊게 중첩된 파일이 웹 UI Code Inspector에서 가끔 안 열림** — 업스트림(GitNexus 자체) 버그, 우리가 못 고침

## 한 줄 결론

**흩어져 있던 레포 4개를, 서로 연결된 하나의 시스템처럼 다룰 수 있게 됐다** — 특히 "이걸 고치면 다른 서비스 어디가 깨지는지"를 실제 증거(5개 교차 링크)를 갖고 답할 수 있게 된 게 핵심이다. 토큰 절약은 그 과정에서 따라오는 부수 효과이지, 애초의 목적도 가장 큰 이득도 아니었다.

## 관련 문서

- `docs/GitNexus-Code-Intelligence-Server.md` — 배포/운영 전체 기록 (디스크 장애, VM 리사이즈, 보안 발견 포함)
- `docs/GitNexus-MCP-Tools-Reference.md` — MCP 도구 17개 레퍼런스 + group_sync 상세 로그
- `docs/GitNexus-Web-UI-Guide.md` — 웹 UI 사용법
