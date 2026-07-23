# VMware Fusion → Multipass K3s 클러스터 마이그레이션 기록

MacBook Air(RAM 8GB, Apple Silicon 8코어)에서 VMware Fusion으로 운영하던 K3s 3노드 클러스터(마스터 1 + 워커 2)를 Multipass 기반으로 전환한 작업 기록. SSH 원격 작업으로 진행했고, 각 단계마다 결과를 확인하며 순차 진행했다.

## 0. 왜 옮겼나

- VMware Fusion은 SVGA 3D 에뮬레이션, VMware Tools 상주 데몬, 스냅샷/체크포인트 등 데스크톱 가상화 기능이 붙어 있어 하이퍼바이저 자체 오버헤드가 있다.
- Apple Silicon에서 Multipass는 macOS 네이티브 `Virtualization.framework`(vz)를 사용해 훨씬 가볍다.
- 다만 실측 결과, 하이퍼바이저 교체 자체의 절감분보다 **VM 스펙 재설계**(구성 5.6GB → 신규 6GB로 유사하지만, 이 과정에서 리포 문서에 남아있던 "OOM 이후 상향 조정된 진짜 운영 스펙"을 발견하고 반영한 것)의 영향이 더 컸다. 자세한 내용은 2절 참조.

## 1. 마이그레이션 전 상태 조사

### 1.1 호스트 환경

| 항목 | 값 |
|---|---|
| OS | macOS 26.5.2 (arm64, Apple Silicon) |
| CPU | 8코어 (Performance 4 + Efficiency 4) |
| RAM | 8GB |
| 디스크 여유 | 약 37GB (`/System/Volumes/Data` 기준) |

### 1.2 기존 VMware VM 실제 스펙 (중요한 발견)

리포에 기록된 원래 설계는 **마스터 2GB / 워커 1GB×2**였지만, `docs/K3s-Node-Resource-Planning-Troubleshooting.md`에 기록된 과거 OOM 장애(워커 노드가 랜덤하게 NotReady에 빠지는 연쇄 장애) 이후 실제 운영 중인 VM은 이미 상향 조정되어 있었다.

| VM | 역할 | 설계 스펙(문서) | **실제 운영 스펙** |
|---|---|---|---|
| server1 | Control-plane | 2GB / 2vCPU | **2.5GB(2560MB) / 2vCPU** |
| server2 | Worker | 1GB / 2vCPU | **1.5GB(1536MB) / 2vCPU** |
| server3 | Worker | 1GB / 2vCPU | **1.5GB(1536MB) / 2vCPU** |

작업 시작 시점에 VM 3대가 모두 켜져 있었고, 호스트 여유 메모리는 `memory_pressure` 기준 **약 260MB**(524288페이지 중 free 15918페이지)로 사실상 포화 상태였다. 즉 VMware VM을 켜둔 채로는 Multipass VM을 추가로 띄울 여력이 전혀 없었다.

### 1.3 기존 클러스터 구성 조사 결과

- k3s 버전: `v1.34.5+k3s1`
- 네트워킹: `--flannel-iface tailscale0` (server, agent 모두 동일 플래그로 설치) — 클러스터 내부 통신을 Tailscale 오버레이망으로 제한
- Tailscale IP: server1 `100.116.194.42`, server2 `100.92.119.127`, server3 `100.106.186.41`
- swap: 노드당 2GB (`/swapfile`, `/etc/fstab` 영구 등록), `vm.swappiness=10`
- 마스터 taint: **미적용** (`docs/...Troubleshooting.md`에는 적용 권장 사항으로 기록돼 있었으나 실제로는 적용된 적 없음)
- ArgoCD: `argocd` 네임스페이스, Application은 `target-tracking-service` 1개만 Synced/Healthy 상태로 배포 중
  - `repoURL: https://github.com/sm010422/k3s-msa-infrastructure.git` (public, HTTPS — 별도 repo credential 불필요)
  - `path: apps/target-tracking-service`, destination namespace `c4i`
  - `syncPolicy.automated`(`prune: true`, `selfHeal: true`)
  - 리포에 `argocd/applications/defense-api-gateway.yaml`도 있었지만 **실제 클러스터에는 배포되어 있지 않았음** → 마이그레이션도 실제 라이브 상태(target-tracking-service만)를 그대로 재현하기로 함
