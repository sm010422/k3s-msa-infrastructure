# 온프레미스 K3s 클러스터 — 노드 리소스 배치 설계 & 트러블슈팅 기록

제한된 하드웨어(MacBook Air VMware VM 3대, Master 2GB / Worker 1GB×2 + Swap 2GB)에서 K3s 클러스터를 운영하며 겪은 리소스 배치 문제와 설계 판단 근거 기록.

## 1. 문제 상황

VM 리소스가 클라우드 대비 매우 제한적인 환경(Master 2GB, Worker 각 1GB + Swap 2GB)에서, 아래 워크로드를 어떻게 배치할지 결정해야 했다.

- `defense-api-gateway` (API Gateway)
- `target-tracking-service` (Spring Boot 기반 표적 추적 서비스)
- Kafka
- Redis
- PostgreSQL + pgvector

## 2. 초기 배치안

| 노드 | 역할 | 배치 컴포넌트 | 메모리 합계 |
|---|---|---|---|
| server1 (Master, 2GB) | Control Plane 전용 | K3s server / etcd / kube-apiserver / scheduler (~900MB) | — |
| server2 (Worker, 1GB + Swap 2GB) | 앱 워크로드 | defense-api-gateway ×1(192Mi), target-tracking-service ×1(256Mi), Redis(~80Mi) | ~528Mi (여유) |
| server3 (Worker, 1GB + Swap 2GB) | 앱 워크로드 | defense-api-gateway ×1(192Mi), target-tracking-service ×1(256Mi), Kafka(~400Mi) | ~848Mi (빠듯) |

## 3. 핵심 판단 1 — Master는 Control Plane 전용으로 격리

### 근거
etcd(클러스터의 모든 상태를 저장하는 저장소)가 마스터 노드에서 돌아가는데, 여기서 앱 파드까지 스케줄링되다가 OOM이 발생하면 **etcd 자체가 죽어서 클러스터 전체가 마비**될 수 있다. 2GB라는 한정된 메모리에서 이 리스크를 원천 차단하기 위해 앱 파드의 마스터 스케줄링을 막기로 결정.

### 적용 명령어
```bash
kubectl taint nodes server1 node-role.kubernetes.io/master=:NoSchedule
```

### 확인
```bash
kubectl describe node server1 | grep Taints
```

Taint가 걸리면 이후 배포되는 Deployment(`replicas: 2` 등)는 K8s 스케줄러가 자동으로 taint 없는 워커 노드들(server2, server3)에 분산 배치한다. 별도 anti-affinity 설정 없이도 replicas 수와 워커 노드 수가 맞아떨어지면 자연스럽게 노드별 1개씩 분산되는 구조.

## 4. 핵심 판단 2 — Kafka는 Swap이 있는 워커에 격리, 단 리스크 존재

### 배치 근거
컴포넌트 중 메모리를 가장 많이 쓰는 Kafka(~400Mi)를 Swap 여유가 있는 server3에 배치해 다른 노드의 메모리 압박을 분산.

### 발견한 리스크 — Swap 위에서 Kafka + JVM 성능 저하 가능성

검토 과정에서 아래 문제를 확인:

- **Kafka**는 디스크 I/O와 OS 페이지 캐시에 민감한 시스템이다. Swap이 발동하면 커널이 메모리를 디스크에 내렸다 올렸다 하면서 지연시간이 튀는데, 이는 컨슈머 랙 증가나 예측 불가능한 지연으로 직결된다.
- **Spring Boot(JVM) 기반 서비스**도 Swap과 상성이 나쁘다. GC가 힙을 스캔하는 도중 일부 메모리가 스왑 아웃되어 있으면 GC pause 시간이 비정상적으로 늘어난다.
- 초기안의 `192Mi~256Mi` 리소스 요청값은 Spring Boot 앱 기준으로 빡빡한 수치다. JVM 기본 힙 설정만으로도 이 수치를 넘기기 쉬워, `-Xmx`나 `-XX:MaxRAMPercentage`로 컨테이너 리밋에 맞춰 명시적으로 제한하지 않으면 OOMKilled가 발생할 가능성이 높다.

