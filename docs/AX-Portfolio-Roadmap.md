# AX 포트폴리오 강화 로드맵

> C4I 방어체계 MSA(target-tracking-service / threat-intel-ai-service / defense-api-gateway / c4i-dashboard-frontend) 기반. "AI를 API로 호출해봤다" 수준을 넘어 "AI가 실제 업무 프로세스를 바꾼다"는 걸 보여주는 방향으로 강화하기 위한 실행 계획.

---

## 현재 구현 완료 현황

| 항목 | 구현 위치 | 비고 |
|---|---|---|
| RAG (실시간 단일 표적 vs 고정 지식베이스) | `target-tracking-service` — Spring AI + pgvector(HNSW) | 10개 위협 패턴 코사인 유사도 검색 → Gemini SITREP 생성 |
| 규칙 기반 위협 등급 사전 평가 | `ThreatAnalysisService` | LLM 호출 전 규칙 기반 등급 산출, AI 미설정 시 단독 동작 (Graceful Degradation) |
| 비동기 AI 분석 | `AsyncConfig` + `analyzeAsync()` | Kafka consumer 스레드 블로킹 방지 (`aiAnalysisExecutor`) |
| 비정형 문서 RAG + 실이력 패턴 탐지 | `threat-intel-ai-service` — LangGraph + Qdrant(2 컬렉션) | `/chat` 하나에서 `doc_rag` / `pattern_search` 분기 |
| Tool calling (모델이 자율 판단) | `threat-intel-ai-service/app/graph/tools.py` | Gemini function-calling으로 `assess_threat_level` 자율 호출 |
| SSE 스트리밍 | `threat-intel-ai-service/routers/chat.py` | 토큰 단위 스트리밍 + `tool_call`/`sources` 이벤트 |
| RAG 정량 평가 | `threat-intel-ai-service/eval/evaluate_rag.py` | RAGAS — faithfulness 0.75~1.0, answer_relevancy 0.87~0.91 |
| AI 챗 프론트엔드 | `c4i-dashboard-frontend/src/components/ChatPanel.tsx` | 대시보드 내 챗 UI |
| K8s 배포/운영 | `k3s-msa-infrastructure` | ArgoCD, Image Updater, `/ai` Ingress, 비용/리소스 실측 문서 |

---

## 강화 방향 (우선순위)

### 1순위 후보였던 것 — 온프레미스/망분리 LLM → **현재 하드웨어로는 상시 운영 불가 (실측 완료)**

**배경:** 방산/국방 AX 공고는 "외부 API(Gemini/OpenAI) 사용 불가, 망분리 환경에서 동작해야 함"이 실제 현업 제약인 경우가 많음. 지금 이 포트폴리오는 전부 Gemini API에 의존 중이라, 로컬 모델(vLLM/Ollama + Qwen/EXAONE 계열)을 하나 띄워 "인터넷 끊긴 환경에서도 동작하는 AI"를 보여주면 도메인과 정확히 맞아떨어지는 스토리가 될 것으로 판단했음.

**2026-09-16 SSH 실측 결과 (`100.112.104.24`, multipass 호스트):**

| 항목 | 값 |
|---|---|
| 호스트 | Mac mini, Apple M2 (8-core CPU: 4P+4E, 8-core GPU) |
| 호스트 통합 메모리 | **8GB** (macOS는 CPU/GPU가 메모리를 공유) |
| 호스트 디스크 | 228GB 중 여유 63GB |
| `k3s-master` VM | 2 vCPU / 메모리 할당 2.9GiB (사용 중 1.3GiB, load avg 1.38) |
| `k3s-worker1` VM | 1 vCPU / 메모리 할당 1.4GiB (사용 중 970MiB) |
| `k3s-worker2` VM | 1 vCPU / 메모리 할당 1.7GiB (사용 중 1.3GiB, load avg 1.28) |
| VM 총 할당 | 4 vCPU / **약 6GB** (호스트 8GB 중) |

