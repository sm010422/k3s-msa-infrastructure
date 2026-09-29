# Maven Smart System(MSS) 비교 및 자산 추천 엔진 구현 (2026-09-29)

Palantir의 Maven Smart System(MSS) 아키텍처 설명을 이 프로젝트와 직접 비교해서 유사성/격차를 평가하고, 가장 명확한 갭이었던 "요격 자산 가용성 = 랜덤 시뮬레이션"을 실제 계산 엔진으로 교체한 기록.

## 비교 결과 요약

<table fit-page-width="true" header-row="true">
<tr><td>MSS 요소</td><td>이 프로젝트</td><td>평가</td></tr>
<tr><td>데이터 융합(Gaia) — 150+ 소스, Stable Identifier</td><td>ADS-B 단일 라이브 피드 → Kafka → 벡터DB</td><td>방향성은 같으나 교차 센서 엔티티 매칭 기술 자체가 없음 (소스가 하나뿐이라 문제 자체가 안 생김)</td></tr>
<tr><td>Observe — AI가 CV로 물체 자동 분류</td><td>`assess_threat_level` — 규칙 기반 자동 분류(표적 유형/고도/속도)</td><td>패턴 일치. 단 CV가 아니라 규칙 기반</td></tr>
<tr><td>Decide — AI가 연료/탄약/도달시간 계산해 3~4개 옵션 추천</td><td>(수정 전) `check_intercept_asset_availability`가 "(시뮬레이션 데이터)" 랜덤 READY/COOLDOWN</td><td>**가장 명확한 갭** — 이번에 실제 계산 엔진으로 교체</td></tr>
<tr><td>Act — 지휘관이 옵션 클릭 승인, 명령 전송</td><td>`ThreatApprovalService` — HIGH/CRITICAL 자동 승인 큐 생성, WebSocket 실시간 push, 승인/반려 + 감사 기록(`decidedBy`, `time_to_decision_seconds`)</td><td>이미 거의 같은 골격 — MSS와 이름은 다르지만 동일한 human-in-the-loop 패턴</td></tr>
<tr><td>실전 검증 규모 — 10만+ 사용자, 24시간 1000+ 옵션</td><td>홈랩 포트폴리오, 사용자 0</td><td>비교 대상 아님 — 포트폴리오 성격상 채울 필요 없는 격차</td></tr>
<tr><td>LLM 내장(Claude) + human-in-the-loop 거버넌스 논쟁</td><td>Gemini 내장, "AI 추천·인간 승인" 동일 철학</td><td>거의 1:1로 겹침 — 포트폴리오 서사에 쓸 수 있는 강점</td></tr>
</table>

## 구현 — 자산 추천 엔진

### 이전 상태

`threat-intel-ai-service/app/graph/tools.py`의 `check_intercept_asset_availability`:

```python
def check_intercept_asset_availability(target_type: str) -> str:
    assets = _INTERCEPT_ASSETS.get(str(target_type).upper(), ["가용 자산 정보 없음"])
    statuses = [f"{asset}: {random.choice(['READY', 'READY', 'COOLDOWN'])}" for asset in assets]
    return "(시뮬레이션 데이터) " + "; ".join(statuses)
```

거리·연료·탄약 계산이 전혀 없는 랜덤 상태 표시였다.

### 이후 — 하버사인 거리 기반 실제 ETA 계산

**target-tracking-service** (`domain/asset/` 신규 패키지):

- `InterceptAssetCatalog` — 고정 자산 5개, 수도권 인근 실존 기지 좌표 참고(오산·수원·평택·김포)
- `AssetRecommendationService.recommend(targetType, lat, lon)` — 표적 유형과 호환되는 자산만 후보로 삼아, 하버사인 거리 → ETA(분) 계산 → 오름차순 정렬 → 상위 3개 반환. `ammoCount > 0 && etaMinutes <= fuelEnduranceMinutes`면 `feasible=true`

```java
private double haversineKm(double lat1, double lon1, double lat2, double lon2) {
    double dLat = Math.toRadians(lat2 - lat1);
    double dLon = Math.toRadians(lon2 - lon1);
    double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
        + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
        * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return EARTH_RADIUS_KM * c;
}
```

`ThreatApprovalService.createIfNeeded()`가 HIGH/CRITICAL 승인 요청을 만들 때 이 추천을 계산해서 `recommendedOptionsJson`(JSON 스냅샷)으로 `ThreatApproval` 엔티티에 저장한다 — 자산 카탈로그가 나중에 바뀌어도 과거 승인 기록엔 "그 당시 뭘 추천했었는지"가 그대로 남는다.

`decide()`는 이제 승인(`APPROVED`)일 때 `selectedOption`이 그 추천 목록 중 하나와 일치해야만 성립한다 (아니면 `IllegalArgumentException`). 반려(`REJECTED`)는 선택 없이도 가능 — MSS의 "3~4개 옵션 중 하나 클릭"과 동일한 제약을 건 것.

