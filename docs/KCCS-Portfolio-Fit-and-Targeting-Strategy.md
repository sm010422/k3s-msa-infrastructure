# KCCS 타겟팅 — 포트폴리오 적합성 분석 (2026-09-28)

## KCCS가 뭔가

**KCCS(차세대 합동지휘통제체계)** — 육·해·공군이 각자 따로 운용 중인 통신 네트워크와 C4I(지휘통제정보시스템)를 하나로 통합하는 국방 사업. 사업 규모는 3000억 원대로 관측되고, 정부는 2027년부터 체계개발을 추진할 계획이다. 3단계 롤아웃 중 2단계(KCCS 2.0)에서 육해공 C4I 통합이 본격화된다.

기대 효과는 각 군이 단일 시스템에서 전장 정보를 공유하고, 실시간 공조로 의사결정을 내리는 것 — 그러려면 저지연 네트워크 환경이 전제 조건이다.

### 주요 참여/경쟁 기업

- **삼성SDS** — 국방과학연구소(ADD) 위탁으로 "클라우드 기반 지능형 합동지휘통제체계(K-TITAN)" 연구 수행, 삼성전자와 5G·전술폰 협업 모델 제시. KNCCS(한국해군전투체계) 전투효율성 개선 사업 196억 원 수주 이력도 있음.
- **LG CNS** — 연합지휘통제체계 성능개량 사업 설명회 참석.
- **네이버클라우드** — 삼성SDS와 국방 AX(AI Transformation) 영역에서 경쟁 구도.
- **아이티센엔텍** — KNCCS 노후 네트워크 장비 교체 사업 수주.

## K-TITAN(삼성SDS 연구)이 제시하는 핵심 아키텍처

<table fit-page-width="true" header-row="true">
<tr><td>요소</td><td>내용</td></tr>
<tr><td>센터-엣지 이중 클라우드</td><td>엣지 클라우드는 네트워크 단절 시에도 소규모 부대가 독립적으로 판단·작전 수행</td></tr>
<tr><td>5G 특화망(p5G)</td><td>고해상도 영상/데이터 실시간 전달, 산악 지역 초저지연 연결</td></tr>
<tr><td>AI 플랫폼</td><td>분석형 AI(Brightics, 표적 인식·위협 분석)+생성형 AI(FabriX, 작전 계획 최적화)</td></tr>
<tr><td>데이터 통합</td><td>항공·지상 센서 데이터를 엣지 클라우드에서 융합 분석 → 종합 상황인식</td></tr>
<tr><td>통신 네트워크</td><td>다중 홉 메시 네트워크 — 특정 노드 장애 시 자동 복구</td></tr>
</table>

## 지금 포트폴리오와의 매칭

<table fit-page-width="true" header-row="true">
<tr><td>KCCS가 요구하는 것</td><td>지금 포트폴리오에 있는 것</td></tr>
<tr><td>AI 기반 표적 인식·위협 분석</td><td>`threat-intel-ai-service` — Gemini RAG로 위협 등급 판정, 요격 자산 가용성 체크, doc_rag/pattern_search 라우팅</td></tr>
<tr><td>센서 데이터 실시간 융합 → 상황인식</td><td>`target-tracking-service`의 ADS-B 피드 → Kafka → AI 색인 → 벡터 DB(Qdrant) 조회 파이프라인</td></tr>
<tr><td>MSA·클라우드 네이티브</td><td>k3s 3노드 + ArgoCD GitOps + Kafka/Postgres/Redis/Qdrant, Image Updater 기반 CD 파이프라인</td></tr>
<tr><td>노드 장애 시 자동 복구(메시 네트워크 수준)</td><td>2026-09-27 정전 사건 대응 — Kafka consumer 재시도 로직 + kafka_consumer_running 기반 livenessProbe로 자가 치유 구현 (`docs/Chuseok-Power-Outage-Recovery.md`)</td></tr>
<tr><td>운영 성숙도(관측가능성)</td><td>AI 헬스체크 자동화(hourly), ntfy 알림, ArgoCD Synced/Healthy 상시 확인 체계</td></tr>
</table>

