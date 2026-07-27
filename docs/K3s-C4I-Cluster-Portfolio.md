# On-Premise K3s 클러스터 기반 C4I 표적추적 시스템

## 개요
개인 소유 하드웨어(MacBook 2대)와 VMware 가상머신 3대를 결합해 구축한 실제 분산 컴퓨팅 환경. 클라우드가 아닌 온프레미스 인프라 위에서 경량 쿠버네티스(K3s) 클러스터를 직접 구성하고, 그 위에 실시간 표적 추적 및 AI 기반 위협 분석 파이프라인을 운용했습니다.

## 인프라 구성

| 구성 요소 | 사양 |
|---|---|
| 물리 호스트 | MacBook 2대 |
| 가상화 | VMware (Ubuntu Server 3대) |
| 클러스터 | K3s — Master 1, Worker 2 |
| 상시 가동 | Amphetamine 기반 Closed-Display Mode 커스텀 전원 정책 (클램쉘 상태에서도 무중단 운용) |

## 애플리케이션 스택

- **Spring Boot 마이크로서비스** — 표적 추적 도메인 로직, REST/이벤트 기반 서비스 분리
- **Kafka** — 실시간 표적 위치/상태 이벤트 스트리밍 파이프라인
- **PostgreSQL + pgvector** — 임베딩 기반 유사도 검색을 활용한 AI 위협 분석 데이터 저장
- **K3s** — 리소스가 제한된 VM 환경에 최적화된 경량 오케스트레이션

## AI 마이크로서비스 확장 — threat-intel-ai-service

기존 target-tracking-service(Java/Spring AI)는 실시간 단일 표적을 고정된 10개 위협 패턴 지식베이스와 비교하는 RAG만 지원했다. 비정형 위협 인텔 문서 검색과 실제 탐지 이력 기반 분석이라는 두 가지 빈틈을 메우기 위해, 별도 저장소로 Python AI 전용 마이크로서비스를 폴리글랏 구조로 추가했다 ([threat-intel-ai-service](https://github.com/sm010422/threat-intel-ai-service)).

**아키텍처**
- **FastAPI + LangGraph** — 질문을 `doc_rag`(문서 검색) / `pattern_search`(이력 검색) 두 갈래로 자동 분류 후 라우팅, SSE로 실시간 스트리밍 응답
- **Qdrant** — 문서 청크·임베딩 저장(`threat_documents`), Kafka로 유입되는 실제 탐지 이력 임베딩 저장(`target_history`) — 독립된 두 벡터 컬렉션
- **Kafka** — 기존 `target-tracking` 토픽을 별도 consumer group으로 구독, Java 서비스와 오프셋 독립적으로 이력 자동 색인
- **Gemini API** — 임베딩·생성 모두 API 기반, 로컬 GPU/모델 리소스 불필요

**CI/CD & 배포**
- GitHub Actions(arm64 네이티브 빌드) → Docker Hub → ArgoCD Image Updater로 이미지 digest 변경을 자동 감지 → GitOps 리포에 write-back 커밋 → 클러스터 자동 반영까지 사람 개입 없이 동작하는 걸 실측 검증 (`docs/Threat-Intel-AI-Service-K3s-Deployment.md`)
- 클러스터 노드별 실측 리소스(`kubectl top`)를 근거로 배치 노드를 설계, `podAntiAffinity`로 기존 워크로드와 분리 스케줄링 (`docs/Threat-Intel-AI-Service-Cost-and-Resource-Verification.md`)

**실 운영 중 발견·수정한 장애**
1. Gemini `gemini-2.5-flash` 모델이 신규 계정에 404로 차단된 것을 API 레벨에서 직접 진단, `-latest` 별칭 모델로 전환해 향후 deprecation에도 견고하도록 수정
2. 비동기 스레드(`run_in_executor`)에서 발생한 예외가 조용히 유실되어 클라이언트가 빈 응답을 받던 문제를 SSE `event: error`로 명시 노출하도록 수정
3. 두 수정 모두 실 서비스 재배포 후 `doc_rag`/`pattern_search` 두 경로 각각 실제 RAG 응답으로 회귀 검증 (`threat-intel-ai-service/docs/concepts/10-live-verification-chat-and-ingest.md`)

## 핵심 역량

- 클라우드 매니지드 서비스 없이 물리 자원부터 클러스터, 애플리케이션 계층까지 직접 설계·구축
- 제한된 하드웨어(노트북) 환경에서 상시 가동을 위한 전원/발열 관리 정책 수립
- 이벤트 기반 아키텍처(Kafka)와 벡터 검색(pgvector, Qdrant)을 결합한 실시간 AI 분석 파이프라인 설계
- 방산 분야 C4I(지휘통제통신정보) 체계를 모사한 표적 추적 도메인 적용
- 폴리글랏 마이크로서비스 아키텍처 설계 (Spring ↔ Kafka ↔ FastAPI 이벤트 연동)
- LangGraph 기반 Agentic 라우팅/RAG 파이프라인 구현
- GitOps(ArgoCD) CI/CD 파이프라인을 신규 서비스로 확장 적용, 자동화 검증
- 실 운영 로그 기반 장애 진단 및 수정 (LLM 모델 deprecation, 비동기 예외 처리)
- 네트워크 토폴로지 분석 기반의 기술 도입 타당성 검증 — MetalLB 도입을 검토하던 중, 노드 인터페이스 플래그(`tailscale0`의 `NOARP`)와 서브넷 도달 범위(Multipass 내부망 vs Tailscale 오버레이)를 실측해 L2/BGP 모드 둘 다 이 토폴로지에서 실질적 효용이 없음을 되돌리기 어려운 변경 전에 규명, 대신 기존 klipper-lb 구성이 이미 동등한 가용성을 제공한다는 근거를 남기고 유지 결정 (`docs/MetalLB-Feasibility-Investigation-on-Tailscale-Overlay.md`)

## 향후 고도화 방향
- 클러스터 모니터링(Prometheus/Grafana) 연동
- Qdrant 이력 컬렉션 규모가 커졌을 때의 검색 성능/리소스 재측정

> ~~노드 장애 시나리오 대비 HA 구성 검증~~ — MetalLB 기반 VIP failover를 조사했으나 Tailscale 오버레이 토폴로지에서 L2/BGP 모드 둘 다 실효성이 없음을 확인, klipper-lb의 다중 노드 IP 라우팅이 이미 동등한 가용성을 제공한다고 결론 (`docs/MetalLB-Feasibility-Investigation-on-Tailscale-Overlay.md`, 2026-07-27)

> ~~CI/CD 파이프라인을 통한 K3s 배포 자동화~~ — target-tracking-service에 이어 threat-intel-ai-service까지 GitHub Actions + ArgoCD Image Updater로 완전 자동화 완료 (2026-07-25)
