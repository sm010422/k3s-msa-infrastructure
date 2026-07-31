# 호스트 유휴 메모리 회수 및 워커 노드 재배분

Multipass 마이그레이션(`docs/VMware-to-Multipass-Cluster-Migration.md`) 완료 후, "호스트에 남는 여유 메모리 자체를 최소화하고, 그만큼을 노드(VM)에 더 얹고 싶다"는 목표로 진행한 작업 기록. 즉 호스트 macOS가 불필요하게 들고 있는 메모리를 찾아 줄이고, 회수분을 워커 노드 스펙에 반영했다.

## 1. 목표와 제약

- 목표: 호스트(macOS)에서 서버 용도로 불필요한 프로세스가 쓰는 메모리를 최대한 줄이고, 회수한 만큼 워커 노드 메모리를 늘린다.
- 제약: **Amphetamine(절전 방지 앱)은 절대 건드리지 않는다.** 이 호스트는 Tailscale/SSH로 상시 원격 접속하는 서버 역할이라 절전 방지가 핵심 요구사항.

## 2. 조사 — 프로세스별 메모리 사용량

`top -o mem`으로 확인한 host 프로세스 상위 목록 (VM 자체인 `qemu-system-aarch64` 3개 제외):

| 프로세스 | 메모리 | 정체 |
|---|---|---|
| WindowServer | 310M | GUI 세션(Aqua) 렌더링 |
| chronod | 289M | Screen Time 데몬 |
| Finder | 119M | GUI |
| VMware Fusion | 79M | VM은 이미 정지 상태인데 앱만 켜져 있음 |
| Spotlight (앱) | 79M | 검색 인덱싱 |
| loginwindow | 78M | 로그인 세션 |
| syspolicyd | 63M | Gatekeeper |
| Dock | 57M | GUI |
| multipassd | 56M | Multipass 데몬 (필수) |
| Tailscale | 54M | 필수 |
| NotificationCenter | 52M | GUI |
| Amphetamine | 51M | **절전 방지 — 절대 유지** |
| ControlCenter | 45M | GUI |
| WallpaperImageExtension | 44M | 배경화면 렌더링 |
| mds | 35M | 검색 인덱싱 데몬 |
| sharingd | 31M | AirDrop/Handoff |
| StocksWidget / WeatherWidget | 30M / 28M | 알림센터 위젯 |
| universalAccessAuthWarn | 30M | 손쉬운 사용 관련 에이전트 |
| TextInputMenuAgent | 30M | 입력 메뉴 |
| sirittsd | 28M | Siri TTS |

## 3. 실행 — 무엇을 껐고, 무엇을 못 껐나

### 3.1 확실히 회수된 것

| 조치 | 방법 | 결과 |
|---|---|---|
| VMware Fusion 앱 종료 | `osascript -e 'quit app "VMware Fusion"'` | 79MB 회수, VM 파일은 그대로 보존 (재실행 시 다시 사용 가능) |
| Spotlight 인덱싱 비활성화 | `sudo mdutil -a -i off` (전체 볼륨) | 인덱싱 중단. 기존 프로세스(`Spotlight`, `mds`)는 launchd가 즉시 재기동시키지만, 인덱싱 대상이 없어지므로 시간이 지나며 자원 사용이 서서히 줄어듦 (`mds` 35M → 23M로 확인) |
| 유휴 알림센터 위젯/에이전트 종료 | `kill -9 <pid>` (직접 프로세스 시그널, `launchctl bootout` 아님) | `sirittsd`, `universalAccessAuthWarn`, `StocksWidget`, `WeatherWidget` — **재실행되지 않고 완전히 종료됨** (약 116MB) |

**합계 확정 회수량: 약 250~300MB** (호스트 `memory_pressure` 기준 free 페이지가 약 62MB → 127MB로 증가, 대략 2배)

### 3.2 시도했지만 안 된 것 — SIP(System Integrity Protection)

```
Boot-out failed: 150: Operation not permitted while System Integrity Protection is engaged
```

`chronod`(Screen Time, 289M)와 `sharingd`(AirDrop/Handoff, 31M)는 `launchctl bootout`으로 시도했으나 SIP가 시스템 데몬 강제 종료를 막았다. `sharingd`는 `kill -9`로 직접 죽여도 launchd가 즉시 재기동시킴 (KeepAlive 정책). SIP를 끄려면 복구모드 재부팅이 필요한데, 원격 SSH 작업 중인 서버에서 이건 너무 위험한 작업이라 **시도하지 않았다.**

### 3.3 의도적으로 남긴 것 — GUI 세션(Aqua) 전체

`WindowServer`(310M) + `Finder`(119M) + `loginwindow`(78M) + `Dock`(57M) + `NotificationCenter`(52M) + `ControlCenter`(45M) ≈ **약 683MB**는 로그인 GUI 세션을 유지하는 데 드는 비용이다.

완전 헤드리스(로그아웃 상태)로 전환하면 이 683MB를 거의 다 회수할 수 있지만, **Amphetamine은 GUI 세션이 살아있어야 절전 방지 기능이 동작**하므로 이 경로는 처음부터 배제했다. 이번 조사에서 회수 가능한 것과 회수 시도조차 하지 않은 것을 명확히 구분해서 기록해둔다.

## 4. 재배분 — 워커 노드 메모리 증설

회수된 약 250~300MB 중, 당시 `available` 메모리가 가장 빠듯했던 `k3s-worker2`(535Mi)에 256Mi를 반영했다.

```bash
multipass stop k3s-worker2
multipass set local.k3s-worker2.memory=1.75G   # 1.5G → 1.75G
multipass start k3s-worker2
```

디스크와 마찬가지로 메모리 변경도 **VM 정지 상태에서만** 가능하다. 재기동 중 해당 노드에 있던 `kafka` 파드가 한 번 재시작됐으나 (`RESTARTS 1`) 자동으로 정상 복구됨.

## 5. 최종 클러스터 스펙

| 노드 | 이전 | 이후 |
|---|---|---|
| k3s-master | 3GB | 3GB (변경 없음) |
| k3s-worker1 | 1.5GB | 1.5GB (변경 없음) |
| k3s-worker2 | 1.5GB | **1.75GB** |
| **합계** | 6GB | **6.25GB** |

재기동 후 검증: 3노드 모두 `Ready`, `target-tracking-service` Application `Synced`/`Healthy`, `c4i` 네임스페이스 파드 전부 `1/1 Running`.

## 6. 교훈

- macOS 호스트에서 "안 쓰는 메모리 회수"는 생각보다 상한선이 낮다. 회수 가능한 대상은 크게 세 그룹으로 나뉜다: (1) 확실히 끌 수 있는 사용자 앱/캐시성 데몬 (2) 유저 세션 소속이라 킬은 되지만 트리거 시 재기동되는 것들 (3) SIP로 원천 차단된 시스템 데몬. 이번엔 (1)에서만 실질적인 이득(~250~300MB)을 봤다.
- "회수한 만큼 VM에 얹는다"는 접근은 목표 자체가 명확했기 때문에 안전 마진을 지키기 쉬웠다 — 회수량(250~300MB)보다 적은 256MB만 반영해서, 결과적으로 호스트 쪽 여유를 깎아먹지 않았다.
- 절전 방지처럼 사용자가 명시적으로 지키라고 한 제약(Amphetamine)이 있으면, 그 제약이 걸어놓는 상한선(이번엔 GUI 세션 683MB)을 정확히 식별하고 그 안에서만 움직여야 한다.