### 대응 방향
- 가능하면 물리 RAM 증설이 최선
- 증설이 어려운 경우, Kafka에 한해 `resources.requests`/`resources.limits`를 명확히 설정하고 JVM 힙 옵션을 컨테이너 리밋에 맞춰 명시적으로 튜닝
- Spring Boot 컨테이너에도 동일하게 `-XX:MaxRAMPercentage` 등으로 힙 크기를 컨테이너 메모리 한도 내로 강제

## 5. 미확정 이슈 — PostgreSQL + pgvector 배치 계획 누락

초기 배치안 검토 중 PostgreSQL+pgvector가 표에서 빠져 있는 것을 발견. Stateful한 컴포넌트라 다음 사항을 먼저 결정해야 함:

- server2 / server3 중 어느 노드에 배치할지
- PersistentVolume 요구사항 (K3s 기본 제공되는 `local-path-provisioner` 활용 여부)
- 메모리 리소스 할당량

→ 이 부분은 별도로 배치 계획을 확정한 뒤 진행하기로 함 (진행 중 이슈, 후속 문서에서 업데이트 예정).

## 6. 배운 점

- **Control plane과 애플리케이션 워크로드는 물리적으로 격리해야 한다.** 리소스가 넉넉한 클라우드 환경에서는 잘 드러나지 않는 문제지만, 저사양 온프레미스 환경에서는 이 원칙을 지키지 않으면 클러스터 전체 장애로 직결된다.
- **Swap은 만능 해결책이 아니다.** 메모리 부족을 swap으로 메우는 접근은 상태가 없는(stateless) 가벼운 워크로드에는 괜찮지만, Kafka나 JVM 기반 애플리케이션처럼 메모리 접근 패턴에 민감한 컴포넌트에는 성능 저하 리스크를 동반한다는 것을 설계 단계에서 미리 고려해야 한다.
- **리소스 요청값(requests/limits)은 애플리케이션 특성을 감안해 설정해야 한다.** 특히 JVM 기반 서비스는 컨테이너 메모리 리밋과 JVM 힙 옵션을 함께 맞춰야 OOMKilled를 방지할 수 있다.
- **배치 계획을 표로 정리하고 각 컴포넌트의 리소스 합계를 미리 계산하는 습관**이 실제 배포 전 병목/리스크를 사전에 발견하는 데 유효했다.

## 7. 실전 장애 사례 — 워커 노드 NotReady 반복 (파드 편중 + 메모리 오버커밋)

앞선 5~6번에서 우려했던 리스크가 실제로 발생한 사례. 이틀에 걸쳐 서로 다른 워커 노드가 무작위로 NotReady에 빠지는 장애가 재발했다.

### 증상

- Day 1: server2가 NotReady. Tailscale ping 무응답, SSH도 불가. server1/server3는 정상.
- Day 2: server3가 NotReady (taint 2개 부착). 마찬가지로 Tailscale ping/SSH 모두 무응답. server1/server2는 정상.
- 특정 노드 고정이 아니라 노드가 바뀌어 가며 같은 패턴이 반복 → 개별 VM 결함이 아니라 클러스터 구조적 원인으로 의심.

### 진단

정상 노드(server1)에서 `kubectl describe node server3` 로 확인한 핵심 정보:

```
Conditions:
  Ready  Unknown  ...  LastTransitionTime: ...  Reason: NodeStatusUnknown  Message: Kubelet stopped posting node status.

Capacity:
  memory: 975484Ki   # ≈ 952Mi, kubelet 기준으로는 swap 미반영

Non-terminated Pods:
  c4i  target-tracking-service-69c8f56996-n8kwv   Memory Requests 256Mi  Limits 512Mi  Age 15m
  c4i  target-tracking-service-9548fb554-vlswn    Memory Requests 256Mi  Limits 512Mi  Age 13m

Allocated resources:
  memory  Requests 582Mi (61%)   Limits 1Gi (107%)   # limit 합계가 노드 실제 메모리를 초과

Events:
  NodeNotReady  11m (x2 over 21h)  node-controller
```

핵심 단서 두 가지:

1. **동일 Deployment의 replica 2개가 전부 한 노드(server3)에 몰려 있었다.** 정상적인 분산이라면 server2/server3에 1개씩 나뉘어야 하는데, 두 파드 모두 server3에서 거의 동시(15m/13m 전)에 새로 떴다.
2. **메모리 Limit 합계가 노드 실제 메모리(952Mi)의 107%.** Requests 기준으로는 스케줄러가 통과시켰지만(61%), Spring Boot(JVM)가 부팅 중 순간적으로 힙을 늘리며 limit 근처까지 치솟으면 물리 메모리를 실제로 초과하게 된다.

### 근본 원인 — 연쇄 장애 시나리오

```
Day 1: server2 다운
  → server2 위에 있던 target-tracking-service 파드가 evict/재스케줄
  → 이 시점 유일하게 살아있는 워커는 server3 하나뿐 (워커가 2대뿐이라 대안이 없음)
  → replica 2개가 전부 server3로 몰림 (anti-affinity/topologySpreadConstraints 미설정)

Day 2: 두 번째 replica가 server3에서 재기동
  → 두 JVM 프로세스가 동시에 힙을 확장
  → 물리 메모리(952Mi) 초과 → 커널 OOM으로 시스템 전체가 응답 불능
  → SSH, Tailscale까지 죽는 이유: 이것은 네트워크 단절이 아니라
    "메모리 압박으로 VM 커널 자체가 멎어 네트워크 스택도 응답 못 하는" 현상
  → kubelet도 하트비트를 못 보내 NodeNotReady

+ server2가 복구된 뒤에도 이미 떠 있던 파드는 자동으로 재분산되지 않음
  (디스케줄러 부재) → 다음 장애의 씨앗이 계속 server3에 남아있는 구조
```

즉, "노드가 무작위로 바뀌며 반복된다"는 관찰과 정확히 일치한다 — 죽은 노드의 파드가 살아남은 노드로 쏠리고, 그 노드가 다음 희생양이 되는 순환 구조다. Tailscale relay 경유·rx=0 등 네트워크 계층 증상은 원인이 아니라 **VM이 멎으면서 나타난 결과**일 가능성이 높다.

### 즉시 조치

- `target-tracking-service` Deployment에 `topologySpreadConstraints` 추가 (`maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: DoNotSchedule`)로 동일 노드 co-location 자체를 차단
- JVM 힙을 컨테이너 limit에 맞춰 명시적으로 제한 (`-XX:MaxRAMPercentage=70.0` 등) — 4번에서 식별된 리스크가 그대로 현실화된 것이므로 최우선 적용
- 노드당 파드 memory limit 합계가 allocatable을 넘지 않도록 재산정 (현재 512Mi×2 = 1Gi > 952Mi는 구조적으로 위험)

### 재발 방지 / 모니터링

- 노드 복구 후에도 파드가 자동 재분산되지 않는 문제 해결을 위해 descheduler 도입 검토, 또는 server1에서 주기적으로 파드 분산 상태를 점검해 편중 시 `kubectl rollout restart`로 강제 재분산하는 간단한 스크립트 운용
- server1에서 워커 노드 메모리/swap 사용률을 주기적으로 polling해 임계치(예: 85%) 초과 시 webhook 알림
- 다음 장애 발생 시 `Boot ID` 비교(`describe node`의 `Boot ID` 필드)로 VM이 실제로 재부팅됐는지, 아니면 멎었다가 스스로 복구됐는지 구분 — OOM 커널 패닉으로 인한 재부팅인지 판단하는 데 사용
- swap이 실제로 커널에 활성화돼 있는지 노드 복구 시 `free -h`, `cat /proc/swaps`로 재확인 (kubelet이 기본적으로 swap 사용 시 기동을 거부하므로, 문서에 적힌 "Swap 2GB"가 실제로 유효한지 검증 필요)

## 다음 단계

- PostgreSQL + pgvector 노드 배치 및 리소스 할당 확정
- Kafka JVM 힙 옵션 튜닝 후 실제 부하 테스트로 swap 발동 여부 검증
- Master taint 적용 후 실제 파드 분산 결과 확인 (`kubectl get pods -o wide`로 NODE 컬럼 확인)
- `target-tracking-service`에 topologySpreadConstraints 적용 및 JVM 힙 옵션(`-XX:MaxRAMPercentage`) 실제 반영
- descheduler 또는 파드 재분산 자동화 스크립트 도입 검토
