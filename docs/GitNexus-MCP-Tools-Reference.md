# GitNexus MCP 도구 레퍼런스 (2026-10-06)

Claude Code에 MCP로 연결한 GitNexus(`docs/GitNexus-Code-Intelligence-Server.md` 참고)가 실제로 어떤 도구를 제공하는지, MCP 서버에 직접 질의해서 확인하고 정리한 기록. 서버가 "말해주는" 요약이 아니라 `tools/list`로 받은 실제 스키마를 근거로 썼다.

```bash
# 확인한 방법 -- MCP 세션을 직접 열어서 물어봄
curl -X POST ".../api/mcp" -H "Authorization: Bearer <토큰>" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize",...}'
# 응답 헤더의 Mcp-Session-Id를 받아서
curl -X POST ".../api/mcp" -H "Mcp-Session-Id: <세션>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

총 17개 도구. 현재 인덱싱된 레포 3개: `k3s-msa-infrastructure`, `target-tracking-service`, `threat-intel-ai-service` (c4i-dashboard-frontend는 아직 미포함 — 14번 항목 참고).

## 읽기 전에 — 반복되는 패턴 두 가지

거의 모든 도구 설명에 공통으로 나오는 개념이라 미리 짚어둔다.

**중의성(ambiguous) 처리**: 같은 이름의 심볼이 여러 개 있으면(`context`, `impact`, `rename`, `trace`, `explain`, `pdg_query` 전부 해당), 하나를 임의로 고르지 않고 후보 목록(순위 매겨서)을 돌려준다. `file_path`나 `kind`로 좁히거나, 후보의 `uid`로 재호출하면 정확히 하나를 집을 수 있다.

**"없다"가 "확실히 없다"가 아닐 수 있다 (epistemic)**: `context`/`impact`는 결과에 `epistemic: 'exact' | 'lower-bound'`를 같이 준다. `'lower-bound'`면 지금 보인 숫자가 **바닥값**이라는 뜻 — 정적 분석이 못 따라간 경로가 있어서(동적 디스패치, DI, 콜백에 저장된 함수 등) 실제로는 더 많을 수 있다. `causes` 필드가 왜 못 따라갔는지(리시버 타입 추론 실패, 외부 경계, DI 경계 등) 구체적으로 알려준다. **"호출하는 곳이 0개"라고 바로 "안전하다"고 믿지 말고, `epistemic`부터 확인하는 습관이 필요하다.**

## 코드 탐색/이해

| 도구 | 용도 |
|---|---|
| **`list_repos`** | 인덱싱된 레포 목록(페이지네이션). 여러 레포 중 뭘 대상으로 할지 정할 때 첫 단계. |
| **`query`** | "토큰 검증 흐름이 어디로 이어지는지" 같은 개념 기반 질문으로 실행 흐름(연쇄 호출 "process")을 찾는다. BM25 키워드 + 벡터 검색을 합쳐서(RRF) 랭킹. 파일 매칭이 아니라 "관계"가 필요할 때 — grep/IDE 검색의 보완재. |
| **`context`** | 심볼 하나의 360도 뷰 — 누가 호출하는지/뭘 호출하는지/상속·구현 관계/어떤 execution flow에 참여하는지까지 한 번에. `query`로 넓게 본 다음 특정 심볼을 깊게 볼 때. |
| **`trace`** | 심볼 A→B 최단 경로. "이게 어떻게 저기까지 이어지는지" 수동으로 context를 3~8번 왔다갔다 할 걸 한 번에. 그룹 모드로 **레포 경계를 넘는 추적도 가능**(실험적, 14번 항목 참고). |
| **`cypher`** | 그래프 쿼리 언어로 직접 질의(고급). 스키마는 `gitnexus://repo/{name}/schema` 리소스로 먼저 확인 권장. 순환참조 탐지, DI 주입 관계, 다이아몬드 상속 같은 복잡한 구조 질문에. |

## 변경 전 안전성 체크

| 도구 | 용도 |
|---|---|
| **`impact`** | 심볼을 고치면 어디까지 영향 가는지("blast radius"). d=1(직접 깨짐)/d=2(간접)/d=3(테스트 필요)로 깊이별 분류, `risk: LOW~CRITICAL` 평가까지. **리팩토링 전에 가장 유용한 도구.** |
| **`detect_changes`** | 지금 커밋 안 한 git diff를 분석해서 어떤 execution flow가 영향받는지 자동 추적. 커밋 전 리뷰용. |
| **`rename`** | 여러 파일에 걸친 이름 변경 — 그래프 기반(고신뢰) + 텍스트 검색(저신뢰, 리뷰 필요) 결과를 구분해서 보여줌. 기본은 미리보기. |
| **`check`** | 구조적 검사 — 현재는 모듈 간 순환 import(초기화 순서를 강제하는 것만, 지연 import는 제외) 탐지. |

## API/마이크로서비스 — 지금 구조에 특히 맞는 영역