- ArgoCD Image Updater 파이프라인 (`docs/ArgoCD-Image-Updater-target-tracking-service.md` 참고):
  - target-tracking-service 리포 CI → Docker Hub push → Image Updater가 2분 간격 폴링 → digest 변경 감지 시 SSH Deploy Key로 인프라 리포에 write-back 커밋 → ArgoCD selfHeal이 반영
  - git에 없는 진짜 시크릿: `argocd` 네임스페이스의 `git-creds`(SSH private key, write-back 전용 Deploy Key)
- c4i 네임스페이스 워크로드: `kafka`(confluentinc/cp-kafka:7.4.0), `postgres`(pgvector/pgvector:pg16, PVC 2Gi `local-path`), `redis`(redis:7-alpine), `target-tracking-service`(sm010422/target-tracking-service:latest)

## 2. 마이그레이션 방침 결정 (사용자 확인 사항)

작업 도중 다음 사항들을 확인받고 진행했다.

1. **VMware VM 처리**: 절대 삭제 금지, 필요시 언제든 재기동 가능한 형태로만 보존. → 결론: **정상 종료(clean shutdown)**로 RAM만 회수 (suspend는 메모리 스냅샷을 디스크에 통째로 저장해 불필요하게 디스크를 소모하므로 채택하지 않음).
2. **VM 스펙**: 호스트 8코어/8GB 기준으로 마스터 3GB/2vCPU, 워커 1.5GB/1vCPU×2(합계 6GB)로 결정. 기존 실제 운영 스펙(5.6GB)보다 넉넉하게, 그러나 과도하지 않게(macOS 자체 베이스라인 오버헤드 고려) 잡음.
3. **Tailscale 조인 방식**: 재사용 가능한(reusable) auth key 발급받아 사용.
4. **마스터 taint**: 기존 클러스터엔 없었지만, 문서에 기록된 재발 방지책(control-plane을 앱 워크로드로부터 격리)을 신규 클러스터에는 적용하기로 결정.

## 3. 실행 절차

### 3.1 기존 클러스터 설정 백업 (1차)

```bash
# argocd 네임스페이스의 git-creds secret (image-updater write-back용 SSH 키)
kubectl get secret git-creds -n argocd -o yaml > git-creds-secret.yaml
# 기존 kubeconfig (롤백/참고용)
cat /etc/rancher/k3s/k3s.yaml > old-cluster-kubeconfig.yaml
```

> ⚠️ **놓친 부분**: 이 시점에는 `argocd` 네임스페이스만 확인하고 `c4i` 네임스페이스의 애플리케이션 시크릿은 확인하지 않았다. 이게 후반부(5.5절)에 문제를 일으킨다.

### 3.2 Multipass 설치

```bash
brew install --cask multipass
```

- 설치는 됐으나 `multipass` 바이너리가 PATH에 없어 `command not found`로 잠깐 헤맴 → 실제 바이너리는 `/usr/local/bin/multipass`(→ `/Library/Application Support/com.canonical.multipass/bin/multipass` 심볼릭 링크)에 설치됨. `PATH="/usr/local/bin:$PATH"`로 해결.
- 설치 버전: Multipass 1.16.3

### 3.3 VMware VM 3대 종료 (RAM 확보)

```bash
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
"$VMRUN" stop ".../server1.vmwarevm/server1.vmx" soft
"$VMRUN" stop ".../server2.vmwarevm/server2.vmx" soft
"$VMRUN" stop ".../server3.vmwarevm/server3.vmx" soft
```

종료 후 호스트 여유 메모리: **260MB → 약 3.6GB**로 회복 (220378페이지 free). VM 파일은 그대로 보존.

### 3.4 Multipass VM 3대 생성

```bash
multipass launch 24.04 --name k3s-master  --cpus 2 --memory 3G   --disk 12G
multipass launch 24.04 --name k3s-worker1 --cpus 1 --memory 1.5G --disk 6G
multipass launch 24.04 --name k3s-worker2 --cpus 1 --memory 1.5G --disk 6G
```

- 첫 `k3s-master` 생성 시 `launch failed: Hash of .../ubuntu-24.04-server-cloudimg-arm64.img does not match ...` 에러 발생 (이미지 캐시 손상). 재시도하니 자동으로 정상 다운로드되어 해결됨.
- 워커 디스크는 처음에 6GB로 잡았는데, 이게 3.5절 후반에 문제가 된다 (→ 5.2절).

