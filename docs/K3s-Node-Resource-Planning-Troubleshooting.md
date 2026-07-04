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

## 다음 단계

- PostgreSQL + pgvector 노드 배치 및 리소스 할당 확정
- Kafka JVM 힙 옵션 튜닝 후 실제 부하 테스트로 swap 발동 여부 검증
- Master taint 적용 후 실제 파드 분산 결과 확인 (`kubectl get pods -o wide`로 NODE 컬럼 확인)