**threat-intel-ai-service** — 동일 카탈로그·공식을 Python으로 미러링해서 채팅 인터페이스에서도 같은 답이 나오도록 맞췄다 (`assess_threat_level`이 이미 두 서비스에 같은 룰로 중복 구현돼 있던 것과 같은 이유). 채팅 질문은 표적의 정확한 좌표가 항상 주어지지 않으므로 `target_latitude`/`target_longitude`를 선택 인자로 두고, 생략 시 서울(수도권 방어 구역 기준점)로 계산한다.

### 프론트엔드 — 대시보드도 "3개 옵션 중 하나 클릭"으로

`ApprovalPanel.tsx`가 기존엔 SITREP만 보여주고 승인/반려 이진 버튼뿐이었는데, 이제 추천 자산 3개를 라디오 옵션으로 보여준다(자산명·ETA·거리·탄약·feasible 여부). **승인 버튼은 옵션을 하나 선택하기 전까진 비활성화**되고, 반려는 선택 없이도 가능하다 — MSS 스크린샷의 "옵션 클릭 → 승인 클릭" 흐름과 UI 레벨에서도 더 가까워졌다.

## 알려진 단순화 (정직하게 남겨둠)

- **탄약 재고가 소모되지 않는다** — `ammoCount`는 고정값이고, 승인이 반복돼도 실제로 줄어들지 않는다. 재고 추적은 동시성·영속성이 추가로 필요해서 이번 스코프 밖.
- **자산 카탈로그는 정적** — 실시간 자산 위치/상태 피드가 아니라 하드코딩된 5개 고정 프로필.
- **MISSILE 요격의 "속도"는 개념적 근사치** — PAC-3 같은 고정 포대의 "이동 속도"라는 개념 자체가 물리적으로 정확하지 않지만, 반응시간 예산(연료 endurance 필드로 대체) 계산이 성립하게 하기 위한 단순화.

이 세 가지는 "실제 자산 관리 시스템과 무관한 시뮬레이션"이라는 원래 주석의 정신을 그대로 유지한다 — 랜덤보다 훨씬 그럴듯해졌을 뿐, 여전히 데모용 근사치라는 점은 변하지 않는다.

## 배포 중 실제로 겪은 버그 — @Lob 컬럼이 3개가 되면서 500 에러

배포 직후 `/api/v1/threat-approvals?status=ALL`을 직접 두드려보니 500이 떴다:

```
org.postgresql.util.PSQLException: Large Objects may not be used in auto-commit mode.
```

`ThreatApproval`에 `sitrep`/`decisionReason` 두 개였던 `@Lob` 컬럼이 `recommendedOptionsJson` 추가로 3개가 됐는데, PostgreSQL은 `@Lob`(Large Object) 스트림을 **활성 트랜잭션 안에서만** 읽을 수 있다. `listPending()`/`listAll()`에 `@Transactional`이 빠져 있어서 실제로 터진 것 — `readOnly = true`로 트랜잭션을 명시해서 해결했다(커밋 `9697284`). 수정 후 같은 엔드포인트를 다시 호출해서 `recommendedOptions`가 실제 계산값(F-15K 요격편대 ETA 0.78분 등)으로 채워진 것까지 확인했다.

## 검증

- target-tracking-service: `AssetRecommendationServiceTest`(자산 카탈로그 호환성, ETA 정렬, feasible 판정) + `ThreatApprovalServiceTest`(추천 옵션 JSON 저장, 승인 시 유효하지 않은 selectedOption 거부, 반려는 선택 불필요) 전부 통과
- threat-intel-ai-service: `test_tools.py`에 좌표 기반 테스트 추가(서울 인근 표적엔 K30 비호 대공포가 최우선 추천, 먼 표적은 feasible=false 가능) 전부 통과
- c4i-dashboard-frontend: `tsc --noEmit`, `eslint`, `vitest` 전부 통과
- 세 리포 전부 push, CI(GitHub Actions) 빌드 성공, ArgoCD Image Updater가 새 이미지 반영

## 다음으로 고려할 것 (이번 스코프 밖)

- **Stable Identifier 미니어처** — 가상 2번째 센서 소스(레이더/SIGINT 시뮬레이션) 추가 후 위치·시간·속도 근접성으로 "같은 표적" 매칭하는 로직. MSS의 핵심 차별화 기술을 작은 스케일로 재현하는 셈이라 포트폴리오 스토리텔링 가치가 큼.
- **탄약/쿨다운 실제 소모 추적** — 승인될 때마다 해당 자산의 ammoCount를 감소시키고 일정 시간 후 회복시키는 상태 관리.
- **Grafana에 승인 루프 지표 노출** — 이미 쌓이고 있는 `threat_approval_requested_total`, `threat_approval_time_to_decision_seconds`를 대시보드 패널로 만들어서 "우리 시스템의 승인 처리 속도"를 정량적으로 보여주기.
