# AIS 실시간 선박 추적 연동 (2026-09-29)

`MSS-Comparison-and-Asset-Recommendation-Engine.md`에서 지적한 "단일 모달리티(ADS-B 하나뿐)" 한계에 대응해서, 두 번째 실시간 공개 데이터 소스(AIS, 선박 자동식별장치)를 붙인 기록. 연결 자체는 30분 넘게 원인을 못 찾다가, 결국 아주 단순한 데이터 형식 오해였다는 게 밝혀진 디버깅 과정이 이 문서의 절반을 차지한다.

## 데이터 소스 선정

무료로 접근 가능한 실시간 AIS API를 조사했다.

<table fit-page-width="true" header-row="true">
<tr><td>옵션</td><td>방식</td><td>결과</td></tr>
<tr><td>**aisstream.io** (채택)</td><td>WebSocket 실시간 스트림</td><td>무료 가입, 이메일 인증만으로 API 키 즉시 발급</td></tr>
<tr><td>AISHub</td><td>REST/XML</td><td>❌ 본인 소유 AIS 수신기 데이터를 공유해야 접근 가능 — 물리 수신기 없음</td></tr>
<tr><td>VesselAPI</td><td>REST</td><td>무료 티어 있지만 호출 제한</td></tr>
</table>

API 키는 클러스터의 `target-tracking-secrets` Secret에 `ais-stream-api-key`로 직접 추가(git에는 안 올림 — `gemini-api-key`/`db-password`와 동일 패턴).

## 아키텍처

`AdsbFiPollingService`(ADS-B, REST 폴링)와 같은 자리에 두 개의 새 클래스를 추가했다.

- **`AisMessageParser`** — AIS 메시지 JSON → `TargetEvent` 순수 변환 함수. 네트워크 없이 단위 테스트 가능(`AdsbFiClient`/`AdsbFiPollingService` 분리 패턴을 그대로 따름). `TrueHeading=511`("값 없음" AIS 스펙 센티널)이면 `Cog`(대지 진행방향)로 대체.
- **`AisStreamService`** — WebSocket 연결·구독·재연결 관리, 파싱은 `AisMessageParser`에 위임.

`TargetEvent`에 `targetType="SHIP"`, `altitude=0.0`으로 발행 — 기존 Kafka 파이프라인(PostgreSQL 저장, WebSocket 브로드캐스트, AI 위협분석)을 그대로 재사용한다.

### 위협 등급 규칙 확장

<table fit-page-width="true" header-row="true">
<tr><td>규칙</td><td>근거</td></tr>
<tr><td>targetId(MMSI)가 9자리 숫자가 아니면 → HIGH</td><td>실제 해상보안 감시에서 쓰는 AIS 스푸핑/다크베슬 탐지 관점을 규칙으로 옮김</td></tr>
<tr><td>속도 &gt; 60km/h → MEDIUM</td><td>상선 순항 속도(30km/h대) 대비 이례적 고속 — 소형 고속정 패턴</td></tr>
</table>

Python(`threat-intel-ai-service`)의 `assess_threat_level`에도 속도 규칙을 동일하게 미러링(MMSI 형식 검사는 그 함수 시그니처에 targetId가 없어서 Java 쪽에만 있음 — `assess_threat_level`이 이미 DRONE/MISSILE/AIRCRAFT 규칙을 Java와 중복 구현해온 것과 같은 이유).

### 쿼터 보호 일반화

`warrantsAiAnalysis()`가 원래 AIRCRAFT 전용으로 "군용/HIGH 이상만 AI 분석"하도록 막아뒀던 게(민항기 폭주로 Gemini 무료 쿼터 소진 사건, 과거 문서 참고) AIRCRAFT에만 적용되고 있었다. SHIP도 한국 연안 AIS 트래픽이면 똑같이 대량 유입될 게 뻔해서, 이 필터를 "DRONE/MISSILE(시뮬레이터, 개체 수 적음)만 무조건 분석, 나머지는 HIGH 이상만"으로 일반화했다.

## 디버깅 — "연결은 됐는데 아무 데이터도 안 온다"

### 1차 구현: JDK `java.net.http.WebSocket`

