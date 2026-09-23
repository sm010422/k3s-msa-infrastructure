# 프로젝트 완성도 분석 (2026-09-23 기준)

이력서/자소서 문구를 쓰기 전에, 실제로 뭐가 강하고 뭐가 비어있는지 정직하게 점검한 기록. 좋은 점만 나열하지 않고, 면접에서 찔릴 수 있는 지점까지 미리 확인해뒀다.

## 요약 표

| 영역 | 수준 | 근거 |
|---|---|---|
| 인프라/CD 자동화 | **강함** | GitOps 풀 파이프라인(빌드→푸시→감지→write-back→sync→롤아웃)을 매 기능 배포마다 실측 검증. 노드별 실측 리소스 기반 배치, `podAntiAffinity` |
| AI 파이프라인 깊이 | **강함** (포트폴리오 기준 상위) | 이중 RAG(pgvector+Qdrant), LangGraph 라우팅, 멀티스텝 tool-calling(3개 도구 체이닝), RAGAS 정량 평가, human-in-the-loop 루프까지 한 사이클 |
| 문서화 | **매우 강함** | 레포별 `docs/concepts/` 수십 개, 의사결정 근거 상시 기록, GitHub→Notion 자동 동기화까지 구축 |
| 관측성 | **스크레이핑 서버만 남음** | 앱 계측(`/actuator/prometheus`, `/metrics`)에 더해 매일 실동작 헬스체크(`ai-health-check.yml`) 추가 완료. Prometheus/Grafana 서버 자체만 하드웨어 제약으로 의도적 보류 |
| 테스트 커버리지 | **개선됨** (2026-09-23) | 백엔드 2개 레포 + 프론트엔드까지 3개 레포 전부 CI 게이트 연결 완료 (아래 상세) |
| 보안/인증 | **약함, 원인 규명·문서화 완료** | 아래 상세 참고 — `defense-api-gateway` 미배포는 하드웨어 제약으로 확정 |
| 프론트엔드 | **강함** | 실시간 다중 패널 UI, 실제 배포·동작 확인됨. Vitest 유닛테스트 + CI까지 연결 완료 |
| 신뢰성 | **재발 방지 장치 추가** | 방치된 Secret, ArgoCD 상태 지연 등을 "발견해서 고쳤다"에서 멈추지 않고, 매일 실동작 헬스체크로 같은 유형의 조용한 장애를 재발 시 감지하도록 조치 |

## 상세 — 테스트 커버리지 (2026-09-23 개선)

착수 전 상태와 조치:

| 레포 | 착수 전 | 조치 |
|---|---|---|
| `target-tracking-service` | 테스트 2개(117줄) 있었지만 **CI에서 한 번도 실행된 적 없음** — `Dockerfile`이 `./gradlew bootJar -x test`로 테스트를 건너뛰고 빌드, `deploy.yml`도 별도 테스트 단계 없이 바로 Docker 빌드로 직행 | `ThreatAnalysisServiceTest`(규칙 기반 위협 등급 표 전체 파라미터라이즈드 테스트, MILITARY 상태 escalate, AI 비활성화 시에도 승인 훅이 호출되는지), `ThreatApprovalServiceTest`(생성 게이팅, 중복 방지, decide 검증/예외) 추가. `TargetTrackingApplicationTests`(실제 Postgres 연결 필요)는 `@Tag("integration")`으로 분리해 CI에선 기본 제외, `deploy.yml`에 `test` job 신설해서 `build-and-push`를 게이트 |
| `threat-intel-ai-service` | 단위 테스트 0개 | `tests/test_tools.py`(`assess_threat_level` 규칙표, `check_intercept_asset_availability` 시뮬레이션 데이터 형식), `tests/test_gemini_client.py`(`classify_question` 키워드 폴백) 추가. `requirements-test.txt`(pytest, 프로덕션 이미지엔 미포함)로 분리, `deploy.yml`에 `test` job 신설해서 게이트 |
| `c4i-dashboard-frontend` | 0개, CI 자체가 없었음(Vercel Git 연동만 존재) | 훅/컴포넌트에 인라인돼 있던 순수 로직(`inBounds`, `appendHistory`, `derivePendingApprovals`)을 `src/lib/`로 추출해 Vitest로 테스트, 기존 `sse.ts` 파서도 함께 테스트. `.github/workflows/test.yml` 신설(타입체크+린트+테스트, push/PR마다) — 단, Vercel 배포 자체를 막지는 못함(그 파이프라인이 GitHub Actions를 안 씀) |

이제 두 백엔드 레포 모두 **테스트 실패 시 Docker 빌드/배포 자체가 막힌다** — 전에는 테스트가 있어도 없는 것과 마찬가지였는데, 지금은 실제로 배포 게이트 역할을 한다. 프론트엔드 테스트는 아직 손 안 댐 (아래 우선순위 참고).

## 상세 — 보안/인증