**가장 강력한 카드는 정전 사건 대응이다.** KCCS 백서가 요구하는 "장애 상황에서도 자율 복구"를 실제로 겪고, 근본 원인(재시도 로직 부재)을 찾아 고치고, 방어선(liveness probe)까지 한 겹 더 추가해 배포한 사례라서 — 면접에서 "이런 상황 어떻게 대응하시겠어요?"가 아니라 "실제로 이렇게 대응했습니다"로 말할 수 있다.

## 갭 3가지

1. **5G/엣지 네트워크 스토리 부재** — Tailscale VPN은 있지만 p5G 특화망, 다중 홉 메시 네트워크, 네트워크 단절 시 자율운영 같은 요소는 없음. 홈서버 한 대짜리 구성이라 애초에 "단절"이라는 개념 자체가 약하다.
2. **대규모 시스템 통합 경험 부재** — KCCS는 육해공군 이종 레거시 시스템을 통합하는 엔터프라이즈 SI 성격이 강한데, 지금 포트폴리오는 처음부터 혼자 설계한 단일 스택이라 "레거시 통합" 경험을 보여주기 어렵다.
3. **채용 자격 요건 미확인** — 방산 SI 업계는 병역/보안 clearance 관련 요건이 있을 수 있다. 포트폴리오 문제가 아니라 지원 전 별도로 확인해야 하는 항목.

## 타겟팅 전략

**삼성SDS·LG CNS의 국방 AX/클라우드 직군**엔 지금 포트폴리오가 상당히 직접적으로 어필된다 — 이 회사들이 지금 밀고 있는 정확히 그 방향(클라우드 네이티브 + AI 위협분석 + MSA)을 개인 스케일로 이미 구현해본 셈이다.

지원 시 용어를 회사들이 실제 쓰는 언어로 재포장하는 게 스크리닝 통과에 유리하다:

<table fit-page-width="true" header-row="true">
<tr><td>내 프로젝트 용어</td><td>KCCS 생태계 용어로 치환</td></tr>
<tr><td>표적 추적/위협 분석</td><td>상황인식(Situational Awareness), 표적 인식 AI</td></tr>
<tr><td>Kafka 이벤트 스트리밍</td><td>센서 데이터 실시간 융합(Data Fusion)</td></tr>
<tr><td>k3s MSA + GitOps</td><td>클라우드 네이티브 지휘통제 인프라</td></tr>
<tr><td>Kafka consumer 재시도/liveness probe</td><td>장애 허용(Fault Tolerance)·자가 치유(Self-Healing) 설계</td></tr>
</table>

## 다음 액션 (제안)

- 이력서/자소서(`AX-Portfolio-Resume-Drafts.md`)에 위 용어 치환 테이블을 반영한 KCCS 타겟 버전 문항 추가 검토
- 삼성SDS·LG CNS 채용공고에서 실제로 요구하는 키워드(예: "국방 AX", "합동지휘통제", "클라우드 네이티브 전장관리") 재확인 후 자소서 문항에 직접 매칭
- 지원 전 방산 SI 특유의 자격 요건(병역, 보안 clearance) 확인

## 출처

- [삼성SDS 인사이트 — 클라우드 기반 지능형 합동지휘통제체계](https://www.samsungsds.com/kr/insights/k-tactical-intelligence-targeting-access-node.html)
- [서울경제 — 삼성, 軍 차세대 지휘통제사업 진출](https://www.sedaily.com/article/20092774)
- [서울경제 — 5G·전술폰으로 미래전장 실시간 통솔](https://m.sedaily.com/article/20092754)
- [전자신문 — 육해공 C4I 잇따라 성능개량](https://www.etnews.com/20260828000187)
- [서울경제 — 삼성SDS·네이버, 국방 AX서도 격돌](https://www.sedaily.com/article/20094861)
