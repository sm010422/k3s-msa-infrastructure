# Multipass 운영 가이드

VMware Fusion에서 Multipass로 마이그레이션(`docs/VMware-to-Multipass-Cluster-Migration.md`)한 이후, 이 클러스터를 일상적으로 다룰 때 참고하는 실전 가이드. 마이그레이션 과정에서 겪은 시행착오를 바탕으로 한 "하다가 막히는 지점"과 그 해결법 위주로 정리한다.

## 1. 현재 인벤토리 (기준: 이 문서 작성 시점)

| VM 이름 | 로그인 계정 | 역할 | CPU | 메모리 | 디스크 | Tailscale IP |
|---|---|---|---|---|---|---|
| k3s-master | `server1` (`ubuntu`도 존재) | control-plane | 2 | 3GB | 12GB | `100.103.119.1` |
| k3s-worker1 | `server2` | worker | 1 | 1.5GB | 14GB | `100.122.146.63` |
| k3s-worker2 | `server3` | worker | 1 | 1.75GB | 14GB | `100.83.49.100` |

Multipass 자체 브리지 IP(`192.168.252.x`)도 있지만, k3s/Tailscale 트래픽은 전부 **Tailscale IP(`100.x.x.x`)** 기준으로 동작한다 (`--flannel-iface tailscale0`로 설치했기 때문). 브리지 IP는 신경 쓸 필요 없음.

호스트(Multipass가 도는 macOS): `100.112.104.24` (SSH: `sangmin` / 비밀번호는 별도 전달됨)

## 2. 기본 명령어

```bash
# 반드시 필요: multipass 바이너리가 기본 PATH에 없음
export PATH="/usr/local/bin:$PATH"

multipass list                        # 전체 VM 목록 + 상태 + IP
multipass info k3s-master             # 상세 스펙, 디스크/메모리 사용량, 스냅샷 여부
multipass exec k3s-master -- <cmd>     # VM 안에서 명령 실행 (비대화형)
multipass shell k3s-master             # VM 안으로 인터랙티브 셸 진입
multipass stop k3s-master              # 정지
multipass start k3s-master             # 시작
multipass restart k3s-master           # 재시작
multipass transfer <local> <vm>:<path> # 파일 업로드 (반대 방향도 가능: <vm>:<path> <local>)
multipass delete k3s-master --purge    # ⚠️ 완전 삭제 (아래 6절 전에 신중히)
```

`multipass exec`은 기본 계정(`ubuntu`)으로 sudo 없이 실행되며, root 권한이 필요하면 `sudo`를 명시해야 한다. 예: `multipass exec k3s-master -- sudo k3s kubectl get nodes`.

## 3. 리소스 조정 — 반드시 정지 상태에서만

디스크/메모리 증설은 **온라인 리사이즈가 안 된다.** VM을 멈춘 상태에서만 `multipass set`이 먹는다. (마이그레이션 중 디스크 부족으로 실제로 겪은 문제, `docs/VMware-to-Multipass-Cluster-Migration.md` 5.2절 참고)

```bash
multipass stop k3s-worker2
multipass set local.k3s-worker2.memory=1.75G
multipass set local.k3s-worker2.disk=14G      # 디스크는 늘리기만 가능, 줄이기는 불가
multipass set local.k3s-worker2.cpus=2
multipass start k3s-worker2
```

**주의**: 리사이즈로 VM을 재기동하면, 그 노드에 떠 있던 파드는 재스케줄링/재시작된다. 운영 중인 서비스가 있다면 트래픽이 적은 시간대에 진행할 것.

## 4. VM 생성 시 자주 겪는 문제

### 4.1 이미지 캐시 해시 불일치

```
launch failed: Hash of .../ubuntu-24.04-server-cloudimg-arm64.img does not match ...
```

캐시된 이미지가 손상된 경우 발생. 재시도하면 대개 자동으로 재다운로드되어 해결된다. 안 되면 캐시를 직접 지우고 재시도:

```bash
sudo rm -rf "/var/root/Library/Caches/multipassd/qemu/vault/images/<image-dir>"
multipass launch 24.04 --name <vm-name> --cpus <n> --memory <n>G --disk <n>G
```

### 4.2 디스크는 넉넉하게 잡을 것

앱 자체 용량뿐 아니라 **이미지 pull 용량까지 감안**해야 한다. ArgoCD 하나만 해도 서버/repo-server/dex/redis/notifications/applicationset용 이미지가 수백MB~1GB씩 나간다. 워커 디스크를 6GB로 잡았다가 `DiskPressure`로 파드가 통째로 멈춘 적이 있다(`kubectl describe node`에서 `DiskPressure: True` 확인 가능). **워커 기준 최소 12~14GB 이상 권장.**

### 4.3 비대화형 SSH/스크립트에서 sudo

`multipass exec`으로 스크립트를 돌릴 때 `sudo`가 비밀번호를 요구하면 (`sudo: a terminal is required`) 아래처럼 처리:

```bash
multipass exec k3s-master -- sudo bash -c "명령어..."   # 대개 multipass exec 세션은 sudo 무암호 가능
```

## 5. SSH 접속 (Multipass 기본 방식 vs 우리가 추가한 방식)

- **Multipass 표준 방식**: `multipass shell <vm>` 또는 `multipass exec <vm> -- bash` — Multipass가 내부적으로 키를 관리해서 별도 계정/비밀번호 불필요. **호스트(100.112.104.24)에 먼저 SSH로 들어간 다음에만** 쓸 수 있다.
- **이번에 추가한 방식**: 각 VM에 `server1`/`server2`/`server3` 계정을 만들고 비밀번호 로그인을 열어서, 호스트를 거치지 않고 **어디서든 `ssh server1@100.103.119.1`** 형태로 바로 접속 가능하게 함 (Tailscale IP 기준). 자세한 내용과 설정 방법은 `docs/VMware-to-Multipass-Cluster-Migration.md` 8.1절 참고.
- Ubuntu cloud image는 기본적으로 `PasswordAuthentication no`이므로, 새로 VM을 만들 때마다 비밀번호 로그인이 필요하면 `/etc/ssh/sshd_config.d/`에 override 파일을 추가해야 한다 (8.1절 명령어 참고).

## 6. VM 삭제 (신중하게)

```bash
multipass stop <vm>
multipass delete <vm>
multipass purge          # 삭제 대기 상태(deleted)인 VM들을 완전히 지움 — 되돌릴 수 없음
```

`delete`만으로는 완전히 사라지지 않고 "삭제 대기" 상태로 남는다 (`multipass list`에 `Deleted`로 표시). **`purge`를 실행해야 진짜로 디스크에서 지워진다.** 실수로 지운 걸 되돌리고 싶으면 `purge` 전에 `multipass recover <vm>`으로 복구 가능.

## 7. 클러스터 재기동 순서 (호스트 자체를 재부팅했을 때)

Multipass VM은 `multipassd`(launchd 서비스)가 살아있는 한 호스트 재부팅 후에도 자동으로 다시 시작된다. 다만 k3s 서비스 자체는 각 VM의 systemd가 관리하므로 별도 조치 불필요 — VM이 뜨면 `k3s`/`k3s-agent` 서비스도 `systemctl enable`되어 있어 자동 기동된다. 재부팅 후 확인 순서:

```bash
multipass list                                          # 전부 Running인지
multipass exec k3s-master -- sudo k3s kubectl get nodes  # 3노드 Ready인지
multipass exec k3s-master -- sudo k3s kubectl get pods -n argocd
```

## 8. 트러블슈팅 — Tailscale이 주기적으로 끊김 (Clamshell Sleep)

### 증상

호스트(macbookair, `100.112.104.24`)가 Tailscale에서 갑자기 `offline`으로 뜨고, 그 위에서 도는 `k3s-master`/`k3s-worker1`/`k3s-worker2` 3대도 **동시에** `offline`으로 표시된다. 이 호스트는 노트북을 뚜껑 닫고 외부 모니터 없이 헤드리스로 운영 중이다.

### 원인 조사

호스트에 SSH로 들어가서 절전 로그를 확인한다.

```bash
ssh sangmin@100.112.104.24
pmset -g log | grep -E 'Entering Sleep|Wake from|DarkWake' | tail -60
pmset -g assertions   # 현재 걸려있는 절전 방지 assertion 목록
pmset -g custom       # 전원별(배터리/어댑터) 상세 설정
```

로그에 아래처럼 `Maintenance Sleep`으로 진짜 Sleep 상태에 들어간 기록이 반복해서 남아있으면 이 케이스다.

```
Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using AC (Charge:80%) 1015 secs
...
DarkWake from Deep Idle [CDN] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using AC (Charge:80%) 45 secs
```

`pmset -g assertions`로 확인해보면 Amphetamine의 assertion(`PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`)은 수백 시간째 끊김 없이 유지되고 있다 — Amphetamine 자체가 죽거나 설정이 바뀐 게 아니다. 다만 이 assertion들은 "사용자 유휴 상태로 인한 절전"만 막을 뿐, 아래 원인은 못 막는다.

### 진짜 원인: Clamshell Sleep

외부 디스플레이가 연결되지 않은 상태에서 뚜껑을 닫으면 macOS는 무조건 Clamshell Sleep에 들어간다. Apple의 클램셸 모드(뚜껑 닫고도 안 자는 것) 공식 조건이 "외부 디스플레이 연결 + 전원 연결"이라, 디스플레이가 없는 헤드리스 구성에서는 Amphetamine의 `PreventUserIdleSystemSleep` assertion으로 우회가 안 된다.