1. **`threat-intel-ai-service`의 CORS가 전체 오리진 허용** (`allow_origins=["*"]`) — 코드에 "데모/로컬 개발 편의, 인증 붙는 순간 좁혀야 함"이라고 이미 스스로 문서화해뒀다는 점은 좋은 신호(의도적 트레이드오프라는 근거가 코드에 남아있음). 다만 실제로 좁혀진 적은 없음. (미해결)
2. **`defense-api-gateway`(JWT 인증 게이트웨이)가 클러스터에 배포조차 안 되어 있음** — ArgoCD Application 목록에도, `kubectl get pods -n c4i`에도 존재하지 않는다. **2026-09-23에 원인을 실측하고 "보류" 결정을 확정**했다 (해결 완료, 근거는 아래).

### `defense-api-gateway` 보류 결정 — 실측 근거

worker 노드의 현재 메모리 커밋 상태(`kubectl describe node`, 2026-09-23):

| 노드 | 메모리 requests | 메모리 limits |
|---|---|---|
| `k3s-worker1` | 544Mi / 1.42GB 할당가능 (37%) | 1664Mi (**114%, 이미 overcommit**) |
| `k3s-worker2` | 512Mi / 1.66GB 할당가능 (30%) | 1536Mi (90%) |

`defense-api-gateway`의 요청 리소스는 `requests.memory: 192Mi` / `limits.memory: 384Mi`(`deployment.yaml`). worker1은 limits 기준으로 이미 114% overcommit 상태라 여기에 더 얹는 건 무리이고, worker2에 얹어도 limits가 110%까지 올라간다. 더 근본적으로는 호스트(Mac mini M2, 통합메모리 8GB) 자체가 이미 k3s VM 3개로 대부분 소진된 상태([AX-Portfolio-Roadmap.md](./AX-Portfolio-Roadmap.md)의 온프레미스 LLM 보류 결정과 같은 하드웨어)라, master 노드에 여유가 있어 보여도(할당 4%) VM 재배치보다 "안 띄운다"가 더 안전한 선택이다.

**결론: (B) 안 띄우는 쪽으로 확정.** JWT 인증 게이트웨이는 소스코드/매니페스트 수준까지만 완성하고, 실제 트래픽 경로에는 의도적으로 연결하지 않는다 — `target-tracking-service`/`threat-intel-ai-service`는 Traefik Ingress에서 인증 없이 바로 노출되는 현재 상태를 유지한다. 이력서/면접에서 이 컴포넌트를 언급할 땐 "설계·구현했으나, 실측 결과 리소스 제약으로 배포는 보류"라고 정확히 말할 것 — "JWT 인증을 게이트웨이 레이어에서 처리한다"처럼 현재 배포 상태와 다른 표현은 쓰지 않는다.

## 상세 — 신뢰성 이력

오늘 세션에서 발견한 것만 나열해도:
- `gemini-api-key` Secret이 `"PLACEHOLDER"`로 방치 — 발견 시점까지 정확히 얼마나 오래 지속됐는지 알 방법이 없음 (로그/알림 부재)
- ArgoCD Image Updater가 git write-back은 성공했지만 Application 상태 반영이 지연되는 걸 인지하지 못하면 배포가 "된 줄 알았는데 안 된" 상태로 남을 수 있음

둘 다 "발견해서 고쳤다"는 긍정적 스토리로 쓸 수 있지만, 애초에 발견까지 오래 걸렸다는 근본 원인(관측성 공백)은 아래 4번 항목으로 메웠다.

## 우선순위 제안 (2026-09-23 최종 갱신)

1. ~~`defense-api-gateway` 처리~~ — 실측 후 보류 확정, 근거 문서화 완료
2. ~~최소 유닛 테스트 (백엔드)~~ — Java 15개(신규 2클래스) + Python 15개(신규 2모듈) 추가, 둘 다 CI 배포 게이트로 연결 완료
3. ~~프론트엔드 테스트~~ — Vitest 도입, `useApprovalSocket`/`useTargetSocket`/`Dashboard`에서 순수 로직(경계 판정, 이력 누적, 대기 목록 정렬) 4개를 `src/lib/`로 분리해 15개 테스트 작성, `test.yml`로 push/PR마다 타입체크·린트·테스트 실행
4. ~~AI 헬스체크 + 알림~~ — `k3s-msa-infrastructure/.github/workflows/ai-health-check.yml`, 매일 00:00 UTC에 두 서비스의 공개 엔드포인트를 실제로 호출해 `aiEnabled`/`ai_enabled`까지 확인. 실패 시 GitHub 기본 동작(스케줄 워크플로 실패 알림 이메일)으로 통지 — 별도 Slack/SMTP 연동 없이 구현
5. **Prometheus 스크레이핑 서버** — 유일하게 남은 항목. 리소스 여유가 생기면 진행 (지금은 하드웨어 제약으로 의도적 보류, 이미 문서화됨)

1~4번이 전부 2026-09-23 하루 동안 처리되면서, 이 문서 초안 작성 시점에 나열했던 "완성도" 공백은 하드웨어 제약으로 의도적으로 보류한 5번을 빼고 전부 해소됐다.