**결론:** k3s 클러스터(VM 3개)만으로 이미 8GB 중 6GB를 점유하고 있어서, macOS 자체 오버헤드를 빼면 로컬 LLM을 위한 여유 메모리가 사실상 없다. 7B~8B급 양자화 모델조차 GGUF Q4 기준 최소 4~5GB가 필요해서 지금 구성으로는 상시 기동이 불가능. Apple Silicon Mac mini는 통합 메모리 특성상 사후 RAM 증설도 안 됨.

**대안 (택1, 또는 조합):**

| 옵션 | 설명 | 트레이드오프 |
|---|---|---|
| A. VM 메모리 다이어트 후 초소형 모델 상시 구동 | `multipass set` 으로 worker 메모리를 줄여 1~2GB 확보 → Qwen2.5-0.5B/1.5B-Instruct(Q4) 같은 초소형 모델을 호스트에서 직접(VM 밖) 구동 | 모델이 너무 작아 실용적 답변 품질은 기대하기 어려움. "동작 증명" 수준의 데모용 |
| B. 데모 시점에만 임시 기동 | 평소엔 꺼두고, 시연 때만 k3s worker 1개를 잠시 내리고 그 자리에 Ollama로 7B급 모델을 임시 기동 | 상시 운영은 아니지만 "실제로 로컬에서 돌아간다"는 걸 증명 가능. 포트폴리오/면접 데모용으로는 충분 |
| C. 별도 머신 확보 | 클라우드 GPU 인스턴스(스팟)나 다른 로컬 머신(RAM 16GB+)에 별도로 LLM 서빙 컨테이너를 올려 threat-intel-ai-service가 필요시 그쪽 엔드포인트로 라우팅 | 인프라가 하나 더 늘어남. 다만 "모델 라우팅(클라우드 API ↔ 온프레미스 LLM)" 자체가 새로운 스토리가 됨 |
| D. 방향 자체를 재우선순위 | 하드웨어 제약을 그대로 스토리로 활용: "8GB 엣지 환경에서 로컬 LLM 서빙이 왜 어려운지 실측하고, 대신 클라우드-온프레미스 하이브리드 라우팅을 설계했다"는 분석 자체를 문서화 | 구현 없이도 엔지니어링 판단력을 보여줄 수 있음. 단, "직접 돌려봤다"는 임팩트는 약함 |

**재평가:** 지금 하드웨어 그대로는 1순위로 밀어붙이기 부담스럽다. B(데모용 임시 기동)가 구현 난이도 대비 가장 현실적이고, 그 다음으로 아래 2·3순위를 먼저 진행하는 편이 ROI가 높다.

---

### 2순위 — Human-in-the-loop 의사결정 루프 ✅ 구현 완료 (2026-09-16)

지금은 AI가 SITREP/위협등급을 "생성"하는 데서 끝난다. AX의 핵심은 그 결과가 실제 업무(승인/반려/에스컬레이션)에 연결되는 것.

- AI가 CRITICAL 판단 → 담당자에게 승인 요청 → 승인/반려 로그 적재
- 이 로그가 다시 평가 데이터셋으로 축적되는 피드백 루프
- "AI 판단 → 사람 승인 → 데이터 축적"이라는 AX 전형적 서사 완성
- 하드웨어 제약과 무관하게 지금 스택(Spring + Kafka + Qdrant)만으로 구현 가능

**구현 내용:**

| 위치 | 내용 |
|---|---|
| `target-tracking-service/domain/approval/*` | `ThreatApproval` 엔티티/리포지토리/DTO/서비스/컨트롤러 신규 |
| `ThreatAnalysisService.analyze()` | HIGH/CRITICAL 판정 시 `ThreatApprovalService.createIfNeeded()` 자동 호출 (REST 수동 분석·Kafka 자동 분석 둘 다 커버) |
| `POST /api/v1/threat-approvals/{id}/decide` | 승인/반려 + 결정자/사유 기록 |
| `/topic/approvals` (STOMP) | 승인 요청 생성·결정을 실시간 브로드캐스트 |
| `c4i-dashboard-frontend/hooks/useApprovalSocket.ts` | REST 초기 로드 + WebSocket 실시간 반영 |
| `c4i-dashboard-frontend/components/ApprovalPanel.tsx` | 대시보드 좌측 승인 대기 패널, 헤더에 대기 건수 배지 |
| `target-tracking-service/docs/threat-approval.md` | 설계 근거·API·WebSocket 스펙 문서화 |