연결·구독 로그는 정상 출력됐지만(`onOpen` → `sendText`), **30분 넘게 단 하나의 메시지도 처리되지 않았다.** API를 조회하니 SHIP 타입 0건, 에러 로그도 0건 — 침묵만 있었다.

### 원인 규명 1단계 — 외부에서 직접 검증

같은 API 키·bounding box·구독 메시지로 Node.js 스크립트를 짜서 직접 접속해보니 **1초 안에 실제 데이터가 왔다.** 이걸로 API 키/구독 포맷/aisstream.io 서버 쪽은 전혀 문제가 없다는 게 확인됐다 — 문제는 100% Java 클라이언트 쪽.

### 원인 규명 2단계 — Spring으로 교체해서 에러를 노출시킴

JDK WebSocket의 `onText`가 왜 안 불리는지 로그를 더 추가해도 실마리가 안 보여서, 이 앱이 대시보드 STOMP 브로드캐스트로 이미 실전 검증된 **Spring `StandardWebSocketClient`**로 교체했다. 그러자 즉시 진짜 에러가 드러났다:

```
CloseStatus[code=1003, reason=Binary messages not supported]
```

### 근본 원인

**aisstream.io는 JSON을 텍스트 프레임이 아니라 바이너리 프레임으로 보낸다.** Node.js 테스트에서 `event.data`가 `Blob`으로 온 것(그래서 `.text()`로 디코딩해야 했던 것)이 사실 이걸 이미 암시하고 있었는데, 처음엔 놓쳤다.

- JDK 버전은 `onText`만 구현하고 `onBinary`를 안 건드려서, 기본 구현(조용히 버림)에 흡수돼 **아무 에러도 없이 그냥 사라졌다.**
- Spring의 `TextWebSocketHandler`는 바이너리 프레임 자체를 명시적으로 거부해서(1003), 처음으로 실마리가 남았다.

### 최종 수정

`TextWebSocketHandler` → `AbstractWebSocketHandler`로 바꿔서 `handleTextMessage`와 `handleBinaryMessage`를 **둘 다** 구현. 바이너리는 UTF-8로 디코딩하면 완전히 동일한 JSON이었다.

```java
@Override
protected void handleBinaryMessage(WebSocketSession session, BinaryMessage message) {
    String payload = StandardCharsets.UTF_8.decode(message.getPayload()).toString();
    AisStreamService.this.handleMessage(payload);
}
```

## 검증

배포 후 7분 동안 재연결 없이 안정 유지, SHIP 이벤트 211건 수신. `/api/targets`에서 실제 확인:

```json
{"total": 4221, "AIRCRAFT": 4141, "SHIP": 80}
{"targetId": "440019220", "targetType": "SHIP", "latitude": 37.45019, "longitude": 126.59419, "speed": 0.0, "heading": 321.0}
```

인천 앞바다 실제 선박(MMSI 440019220) 좌표·방위까지 정확히 잡힌다.

## 프론트엔드

`MapView.tsx` — SHIP은 항공기(삼각형/점)와 구분되게 사각형 마커로 렌더링. 새 데이터 소스가 섞여 있다는 걸 지도에서도 시각적으로 드러내는 게 "다중 소스 융합"이라는 의도에 맞다고 판단. 툴팁도 SHIP일 땐 의미 없는 고도(항상 0m) 대신 속도만 표시.

## 부수적으로 발견한 것 — 방치된 백그라운드 셸 5개

이 디버깅 과정에서 ArgoCD Image Updater의 digest 커밋을 기다리는 백그라운드 폴링 루프를 여러 번 띄웠는데, 그중 5개가 `sshpass ... ssh sangmin@...`(pubkey 인증 옵션 없이 호출)가 "Too many authentication failures"로 **무한 재시도 루프에 빠진 채 방치**돼 있었다 — 실제로 필요한 조건 확인은 한 번도 못 하고 10초마다 인증 실패만 반복. 전부 찾아서 종료시켰고, 이후엔 `-o PreferredAuthentications=password -o PubkeyAuthentication=no`를 붙인 패턴으로만 SSH를 호출했다.