### 3.5 Tailscale 설치 및 조인

```bash
# 3대 모두
curl -fsSL https://tailscale.com/install.sh | sudo sh
```

조인 과정에서 두 번의 시행착오가 있었다.

1. 처음 받은 auth key로 `k3s-master`는 조인 성공했지만, 같은 키로 `k3s-worker1/2`를 조인하려 하자 `backend error: invalid key: API key ... not valid`. → **1회용(single-use) 키**였던 것으로 확인. (reusable로 요청했지만 실제 발급은 1회용이었던 것)
2. reusable 키를 재발급받아 워커 2대 조인 성공.

```bash
sudo tailscale up --authkey=<AUTH_KEY> --hostname=<vm-name> --ssh
```

최종 Tailscale IP:

| 노드 | Tailscale IP |
|---|---|
| k3s-master | `100.103.119.1` |
| k3s-worker1 | `100.122.146.63` |
| k3s-worker2 | `100.83.49.100` |

### 3.6 swap 2GB 설정 (노드별 동일 적용)

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
sysctl -w vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
```

기존 `k3s-setup/swap-setup.sh`와 동일한 로직. 최신 k3s(v1.36.2)는 swap이 켜져 있어도 별도 `--kubelet-arg=fail-swap-on=false` 없이 정상 기동됨 (구버전 문서에 있던 "kubelet이 swap 있으면 기동 거부" 우려는 현재 버전에서는 해당 없음).

### 3.7 k3s 마스터 설치

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --flannel-iface tailscale0" sh -
```

- 설치된 버전: `v1.36.2+k3s1` (stable 채널 기준 최신 — 기존 클러스터의 `v1.34.5+k3s1`보다 상위 버전으로 마이그레이션됨. 마이너 버전 스킵 업그레이드가 아니라 신규 설치이므로 호환성 이슈 없음)
- `kubectl get nodes -o wide`의 INTERNAL-IP가 `100.103.119.1`(tailscale IP)로 잡히는 것으로 `--flannel-iface tailscale0` 정상 적용 확인

마스터 taint 적용 (2절의 결정 사항):

```bash
kubectl taint nodes k3s-master node-role.kubernetes.io/master=:NoSchedule
```

### 3.8 워커 2대 조인

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://100.103.119.1:6443 \
  K3S_TOKEN=<node-token> \
  INSTALL_K3S_EXEC="agent --flannel-iface tailscale0" sh -
```

`kubectl get nodes` 결과 3노드 모두 `Ready` 확인.

## 4. ArgoCD 재설치

### 4.1 ArgoCD 코어 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

첫 시도에서 에러:

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

`kubectl apply`(client-side apply)가 CRD 전체를 `last-applied-configuration` 어노테이션에 통째로 넣으려다 크기 제한(256KiB)을 초과해서 발생하는 잘 알려진 이슈. **server-side apply로 전환해 해결**:

```bash
kubectl apply -n argocd -f <install.yaml> --server-side --force-conflicts
```

### 4.2 Image Updater 설치 및 리소스 트리밍

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml
kubectl patch deployment argocd-image-updater-controller -n argocd \
  --type strategic --patch-file argocd/image-updater-resources-patch.yaml
```

리포에 이미 기록돼 있던 패치(`argocd/image-updater-resources-patch.yaml`)로 기본 리소스(request 250m/512Mi)를 실사용치 수준(request 50m/128Mi, limit 250m/256Mi)으로 낮춤 — 8GB RAM 클러스터에서 필수적인 최적화.

### 4.3 git-creds 시크릿 복원 및 ImageUpdater CR 적용

```bash
kubectl apply -f git-creds-secret.yaml   # 3.1절에서 백업해둔 것
kubectl apply -f argocd/image-updater.yaml   # ImageUpdater CR (target-tracking-service-updater)
```

### 4.4 target-tracking-service Application 재연결

```bash
kubectl apply -f argocd/applications/target-tracking-service.yaml
```

## 5. 트러블슈팅 (마이그레이션 중 실제로 겪은 문제들)

### 5.1 SSH 인증 실패 (`Too many authentication failures`)

작업 중간에 `sshpass` 경유 SSH가 간헐적으로 `Permission denied` → `Too many authentication failures`로 끊김. 원인은 ssh 클라이언트가 비밀번호 시도 전에 등록된 여러 identity(키) 인증을 먼저 시도하다 시도 횟수 제한에 걸리는 문제. `-o PreferredAuthentications=password -o PubkeyAuthentication=no` 옵션으로 해결.