| 도구 | 용도 |
|---|---|
| **`route_map`** | 프론트엔드 컴포넌트/훅이 어떤 API 엔드포인트를 호출하는지, 그걸 어떤 핸들러가 처리하는지 매핑. |
| **`shape_check`** | 백엔드 응답이 실제로 주는 키 vs 프론트엔드가 접근하는 키를 비교해서 `MISMATCH` 탐지 — 계약 drift(API는 바뀌었는데 소비자는 안 바뀐 상황)를 잡아준다. |
| **`api_impact`** | API 핸들러 고치기 전 리포트 — 소비자가 몇 개인지, 어떤 필드를 쓰는지, 미들웨어는 뭔지, 어떤 execution flow를 트리거하는지까지 `route_map`+`shape_check`+`impact`를 합쳐서 한 번에. 라우트 핸들러 수정 전엔 이걸 먼저. |
| **`tool_map`** | MCP/RPC 도구 정의 매핑(이 문서 자체가 다루는 종류의 것 — 다른 MCP 서버를 운영하게 되면 유용). |
| **`group_list`** / **`group_sync`** | 레포 여러 개를 "그룹"으로 묶어서 서비스 간 계약(HTTP/gRPC/Kafka 토픽)을 교차 링크. 14번 항목에서 실제로 설정한 과정 참고. |

## 보안/데이터플로우 (고급, 현재 비어있음)

| 도구 | 용도 |
|---|---|
| **`explain`** | `gitnexus analyze --pdg`로 분석한 taint(오염 데이터) 흐름 — source→sink(명령 주입/SQL 주입/XSS 등) 경로 설명. |
| **`pdg_query`** | Program Dependence Graph 질의 — "이 줄은 어떤 조건에서 실행되나"(제어 의존), "이 변수가 어디로 흘러가나"(데이터 의존). |

**둘 다 지금은 빈 결과만 돌려준다** — `gitnexus analyze --pdg`로 별도 분석을 돌려야 데이터가 채워지는데, 지금 레포들은 기본 `analyze`(`--pdg` 없이)로만 인덱싱돼 있다. 필요해지면 재분석하면 된다.

## 14. 실제로 해본 것 — `group_sync` 설정

API 계약을 서비스 간에 교차 링크해보려고 `c4i`라는 그룹을 만들어서 레포 3개를 묶었다. 과정에 두 가지 걸렸다.

### 삽질 ① — `group_sync`가 OOMKilled

```
command terminated with exit code 137
```
`kubectl describe pod`로 확인하니 `reason: OOMKilled`. `group_sync`는 그룹에 속한 레포 전부의 인덱스를 **동시에** 열어서 계약을 추출+교차 링크하므로, 레포 하나짜리 `analyze`/`auto-sync`보다 메모리를 더 쓴다. 당시 메모리 한도(1Gi)로는 부족했다 — master 노드 여유(이 시점 약 1.2GB)를 확인하고 **2Gi로 상향**(`apps/gitnexus/deployment.yaml`).

### 삽질 ② — `target-tracking-service` 인덱스가 읽기 전용 복구 상태로 막혀있었음

메모리를 올리고 재시도하니 다른 에러:
```
LadybugDB unavailable for github.com/sm010422/target-tracking-service.
Couldn't replay shadow pages under read-only mode.
Please re-open the database with read-write mode to replay shadow pages.
```
서버 시작 로그에 이미 단서가 있었다: `"quarantined WAL ... because LadybugDB shadow sidecar was missing; continuing from last checkpoint (read-only recovery)"` — 아마 앞서 겪은 OOMKilled(①)가 이 레포의 인덱스를 쓰는 도중에 발생해서, WAL(write-ahead-log)이 완전히 커밋되지 못한 채 남아있었던 것으로 보인다. `gitnexus doctor`는 전체 런타임 상태만 보여주고 개별 레포 복구 기능은 아니었다 — 대신 `gitnexus analyze --force <경로>`로 해당 레포를 강제 재인덱싱(읽기-쓰기 모드로 다시 열림)하니 자연스럽게 복구됐다.

### 결과 — 계약 13개 추출, 교차 링크는 0개 (정상)

```
Matching:
  exact:     0 cross-links
  manifest:  0 cross-links
  wildcard:  0 cross-links
  unmatched: 13 contracts
```
`group_contracts`로 내용을 보면 전부 `[provider]`(HTTP 엔드포인트를 **제공**하는 쪽)뿐이고, `[consumer]`는 `target-tracking-service` 자신이 발행한 Kafka 토픽을 자신이 구독하는 것 하나뿐이다. **이 3개 레포는 전부 API를 제공하는 쪽이라 서로 교차 링크될 게 없다** — 실제로 target-tracking-service의 REST API를 호출하는 건 `c4i-dashboard-frontend`인데, 그 레포가 아직 인덱싱/그룹 등록이 안 돼 있다. 버그가 아니라 지금 그룹 구성이 그런 것.

**다음에 의미 있는 교차 링크를 보려면**: `c4i-dashboard-frontend`를 인덱싱해서 그룹에 추가하면 `route_map`/`api_impact`가 실제로 프론트→백엔드 연결을 보여줄 것으로 예상된다. threat-intel-ai-service가 target-tracking-service와 같은 Kafka 토픽을 구독하는 관계(RAG 색인용)도 왜 안 잡혔는지는 더 봐야 함 — Python 쪽 Kafka consumer 추출 커버리지 문제일 수 있음.

## 사용 예시

Claude Code 세션에서 그냥 자연어로 물어보면 알아서 적절한 도구를 호출한다:

> "GitNexus로 target-tracking-service에서 ThreatAnalysisService를 누가 호출하는지 찾아줘" → `context`
> "이 함수 지우면 뭐가 깨지는지 확인해줘" → `impact`
> "지금 커밋 안 한 변경사항이 어디에 영향 주는지 봐줘" → `detect_changes`
> "/api/v1/threat-analysis/analyze 고치기 전에 영향 범위 알려줘" → `api_impact`

## 관련 문서

- `docs/GitNexus-Code-Intelligence-Server.md` — 서버 배포/운영 전체 기록(접속 URL, 토큰, auto-sync 설정 등)
