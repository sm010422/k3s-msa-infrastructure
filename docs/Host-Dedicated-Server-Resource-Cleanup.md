# 호스트 전용 서버화 — 개인용 앱 리소스 정리 (2026-09-28)

## 목표

"최대한 서버 컴퓨터로만 작동하도록 유지" — 이 macOS 호스트는 k3s VM 3대(`multipass`)를 24/7 띄우는 용도가 전부이고, 사람이 직접 로그인해서 데스크톱으로 쓰는 일은 없어야 한다는 전제. 기존 `Host-Memory-Reclamation-for-Multipass-VMs.md`가 macOS 시스템 자체(Spotlight, 알림센터 위젯 등)를 다뤘다면, 이번엔 **개인 데스크톱 용도로 설치된 앱**들이 여전히 상시 실행 중인 걸 새로 찾아서 정리했다.

## 발견 — 개인용 앱들이 여전히 떠 있었다

<table fit-page-width="true" header-row="true">
<tr><td>프로세스</td><td>메모리</td><td>용도</td><td>조치</td></tr>
<tr><td>Magnet</td><td>22M</td><td>윈도우 스냅(화면 분할)</td><td>종료함 — 헤드리스 서버엔 무의미</td></tr>
<tr><td>Hammerspoon</td><td>22M</td><td>개인 자동화 스크립팅</td><td>종료함</td></tr>
<tr><td>WakaTime</td><td>21M</td><td>코딩 시간 트래커</td><td>종료함 — 서버 역할과 무관한 개인 생산성 도구</td></tr>
<tr><td>Karabiner-Console-User-Server</td><td>26M</td><td>키보드 리매핑(사용자 앱 부분)</td><td>종료함</td></tr>
<tr><td>Logi Options+ (`logioptionsplus_agent`)</td><td>56~94M</td><td>로지텍 마우스/키보드 커스터마이징</td><td>종료 + LaunchAgent bootout(`gui/501/com.logi.cp-dev-mgr`)으로 재기동까지 차단. root 소유 업데이터 스텁만 미미하게 남음(idle, 무시 가능)</td></tr>
<tr><td>AlDente</td><td>34M</td><td>배터리 충전 상한 제한</td><td>**유지 결정** — 24/7 AC 전원에 물린 랩탑 배터리 수명 보호 목적이라 서버 역할에도 필요. 제거 대상 아님</td></tr>
</table>

이번 라운드 회수량: 약 150~185MB (Karabiner-Console 26 + Magnet 22 + Hammerspoon 22 + WakaTime 21 + Logi Options+ 56~94).

## 손 못 댄 것 — Karabiner-Elements 본체

사용자 앱(Console-User-Server)만 종료했고, 다음은 그대로 뒀다:

- `Karabiner-Core-Service` (root + user, 2개 프로세스)
- `Karabiner-VirtualHIDDevice-Daemon` (root, LaunchDaemon)
- `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` (커널 수준 DriverKit 시스템 확장, `_driverkit` 계정)

이유: 전부 root 소유 LaunchDaemon이거나 커널 확장이라 `Host-Memory-Reclamation-for-Multipass-VMs.md`의 `chronod`/`sharingd`와 같은 SIP 인접 영역이다. 완전 제거하려면 공식 언인스톨러(시스템 확장 등록 해제 포함)가 필요한데, 정전 사건 이후 원격 SSH만으로 이런 커널 확장급 구성요소를 건드리는 건 재발 리스크가 부담스러워서 보류했다. 개별 메모리 비중도 작아서(합쳐도 수십 MB) 굳이 지금 위험을 감수할 이유가 적다.

## 가장 큰 단일 항목 — 로그인 GUI 세션 전체 (683MB), 아직 안 건드림

`Host-Memory-Reclamation-for-Multipass-VMs.md` 3.3절에서 이미 식별한 대로, `WindowServer`(313M) + `Finder`(58M) + `loginwindow`(41M) + `Dock`(45M) + `NotificationCenter`(45M) + `ControlCenter`(40M) ≈ **683MB**가 GUI 세션(Aqua) 유지 비용이다. 지금까지는 **Amphetamine이 GUI 세션에 의존**해서 로그아웃(헤드리스 전환)을 배제해왔다.

`Remote-Wake-and-Downtime-Alerting.md`에서 이미 제안한 대안이 여기서 다시 의미를 갖는다 — **`caffeinate -disu`를 LaunchDaemon으로 등록**하면 GUI 세션과 무관하게 절전 방지가 동작한다. 이걸 먼저 검증하고 Amphetamine을 대체하면, 로그아웃으로 이 683MB까지 회수할 수 있는 길이 열린다.

"최대한 서버 컴퓨터로만 작동"이라는 목표에 가장 크게 기여할 단일 조치지만, 원격 접속 방식 자체가 바뀌는 변경(Screen Sharing 불가가 됨 — Tailscale SSH는 영향 없음)이라 **여기서 바로 실행하지 않고 검토 항목으로만 남긴다.**

## 여전히 SIP/권한으로 막힌 것

`chronod`(Screen Time), `sharingd`(AirDrop/Handoff), `syspolicyd`(Gatekeeper) — `Host-Memory-Reclamation-for-Multipass-VMs.md`와 동일하게 SIP가 `launchctl bootout`을 막는다. System Settings GUI에서 끄면 될 가능성이 있지만, 원격 SSH의 `osascript`로 System Events 자동화를 시도하면 권한 승인이 필요해서 막힌다(`User canceled` 에러) — 물리적으로 화면 앞에 있거나 화면 공유 세션이 있어야 확인 가능하다.

## 다음 액션 (제안, 우선순위순)

1. **`caffeinate -disu` LaunchDaemon 검증 → 로그아웃 전환 (683MB)** — 가장 임팩트 크지만 원격 접속 방식이 바뀌므로 실행 전 확인 필요
2. **Karabiner-Elements 완전 제거 검토** — 이 컴퓨터를 물리 키보드로 다시 쓸 계획이 없다면 공식 언인스톨러로 커널 확장까지 정리. 화면 앞에서 처리 권장
3. **Screen Time / AirDrop·Handoff 끄기** — GUI 필요, 다음에 물리적으로 접근할 때 처리
4. **재부팅 후 재검증** — `Magnet`/`Hammerspoon`/`WakaTime`이 로그인 항목으로 등록돼 있는지 이번엔 확인 못 했다(System Events 권한 문제). 다음 재부팅 후 다시 떠 있는지 확인 필요 — `Host-Memory-Reclamation-for-Multipass-VMs.md`의 알림센터 위젯처럼 세션마다 재킬해야 할 수 있다.