### 5.2 워커 디스크 부족 → ArgoCD 이미지 pull 실패

ArgoCD 코어 설치 직후 파드들이 전부 `ImagePullBackOff`/`ErrImagePull`. 원인 조사:

```bash
ctr images pull quay.io/argoproj/argocd:latest
# ctr: failed to extract layer ... write .../usr/local/bin/helm: no space left on device
```

`kubectl describe nodes`로 확인한 노드 컨디션:

```
k3s-worker1  DiskPressure   True   KubeletHasDiskPressure
k3s-worker2  DiskPressure   True   KubeletHasDiskPressure
```

**원인**: 워커 VM 디스크를 6GB로 잡았는데, OS(4.4GB) + ArgoCD 이미지 여러 개(quay.io/argoproj/argocd는 서버/repo-server/dex/redis/notifications/applicationset 등 여러 컴포넌트가 같은 대형 이미지를 공유하지만 합쳐서 수백MB~1GB대)를 감당하기엔 턱없이 부족했음.

**해결**:

```bash
multipass stop k3s-worker1 k3s-worker2
multipass set local.k3s-worker1.disk=14G
multipass set local.k3s-worker2.disk=14G
multipass start k3s-worker1 k3s-worker2
```

Multipass는 정지 상태에서만 디스크 증설 가능 (온라인 리사이즈 미지원, 축소는 애초에 불가). 증설 후 각 노드 8GB 여유로 회복, DiskPressure 해제.

디스크 리사이즈로 워커가 재기동되면서 예전 파드들이 `ContainerStatusUnknown` 상태로 유령처럼 남았음 → 강제 정리:

```bash
kubectl delete pod -n argocd --field-selector=status.phase!=Running --grace-period=0 --force
```

### 5.3 마스터 taint 적용으로 인한 메모리 재분배

마스터에 `NoSchedule` taint를 걸었기 때문에, ArgoCD 전체 컴포넌트(server/repo-server/redis/dex/notifications/applicationset/image-updater) + 앱 워크로드(kafka/postgres/redis/target-tracking-service)가 **워커 2대(합계 3GB)에만** 스케줄링된다. 기존 클러스터(taint 없음, 3노드 5.6GB 전체에 분산 가능)보다 실질적으로 가용 메모리 풀이 좁아진 셈.

실제로는 별문제 없이 안정화됐지만(최종 워커 메모리 available 535~674Mi 확보), 향후 `defense-api-gateway`처럼 워크로드가 추가되면 이 지점이 다시 병목이 될 수 있다. **후속 과제로 남김** (7절 참고).

### 5.4 CRD 적용 시 "일시적" 시크릿 not found

`argocd-application-controller-0` 파드가 잠깐 `CreateContainerConfigError: secret "argocd-redis" not found`를 뱉었는데, 이는 `argocd-redis` 파드/시크릿이 아직 초기화되는 중이라 생긴 스타트업 순서 레이스 컨디션이었고 몇 초 뒤 자동 재시도로 해소됨 (별도 조치 불필요).

### 5.5 진짜 문제: `target-tracking-secrets` 시크릿 백업 누락

target-tracking-service Application을 동기화하자 `kafka`, `postgres`, `target-tracking-service` 파드가 전부:

```
Error: secret "target-tracking-secrets" not found
```

**원인**: `c4i` 네임스페이스의 `target-tracking-secrets`(DB 계정/비밀번호, Gemini API 키)는 ArgoCD가 관리하는 매니페스트에 없는 **수동으로 생성된 시크릿**이다. `apps/target-tracking-service/kustomization.yaml`의 리소스 목록에도 없다. 3.1절 백업 때 `argocd` 네임스페이스만 확인하고 `c4i` 네임스페이스 애플리케이션 시크릿은 확인하지 않아 통째로 누락됐다.

**복구**: 이미 종료해둔 VMware `server1`을 **일시적으로 재기동**해서 값을 추출한 뒤 즉시 재종료.

```bash
# server1 재기동 (호스트 메모리 여유 61MB 수준으로 매우 빠듯한 상태에서 진행, 면밀히 모니터링)
vmrun start server1.vmx nogui
# k3s 서비스 기동 대기 후
kubectl get secret target-tracking-secrets -n c4i -o yaml > target-tracking-secrets.yaml
# 즉시 종료
vmrun stop server1.vmx soft
# 신규 클러스터에 복원
kubectl apply -f target-tracking-secrets.yaml
```