백엔드 `./gradlew compileJava`/`compileTestJava`, 프론트 `tsc --noEmit`/`eslint` 검증 완료. 로컬에서 `docker compose up`으로 실행 후 대시보드에서 "AI 위협분석" 버튼을 눌러 HIGH/CRITICAL이 나오면 좌측 승인 패널에 뜨는지 확인 필요 (아직 브라우저 수동 검증 전).

### 3순위 — 관측성/평가 파이프라인 고도화 ✅ 구현 완료 (2026-09-22)

- RAGAS 1회성 실행 → CI에 golden dataset 기반 회귀 평가 자동화
- LLM 호출 latency/cost/토큰 사용량 Prometheus 노출
- "프로덕션에서 AI 품질을 지속 관리하는 역량" 어필

**착수 전 재확인한 전제 하나가 틀렸다**: "이미 K8s + 모니터링 기반 있음"이라고 썼었는데, 실제로 확인해보니 클러스터에 Prometheus/Grafana는 아예 없었고 (`kubectl top` 기준) worker 노드가 이미 메모리 70%대·load average가 vCPU 수를 넘는 상태였다. 1순위(온프레미스 LLM)를 막았던 것과 같은 하드웨어 제약이 여기도 걸려서, **Prometheus/Grafana 서버를 새로 배포하는 건 하지 않고, 앱 쪽만 Prometheus 포맷으로 계측**하는 선에서 스코프를 조정했다. 또한 RAGAS를 "PR마다 자동 실행"하려던 원래 계획도, Gemini 무료 tier 일일 쿼터가 워낙 낮아서(이미 이 프로젝트 여러 곳에서 실측된 제약) 자동 트리거 대신 `workflow_dispatch` 수동 트리거로 바꿨다.

**구현 내용:**

| 위치 | 내용 |
|---|---|
| `target-tracking-service` build.gradle/application.yaml | `micrometer-registry-prometheus` 추가, `/actuator/prometheus` 노출 |
| `ThreatAnalysisService` | `threat_ai_analysis_total`(disabled/success/failure), `threat_ai_llm_call_duration_seconds` 계측 |
| `ThreatApprovalService` | `threat_approval_requested_total`, `threat_approval_decided_total`, `threat_approval_time_to_decision_seconds`(승인 대기 시간) 계측 — 2순위 human-in-the-loop 루프와 직결되는 지표 |
| `target-tracking-service/docs/observability.md` | 지표 목록 + Prometheus/Grafana 미배포 결정 근거 문서화 |
| `threat-intel-ai-service/app/metrics.py` + `main.py`/`chat.py` | `prometheus-client`로 `/metrics`, `/ai/metrics` 노출 — 라우팅 분포, tool-call 횟수, RAG 검색 지연시간 |
| `threat-intel-ai-service/eval/evaluate_rag.py` | `--fail-below` 임계값 옵션 추가 (평균 faithfulness/answer_relevancy 미달 시 non-zero exit) |
| `threat-intel-ai-service/.github/workflows/eval.yml` | RAGAS 회귀 평가 CI 워크플로, `workflow_dispatch` 수동 트리거 (`gh workflow run eval.yml`) |
| `threat-intel-ai-service/docs/observability.md` | 왜 자동 트리거를 안 했는지 근거 + 실행 방법 문서화 |

백엔드 `./gradlew compileJava` 통과, Python 쪽은 `py_compile`로 문법 검증 완료 (레포에 이미 있던 `.venv`가 `cohere` 등 일부 의존성이 안 깔려 있어 전체 import는 못 돌렸음 — 기존 상태이지 이번 변경으로 생긴 문제 아님). RAGAS CI 워크플로는 저장소에 `GEMINI_API_KEY` 시크릿이 없어서 아직 실행 전 (`gh secret set GEMINI_API_KEY` 필요).

### 4순위 — 에이전트 확장 (도구 추가, 멀티스텝 플래닝) ✅ 구현 완료 (2026-09-23)