**교훈**: 백그라운드 폴링 루프의 내부 명령이 실패하기 시작하면(이번처럼 인증 문제로), `until` 루프는 조건이 "아직 안 됨"으로 영원히 착각한 채 조용히 자원만 쓴다 — 완료 알림이 안 온다고 해서 "아직 진행 중"이라고 넘겨짚지 말고, 오래 걸리면 실제 출력을 한 번씩 들여다볼 필요가 있다.

## 장애 — 좀비 연결로 16시간 동안 선박이 안 보였던 사건 (2026-09-30)

배포하고 하루쯤 지나서 "선박이 안 보인다"는 보고를 받고 확인해보니, `/api/targets`가 항공기(AIRCRAFT)만 13,000여 건이고 SHIP은 0건이었다.

**증상 진단 과정:**

1. 파드 상태(`kubectl get pods`)는 `1/1 Running`, 재시작 0회 — 크래시가 아니었다.
2. `AIS_ENABLED`/`AIS_STREAM_API_KEY` 환경변수도 파드 안에서 정상 확인 — 설정 문제가 아니었다.
3. 로그에서 `[AisStream]` 태그가 붙은 줄을 아예 못 찾았다 — 처음엔 "로그 보존 기간(container log rotation)이 짧아서 안 보이나?" 의심했지만, 파드가 뜬 지 16시간이 지났는데 그동안 재연결 시도 로그(`연결 실패`/`연결 종료`/`스트림 에러`)가 **단 한 줄도 없었다**는 게 핵심 단서였다. 재연결 로직(10초 딜레이)이 살아있었다면 문제가 지속되는 동안 로그가 쌓였을 텐데, 그조차 없다는 건 "재연결이 실패하고 있다"가 아니라 "재연결을 시도할 계기 자체가 한 번도 발생하지 않았다"는 뜻이었다.
4. 결론: `afterConnectionClosed`/`handleTransportError` 콜백이 애초에 안 불리는 상태로 TCP 연결만 조용히 죽어버린 **좀비 연결**. Java WebSocket 클라이언트는 서버가 정상적인 close 프레임을 안 보내면(중간 경로의 idle timeout 등으로 그냥 끊기면) 이걸 스스로 감지할 방법이 없다 — ping/pong이나 수신 타임아웃 같은 애플리케이션 레벨 감시가 없었던 게 근본 원인.

**즉시 조치**: `kubectl rollout restart deployment/target-tracking-service`로 파드를 새로 띄우니 새 연결이 맺어지고(`연결 및 구독 완료` 로그 확인) 30초 안에 SHIP 이벤트가 다시 들어왔다 — 이게 "연결이 죽어있었다"는 가설을 그대로 뒷받침했다.

**근본 수정**: `AisStreamService`에 워치독을 추가했다. 마지막 메시지 수신 시각(`lastMessageAt`)을 매 메시지마다 갱신하고, 30초마다 도는 스케줄러가 120초 넘게 조용하면(이 권역 트래픽 밀도면 정상 상태에서 그렇게 길게 공백이 날 수 없음) 현재 세션을 죽었다고 간주해 강제로 닫고 재연결한다. 옛 세션을 `session` 필드에서 먼저 떼어낸 뒤 닫기 때문에, 그 세션의 콜백이 나중에 뒤늦게 불리더라도(신원 비교로 걸러져서) 중복 연결로 이어지지 않는다.

**교훈**: 재연결 로직이 있다고 해서 "연결이 끊기면 알아서 복구된다"가 보장되지 않는다 — 그 로직을 트리거하는 신호(close/error 콜백) 자체가 안 온다면 아무 소용이 없다. 네트워크 연결을 다루는 백그라운드 서비스는 재연결 로직과는 별개로, "얼마나 조용했는가"를 직접 재는 독립적인 생존 확인(watchdog/heartbeat)이 있어야 한다.

## 알려진 단순화

- 같은 표적을 여러 센서가 보고 있는지 판정하는 교차 소스 매칭(MSS의 Stable Identifier) 로직은 아직 없음 — 지금은 그냥 SHIP/AIRCRAFT가 같은 파이프라인에 나란히 흐를 뿐. 다음 단계로 남겨둠.
- bounding box(한국 연안)는 코드에 고정값 — 지역 변경이 거의 없을 거라는 판단으로 ADS-B REGIONS와 같은 설계.