복원 즉시 `kafka`, `postgres`, `target-tracking-service` 파드가 정상 기동. `target-tracking-service`는 부팅 초반 Kafka consumer group coordinator를 대상으로 `NOT_COORDINATOR`/`coordinator unavailable` 경고를 몇 초간 반복했는데, 이는 Kafka 브로커가 방금 뜬 직후 `__consumer_offsets` 파티션 리더 선출이 끝나기 전 컨슈머가 먼저 join을 시도해 생기는 **정상적인 콜드 스타트 과도기 현상**이며, 몇 초 뒤 자동으로 정상화됨.

> **교훈**: GitOps 클러스터라도 "git에 없는 상태"(imperative하게 만든 Secret, PV 데이터 등)는 별도로 반드시 목록화하고 백업해야 한다. `kubectl get secrets -A`로 애플리케이션 네임스페이스까지 전수 확인했어야 함.

## 6. 최종 검증 결과

### 6.1 노드 상태

```
NAME          STATUS   ROLES           VERSION        INTERNAL-IP
k3s-master    Ready    control-plane   v1.36.2+k3s1   100.103.119.1
k3s-worker1   Ready    <none>          v1.36.2+k3s1   100.122.146.63
k3s-worker2   Ready    <none>          v1.36.2+k3s1   100.83.49.100
```

### 6.2 ArgoCD Application

```
NAME                      SYNC STATUS   HEALTH STATUS
target-tracking-service   Synced        Healthy
```

### 6.3 c4i 네임스페이스 파드

```
NAME                                       READY   STATUS
kafka-698f8c58b7-rxgtc                     1/1     Running
postgres-699989454b-tngsr                  1/1     Running
redis-cd56df584-wh4sv                      1/1     Running
target-tracking-service-678785d864-svrt5   1/1     Running
```

### 6.4 리소스 사용 현황 (최종)

| 노드 | 총 메모리 | available | swap 사용 |
|---|---|---|---|
| k3s-master | 2.9Gi | 1.7Gi | 268Ki (거의 미사용) |
| k3s-worker1 | 1.4Gi | 674Mi | 268Ki |
| k3s-worker2 | 1.4Gi | 535Mi | 8.6Mi |

스왑을 거의 쓰지 않고도 안정적으로 구동 — 5.3절에서 우려했던 "워커 2대에 전부 몰림" 문제는 현재 워크로드 규모에서는 문제가 되지 않았다.

## 7. 마이그레이션 후 상태 및 후속 과제

### 7.1 기존 VMware VM 처리

- server1/2/3 모두 **정상 종료(soft shutdown) 상태로 보존**. 삭제하지 않았으며, VMware Fusion에서 언제든 재기동 가능.
- 새 클러스터 검증이 충분히 끝나면(예: 며칠간 운영 안정성 확인 후) 폐기 여부를 별도로 재검토하기로 함.

### 7.2 백업해둔 파일 (git에 커밋하지 않음, 로컬 보관)

- `git-creds-secret.yaml` (image-updater SSH deploy key)
- `target-tracking-secrets.yaml` (DB 계정/비밀번호, Gemini API 키)
- `old-cluster-kubeconfig.yaml`, `new-cluster-kubeconfig.yaml`

### 7.3 후속 과제

- [ ] 마스터 taint 적용으로 워커 2대에만 워크로드가 몰리는 구조가 됐으므로, `defense-api-gateway` 등 워크로드 추가 시 5.3절의 메모리 병목 재검토 필요
- [ ] `kubectl get secrets -A` 전수 조사를 정례화해 "git에 없는 상태" 자산을 별도 문서(예: `docs/Cluster-Secrets-Inventory.md`)로 관리하는 것을 검토
- [ ] Multipass VM은 온라인 디스크 리사이즈가 안 되므로, 다음에 VM을 새로 만들 때는 이미지 pull 용량을 감안해 워커도 최소 12~14GB로 처음부터 잡을 것
- [ ] k3s 버전이 `v1.34.5` → `v1.36.2`로 두 마이너 버전 올라갔으므로, 이후 리포 문서/스크립트에 하드코딩된 버전 참조가 있는지 점검
