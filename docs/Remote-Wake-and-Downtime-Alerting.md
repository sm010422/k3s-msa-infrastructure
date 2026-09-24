# 서버 다운 알림 + 원격 Wake-up 조사 (2026-09-25)

## 배경

2026-09-24 밤~25일 새벽 사이, 홈서버(MacBook, 클램쉘 상태로 상시 가동 — `K3s-C4I-Cluster-Portfolio.md` 참고)가 원인 불명으로 Tailscale에서 사라졌다. 아무도(사용자도, 이 세션도) 원격으로 그 서버에 뭔가를 한 적이 없는 시간대였고, `ai-health-check.yml`의 하루 1회 스케줄 실행이 다음 날에야 그걸 감지했다 — 최대 24시간 동안 아무도 몰랐다는 뜻이다.

이 문서는 그 사건 이후 두 가지를 다룬다: **① 감지를 빠르게(알림), ② 원격으로 직접 깨울 수 있는가(wake-up)**.

## ① 다운 감지 알림 — 구현 완료

`.github/workflows/ai-health-check.yml`

- 주기: 하루 1회 → **매시간**
- 알림 채널: GitHub 기본 이메일(스케줄 워크플로 실패 시 자동) + **ntfy.sh 푸시 알림** 신규 추가
- ntfy 토픽: `c4i-defense-56e57701d708` — 계정가입 없는 무료 pub/sub 알림 서비스. 이 토픽 이름을 아는 사람은 누구나 구독/발행 가능하므로 완전한 비밀은 아니지만(공개 레포에 노출됨), 알림 내용 자체가 민감정보는 아니라서 스팸 정도의 리스크만 있음
- 수신 방법 (폰에만 국한 안 됨):
  - 폰: iOS/Android ntfy 앱 설치 후 토픽 구독 (잠금화면 푸시, 가장 확실함)
  - 아무 기기 브라우저: `https://ntfy.sh/c4i-defense-56e57701d708` 접속만 해도 메시지 히스토리 확인 가능
  - 브라우저 PWA: `https://ntfy.sh/app`에서 토픽 추가하면 브라우저 켜져있는 동안 데스크톱 알림
  - macOS CLI: `brew install ntfy` 후 `ntfy subscribe c4i-defense-56e57701d708`
- 실제 장애 상황(이 서버가 다운된 상태)에서 워크플로 수동 실행 → 실패 감지 → ntfy 알림 발송까지 전 구간 실측 검증 완료 (2026-09-25)

## ② 원격 Wake-up — 조사 결과: 지금 구성으론 불가능, 추가 하드웨어 있으면 가능

### 핵심 문제: Tailscale은 Wake-on-LAN을 못 보낸다

Wake-on-LAN(매직 패킷)은 **Layer 2**(MAC 주소 기반 로컬 브로드캐스트)에서 동작하는데, Tailscale은 **Layer 3**(IP 오버레이 네트워크)다. Tailscale이 아무리 그 기기와 "연결된 것처럼" 보여도, 매직 패킷 자체를 터널 너머로 보낼 방법이 원천적으로 없다 ([Tailscale 공식 블로그](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)).

Tailscale 공식 해법은 "같은 로컬 네트워크에 있는 **다른 상시 가동 기기**가 Tailscale로 명령을 받아서, 그 기기가 로컬에서 진짜 매직 패킷을 쏘는" 구조다(Raspberry Pi/NAS를 릴레이로 씀).

**그런데 지금 우리 구성엔 그 "다른 상시 가동 기기"가 없다** — k3s-master/worker1/worker2가 전부 그 MacBook 한 대 위의 VM이다. MacBook이 잠들면 VM 전부 같이 죽고, 로컬 네트워크엔 신호를 릴레이해줄 게 아무것도 안 남는다. 즉 지금 상태로는 순수 소프트웨어/클라우드 조합만으로는 원격 wake가 불가능하다.

### 추가로 확인한 제약 (macOS 쪽)

- macOS의 Wake-on-LAN(정식 명칭 "Wake for network access")은 **Sleep 상태에서만 동작하고, 완전히 꺼지거나(shutdown) 크래시한 경우엔 안 먹힌다** ([macOS WoL 정리](https://grokipedia.com/page/Wake-on-LAN_on_macOS)) — 즉 "잠들었을 때"만 커버되고, 전원이 나가거나 커널 패닉 난 경우는 이 방법으로 못 살린다.
- **Wi-Fi로 연결된 경우 WoL 신뢰도가 낮다** — Apple 자체 AirPort/Time Capsule의 Bonjour Sleep Proxy가 없으면 서드파티 공유기 환경에서 Wi-Fi 기반 WoL이 잘 안 먹힌다는 보고가 많다 ([참고](https://iboysoft.com/wiki/wake-for-network-access.html)). **이더넷 연결이면 훨씬 안정적.**
- **공유기 자체의 "Wake on WAN"**(외부 인터넷에서 직접 매직 패킷 전달)도 확인했는데, 포트포워딩을 브로드캐스트 주소로 걸어야 해서 가정용 공유기 상당수(Netgear 포함)가 아예 지원을 안 한다 ([참고](https://community.netgear.com/discussions/home-cable-modems-routers/solved---remote-wake-on-lan-with-home-routers/1992844)). 라우터 모델에 따라 다름 — 확인 필요.

### 실제로 가능하게 만드는 방법 (순서대로, 비용/난이도 낮은 것부터)

| # | 방법 | 비용 | 커버 범위 | 비고 |
|---|---|---|---|---|
| 0 | **애초에 안 자게 만들기** | 무료 | 예방 자체 | Amphetamine이 실제로 살아있는지부터 재확인. 앱이 죽거나 로그아웃되면 무력화되는 게 약점 — `caffeinate -disu`를 LaunchDaemon으로 등록하면 로그인 세션과 무관하게 부팅 시 자동 실행되어 더 견고함. **이게 되면 애초에 wake-up 자체가 필요 없어진다.** |
| 1 | **공유기 자체 WoL 지원 확인** | 무료(지원하면) | Sleep만 | 쓰고 있는 공유기 모델이 "Wake on WAN" 또는 앱에서 원격 WoL 트리거를 지원하는지 확인. 지원하면 추가 하드웨어 없이 끝 |
| 2 | **Raspberry Pi(또는 다른 상시 가동 기기) + Tailscale 릴레이** | ~5~7만원 (Pi Zero 2 W 기준) | Sleep만, 안전함(전원 안 끊음) | [Tailscale 공식 가이드](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap) 그대로 따라가면 됨 — UpSnap 같은 웹 UI로 폰에서 버튼 눌러 깨우는 것까지 가능. 데이터 손상 위험 없음 |
| 3 | **스마트 플러그로 강제 전원 차단/복구** | ~2만원 | Sleep + 완전 다운/크래시까지 | 유일하게 "커널 패닉/먹통"까지 커버하지만, **강제 전원 차단이라 Postgres/Kafka가 쓰기 작업 중이면 데이터 손상 위험이 있음** — 최후의 수단으로만, 평소엔 안 씀 |

### 결론

지금 당장은 "시그널 하나 보내면 깨어남"이 불가능하다 — 이건 소프트웨어 설정 문제가 아니라 **그 신호를 로컬에서 받아 릴레이할 두 번째 기기가 물리적으로 없어서**다. 가장 현실적인 다음 단계는 **0번(안 자게 만들기 재점검)을 먼저 하고, 그래도 재발하면 2번(라즈베리파이 릴레이)을 추가**하는 것 — 이게 안전하고, Tailscale 생태계에서 이미 검증된 표준 패턴이다.
