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

## 8. 관련 문서

- `docs/VMware-to-Multipass-Cluster-Migration.md` — 전체 마이그레이션 과정과 트러블슈팅
- `docs/VMware-vs-Multipass-Tradeoffs.md` — 하이퍼바이저 선택 관점의 장단점
- `docs/VMware-vs-Multipass-Resource-Usage-Analysis.md` — 실측 리소스 사용량 비교
- `docs/Host-Memory-Reclamation-for-Multipass-VMs.md` — 호스트 메모리 회수 및 재배분 기록
