# 프로젝트 완성도 분석 (2026-09-23 기준)

이력서/자소서 문구를 쓰기 전에, 실제로 뭐가 강하고 뭐가 비어있는지 정직하게 점검한 기록. 좋은 점만 나열하지 않고, 면접에서 찔릴 수 있는 지점까지 미리 확인해뒀다.

## 요약 표

| 영역 | 수준 | 근거 |
|---|---|---|
| 인프라/CD 자동화 | **강함** | GitOps 풀 파이프라인(빌드→푸시→감지→write-back→sync→롤아웃)을 매 기능 배포마다 실측 검증. 노드별 실측 리소스 기반 배치, `podAntiAffinity` |
| AI 파이프라인 깊이 | **강함** (포트폴리오 기준 상위) | 이중 RAG(pgvector+Qdrant), LangGraph 라우팅, 멀티스텝 tool-calling(3개 도구 체이닝), RAGAS 정량 평가, human-in-the-loop 루프까지 한 사이클 |
| 문서화 | **매우 강함** | 레포별 `docs/concepts/` 수십 개, 의사결정 근거 상시 기록, GitHub→Notion 자동 동기화까지 구축 |
| 관측성 | **절반만 완성** | 앱 계측(`/actuator/prometheus`, `/metrics`)은 있지만 실제 스크레이핑 서버·알림 없음. Gemini 키가 `PLACEHOLDER`로 장기간 방치된 것도 이 공백 때문에 아무도 못 알아챈 것 |
| 테스트 커버리지 | **약함** | 아래 상세 참고 |
| 보안/인증 | **약함** | 아래 상세 참고 |
| 프론트엔드 | **보통~강함** | 실시간 다중 패널 UI, 실제 배포·동작 확인됨. 테스트는 없음 |
| 신뢰성 | **취약했던 이력, 개선 진행 중** | 방치된 Secret, ArgoCD 상태 지연 등 — 전부 "발견해서 고쳤다"는 스토리로 전환 가능하지만, 애초에 발견까지 오래 걸렸다는 건 인정해야 할 사실 |

## 상세 — 테스트 커버리지 (약함)

| 레포 | 테스트 파일 수 | 비고 |
|---|---|---|
| `target-tracking-service` | 2개 (117줄) | `TargetTrackingApplicationTests`(컨텍스트 로드), `TargetServiceTest` 하나뿐. `ThreatAnalysisService`, `ThreatApprovalService` 등 오늘 만든 로직은 테스트 없음 |
| `threat-intel-ai-service` | 0개 | 단위 테스트 자체가 없음. `eval/evaluate_rag.py`(RAGAS)는 있지만 이건 품질 평가지 로직 검증(유닛테스트)이 아님 — `classify_question`의 키워드 폴백, `assess_threat_level`의 규칙, 새로 만든 `tools.py`의 순수 함수들은 Gemini API 없이도 충분히 테스트 가능한데 전혀 안 돼 있음 |
| `c4i-dashboard-frontend` | 0개 | 컴포넌트/훅 테스트 없음 |

포트폴리오 프로젝트에서 테스트 커버리지가 낮은 건 흔하지만, 이 프로젝트는 "엔지니어링 판단력"을 내세우는 포지셔닝을 택했기 때문에("[AX-Portfolio-Positioning-Strategy.md](./AX-Portfolio-Positioning-Strategy.md)" 참고) 이 공백이 상대적으로 더 눈에 띌 수 있다. "왜 테스트가 없나"라는 질문에는 "인프라/파이프라인 검증에 우선순위를 뒀다"는 답이 가능하지만, 방어보다는 실제로 몇 개 채워넣는 쪽이 낫다.

## 상세 — 보안/인증 (약함)

1. **`threat-intel-ai-service`의 CORS가 전체 오리진 허용** (`allow_origins=["*"]`) — 코드에 "데모/로컬 개발 편의, 인증 붙는 순간 좁혀야 함"이라고 이미 스스로 문서화해뒀다는 점은 좋은 신호(의도적 트레이드오프라는 근거가 코드에 남아있음). 다만 실제로 좁혀진 적은 없음.
2. **`defense-api-gateway`(JWT 인증 게이트웨이)가 실제로는 클러스터에 배포조차 안 되어 있음** — ArgoCD Application 목록에도, `kubectl get pods -n c4i`에도 존재하지 않는다. 소스코드와 k8s manifest(Service만, Ingress 없음)는 있지만 실제 트래픽 경로에서 완전히 빠져 있다. README/포트폴리오 문서에서 "JWT 인증을 게이트웨이 레이어에서 처리"라고 언급한 부분이 있다면 **현재 사실과 다르다** — 실제로는 `target-tracking-service`/`threat-intel-ai-service`가 Traefik Ingress에서 바로 노출되고 있고 인증 자체가 없다.

이건 포트폴리오에서 가장 눈에 띄는 "만들어놓고 안 쓰는 컴포넌트" 사례다. 둘 중 하나를 택해야 한다:
- (A) 실제로 게이트웨이를 트래픽 경로에 연결한다 (Ingress를 게이트웨이로 통일하고 인증 미들웨어로 동작시킴)
- (B) 연결하지 않기로 한 이유를 명시적으로 문서화한다 ("개인 프로젝트라 인증 자체의 우선순위가 낮았다" 등)

지금처럼 "존재하지만 안 물려있고 아무 설명도 없는" 상태가 제일 나쁘다 — 면접에서 "이 게이트웨이는 어떻게 쓰이나요?" 질문이 나오면 답할 말이 없다.

## 상세 — 신뢰성 이력

오늘 세션에서 발견한 것만 나열해도:
- `gemini-api-key` Secret이 `"PLACEHOLDER"`로 방치 — 발견 시점까지 정확히 얼마나 오래 지속됐는지 알 방법이 없음 (로그/알림 부재)
- ArgoCD Image Updater가 git write-back은 성공했지만 Application 상태 반영이 지연되는 걸 인지하지 못하면 배포가 "된 줄 알았는데 안 된" 상태로 남을 수 있음

둘 다 "발견해서 고쳤다"는 긍정적 스토리로 쓸 수 있지만, 근본 원인(관측성 공백)은 아직 완전히 안 채워졌다. 상세 진단이 [AX-Portfolio-Positioning-Strategy.md](./AX-Portfolio-Positioning-Strategy.md)에서 언급한 "다음에 손댈 것" 1순위여야 한다.

## 우선순위 제안 (완성도를 실질적으로 올리는 순서)

1. **`defense-api-gateway` 처리** — 연결하거나, 왜 안 했는지 명시. 지금 상태가 제일 설명하기 곤란함
2. **최소 유닛 테스트** — API 호출 없이 검증 가능한 순수 로직부터 (`assess_threat_level`, `check_intercept_asset_availability`, `classify_question` 키워드 폴백, `calculateRuleBasedThreatLevel`) — 반나절이면 충분한 낮은 비용 대비 "테스트가 아예 없다"는 인상을 없애는 효과가 큼
3. **AI 헬스체크 + 알림** — Gemini 키 방치 같은 "조용한 장애"가 재발하지 않도록, 매일 한 번 `/api/v1/threat-analysis/status` 확인해서 실패 시 알림 (이메일/슬랙 등 가벼운 걸로 충분)
4. **Prometheus 스크레이핑 서버** — 리소스 여유가 생기면 (지금은 하드웨어 제약으로 의도적 보류 상태, 이미 문서화됨)

이 중 1·2번은 기술적으로 크지 않은 작업 대비 "완성도" 인상에 미치는 영향이 가장 크다.