- 지금 tool은 `assess_threat_level` 1개 → "유사 사례 검색 → 대응 절차 문서 조회 → 요격 자산 가용성 확인" 같은 멀티스텝 플래닝 에이전트로 확장
- "라우팅"을 넘어 "플래닝"을 보여줌

**착수 전 질문에 대한 답**: 하드웨어 제약은 없음(순수 애플리케이션 로직, 새 파드/인프라 불필요). 비용/쿼터 제약은 있음 — 멀티스텝 도구 호출은 요청 하나가 LLM 호출을 여러 번 연쇄로 쓸 수 있는 구조라, Gemini 무료 tier 쿼터를 이미 여러 번 실측으로 소진해본 이 프로젝트 특성상 상한이 필요했다. `MAX_TOOL_STEPS = 3`으로 요청당 최악의 경우도 못박아서 구현.

**구현 내용:**

| 위치 | 내용 |
|---|---|
| `threat-intel-ai-service/app/graph/tools.py` | 도구 2개 신규 추가 — `lookup_response_procedure`(기존 `threat_documents` 검색 재사용), `check_intercept_asset_availability`(요격 자산 가용성, **시뮬레이션 데이터**) |
| `threat-intel-ai-service/app/llm/gemini_client.py` | `call_with_tools()`를 단일 턴 → `ChatSession` 기반 멀티턴 루프로 재작성. 매 스텝마다 모델이 도구를 더 부를지 텍스트로 답할지 스스로 판단, 최대 3스텝 |
| `threat-intel-ai-service/app/graph/nodes.py` | `assess_threat_node`를 async로 변경, `tool_call: dict\|None` → `tool_calls: list[dict]` |
| `threat-intel-ai-service/app/routers/chat.py` | `event: tool_call`을 0~3번 순서대로 SSE 스트리밍, Prometheus 카운터도 호출마다 증가 |
| `c4i-dashboard-frontend` (`types/target.ts`, `ChatPanel.tsx`) | 도구 호출을 배열로 누적해서 "N단계: 도구명 → 결과" 형태로 순서대로 렌더링 |
| `threat-intel-ai-service/docs/agent-planning.md` | 설계 근거 + 이전 구조와의 차이 + SSE 프로토콜 변화 문서화 |

Python `py_compile` + 모듈 임포트 검증 완료(순환 임포트 1건 발견해서 지연 임포트로 수정), 프론트 `tsc --noEmit`/`eslint` 통과. 라이브 클러스터 배포·실제 멀티스텝 호출 검증은 아래 "다음 액션" 참고.

**부록 — 3순위 검증 중 발견한 별개 이슈**: 라이브 클러스터의 k8s Secret(`target-tracking-secrets`의 `gemini-api-key`)이 실제 키가 아니라 문자 그대로 `"PLACEHOLDER"`로 방치돼 있어서, 대시보드의 AI 기능(SITREP/챗봇)이 전부 규칙 기반 폴백으로만 동작 중이었다. 사용자가 실제 키를 제공해서 2026-09-23에 Secret을 patch하고 두 서비스를 재시작해 해결 — 이번 3·4순위 작업과는 무관한 기존 운영 이슈였지만, 검증 과정에서 발견해서 같이 고쳤다.

---

## 다음 액션

- [x] 2순위(Human-in-the-loop) 구현 — 승인/반려 엔티티, API, 프론트 UI 완료 (2026-09-16), 라이브 클러스터 배포·검증 완료
- [ ] 2순위 브라우저 수동 검증 — 대시보드 UI에서 실제로 승인/반려 클릭까지 눈으로 확인 (API/배포는 검증됐지만 프론트 클릭 플로우는 아직)
- [x] 3순위(관측성/평가 파이프라인) 구현 — Prometheus 계측 + RAGAS CI 게이트 완료 (2026-09-22)
- [ ] 3순위 후속 — `gh secret set GEMINI_API_KEY` 등록 후 `gh workflow run eval.yml`로 실제 CI 게이트 1회 실행해서 통과 확인
- [ ] 4순위(에이전트 확장) 착수
- [ ] 1순위(온프레미스 LLM)는 옵션 B(데모용 임시 기동)로 축소 재정의, 별도 브랜치/시점에 진행