**`powernap` 설정은 이 문제와 무관하다.** `powernap 1`(켜짐)일 때는 macOS가 백그라운드 유지보수를 위해 10~17분마다 짧게 깨어나면서 그 틈에 Tailscale이 잠깐 붙었다 끊기길 반복해 "금방 복구되는 문제"처럼 보이지만, 이건 진짜 복구가 아니라 Clamshell Sleep 중에 우연히 열리는 짧은 접속 창일 뿐이다. `powernap 0`(꺼짐)으로 바꾸면 이 주기적 깨어남 자체가 사라지고, 유지보수 사이클 간격이 10~17분에서 **~60분(45초만 깨어남)**으로 늘어나 버려 체감상 "아예 안 돌아오는" 것처럼 보이게 된다. 즉 `powernap`을 어느 쪽으로 두든 근본 원인(Clamshell Sleep)은 그대로다 — powernap은 증상의 빈도만 바꿀 뿐 해결책이 아니다.

### 해결: `disablesleep`

AC 전원에 연결되어 있는 동안 시스템 절전을 통째로 비활성화하는 옵션으로, Apple이 헤드리스 Mac 서버 운영을 위해 공식 지원한다. lid 상태와 무관하게 동작한다.

```bash
sudo pmset -a disablesleep 1
```

시스템 설정 GUI로는: 설정(System Settings) → 배터리(Battery) → 우측 하단 **Options...** 버튼 → **"Prevent automatic sleeping on power adapter when the display is off"** 체크와 동일한 설정이다 (macOS 버전에 따라 배터리 화면 UI가 다르므로 "전원 어댑터" 탭이 따로 없을 수 있고, 이 경우 Options... 안에 통합되어 있다).

배터리 전원에서는 무시되므로(안전 장치) 이 호스트가 항상 어댑터에 물려있어야 유효하다 — 지금 구성과 맞는다. `powernap`은 0으로 둬도 무방하지만 원인이 아니므로 이 문제 해결과는 무관.

### 확인 시 주의: `disablesleep`은 `pmset -g custom` / `pmset -g everything`에 안 나타난다

`disablesleep`을 적용한 뒤 `pmset -g custom`이나 `pmset -g everything`으로 확인하면 **어디에도 `disablesleep` 항목이 안 보인다.** 이걸 보고 "적용이 안 됐다"고 오판하기 쉬운데(실제로 이 문서를 쓰다가 한 번 이렇게 잘못 결론 내렸었다), 확인은 반드시 이렇게 해야 한다:

```bash
pmset -g | head -3
```

```
System-wide power settings:
 SleepDisabled		1
```

`System-wide power settings:` 블록 아래 `SleepDisabled 1`이 찍히면 정상 적용된 것 — 내부적으로 `disablesleep`은 `SleepDisabled`라는 이름으로 노출된다.

### 최종 검증 (2026-08-05 진행 중)

`sudo pmset -a disablesleep 1` 적용 후 `SleepDisabled 1` 확인까지는 완료. 다만 지금까지의 관찰은 뚜껑이 열려있는 상태에서 이루어진 것이라(Amphetamine이 이미 유휴 절전은 막고 있어서 뚜껑 열린 채로는 애초에 원인 재현이 안 됨), **뚜껑을 닫은 채로 최소 몇 시간 유지하면서 Maintenance Sleep이 다시 발생하는지 확인이 아직 안 끝났다.**

```bash
# 상태 확인 (원격, macbookpro 등 다른 기기에서)
tailscale status | grep macbookair

# 실제 sleep 이벤트 재발 여부 (macbookair에 SSH 가능할 때)
pmset -g log | grep -E 'Entering Sleep|Wake from|DarkWake' | tail -10
```

만약 뚜껑을 닫아둔 채로도 `Entering Sleep`이 다시 찍히면 `disablesleep`조차 이 macOS 버전(현재 26.5.2 "Tahoe")에서 Clamshell Sleep을 완전히 막지 못한다는 뜻이므로, 그때는 소프트웨어 설정을 포기하고 **HDMI/USB-C 더미 플러그(dummy display adapter)**로 진짜 외부 디스플레이가 연결된 것처럼 만들어 공식 클램셸 모드 조건을 하드웨어로 충족시키는 방법으로 넘어간다.

> **TODO**: 뚜껑 닫은 채 장시간(몇 시간) 방치 후 재확인 필요. 문제 없으면 이 TODO와 "최종 검증" 섹션 정리해서 결론만 남길 것.

## 9. 관련 문서

- `docs/VMware-to-Multipass-Cluster-Migration.md` — 전체 마이그레이션 과정과 트러블슈팅
- `docs/VMware-vs-Multipass-Tradeoffs.md` — 하이퍼바이저 선택 관점의 장단점
- `docs/VMware-vs-Multipass-Resource-Usage-Analysis.md` — 실측 리소스 사용량 비교
- `docs/Host-Memory-Reclamation-for-Multipass-VMs.md` — 호스트 메모리 회수 및 재배분 기록
