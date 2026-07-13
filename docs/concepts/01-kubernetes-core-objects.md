# 개념 정리 — 쿠버네티스 핵심 오브젝트

`target-tracking-service`를 `c4i` 네임스페이스에 배포하며 새로 만든 `postgres.yaml`, `redis.yaml`, `kafka.yaml`, `deployment.yaml`을 예시로 각 오브젝트가 왜 필요한지 정리.

## 1. Namespace — 클러스터 안의 논리적 구역

```bash
kubectl create namespace c4i
```

같은 물리 클러스터 안에서 리소스를 그룹으로 나누는 단위. `c4i` 네임스페이스가 없으면 `target-tracking-secrets` 시크릿도, `postgres` Deployment도 만들 수 없다 — 실제로 이번에 `kubectl get ns`로 확인했을 때 `c4i`가 아예 없어서 여기서부터 시작해야 했다. 네임스페이스가 다르면 이름이 같아도 별개의 리소스로 취급된다(`defense-api-gateway`도 같은 `c4i` 안에 있어서 서로 이름 충돌 없이 통신 가능).

## 2. Deployment — "이 상태를 유지해줘"라는 선언

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 2
  selector:
    matchLabels: { app: target-tracking-service }
  template:
    metadata:
      labels: { app: target-tracking-service }
    spec:
      containers: [...]
```

Deployment는 "이 파드 스펙(`template`)으로 항상 `replicas`개가 떠 있게 유지해줘"라는 **선언적** 명령이다. 직접 파드를 만드는 게 아니라, 내부적으로 **ReplicaSet**을 만들고 그 ReplicaSet이 실제 파드 개수를 감시·조정한다. 파드가 죽으면(노드 장애, OOM 등) ReplicaSet이 자동으로 새 파드를 띄운다 — 이게 `docker run`으로 컨테이너 하나 띄우는 것과 근본적으로 다른 점이다.

`selector.matchLabels`와 `template.metadata.labels`가 반드시 같아야 한다 — Deployment가 "내가 관리해야 할 파드가 어떤 것들인지"를 라벨로 식별하기 때문이다.

`imagePullPolicy: Always`로 설정한 이유: `IfNotPresent`(기본값에 가까움)면 노드에 같은 태그(`v1`)의 이미지가 이미 있을 때 재사용해버려서, Docker Hub에 새 이미지를 `v1`로 다시 push해도 클러스터가 옛날 이미지를 계속 쓸 수 있다. 태그를 매번 새로 발급하는 게 정석이지만(예: `v2`, 커밋 SHA), 당장은 `Always`로 강제 재pull하도록 설정했다.

## 3. Service — 파드에 대한 "안정적인 이름표"

파드는 재시작될 때마다 IP가 바뀐다. 그래서 다른 컴포넌트가 파드 IP를 직접 알고 접속하면 안 된다. **Service**는 라벨 셀렉터로 파드 집합을 묶고, 그 앞에 **바뀌지 않는 가상 IP(ClusterIP)와 DNS 이름**을 붙여준다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
  namespace: c4i
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
```

이 Service가 생기면 클러스터 안 어디서든 `postgres-service.c4i.svc.cluster.local`(또는 같은 네임스페이스 안이면 그냥 `postgres-service`)로 접속할 수 있다. 실제 트래픽은 이 이름 → ClusterIP → (kube-proxy가) 라벨이 `app: postgres`인 파드들 중 하나로 전달된다.

이번 작업에서 중요했던 점: 기존 `target-tracking-config` ConfigMap이 이미 `kafka-service.c4i.svc.cluster.local`, `redis-service.c4i.svc.cluster.local`라는 이름을 **참조하고 있었기 때문에**, 새로 만드는 Kafka/Redis의 Service `metadata.name`을 정확히 `kafka-service`/`redis-service`로 맞춰야 했다. 이름 하나라도 다르면 DNS 조회 자체가 실패한다(`UnknownHostException`).

## 4. ConfigMap과 Secret — 둘 다 "설정값을 코드 밖으로"인데 왜 나뉘나

```yaml
# ConfigMap: 민감하지 않은 값
data:
  kafka-bootstrap-servers: "kafka-service.c4i.svc.cluster.local:9092"

# Secret: 민감한 값
kubectl create secret generic target-tracking-secrets \
  --from-literal=db-password=defense_password \
  --from-literal=gemini-api-key=<key>
```

기능적으로는 둘 다 "키-값을 담아서 파드에 env나 볼륨으로 주입"하는 같은 매커니즘이다. 차이는:
- **Secret은 기본적으로 base64 인코딩**되어 저장된다(암호화는 아니고 단순 인코딩 — RBAC으로 접근을 막는 게 실질적 보호).
- 도구(대시보드, `kubectl get`)들이 Secret 값은 기본적으로 마스킹해서 보여준다.
- 이번처럼 **레포가 public**이면, Secret이든 ConfigMap이든 "git에 커밋하느냐"가 진짜 경계선이다 — ConfigMap도 민감한 값이면 커밋하면 안 되고, Secret이라고 자동으로 암호화되는 것도 아니다. 그래서 DB 비밀번호/`GEMINI_API_KEY`는 아예 YAML로 만들지 않고 `kubectl create secret`으로 클러스터에 직접 주입하고 git에는 남기지 않았다.

파드 안에서 이 값들을 쓰는 방법:
```yaml
env:
  - name: GEMINI_API_KEY
    valueFrom:
      secretKeyRef: { name: target-tracking-secrets, key: gemini-api-key }
```
`valueFrom`은 값을 YAML에 직접 안 적고 "이 Secret의 이 키를 참조해라"라고만 적는 방식 — 매니페스트 자체에는 실제 값이 전혀 안 남는다.

## 5. PersistentVolumeClaim(PVC) — "디스크 공간 좀 줘"라는 요청

컨테이너는 기본적으로 **일시적(ephemeral)**이다. 파드가 재시작되면 컨테이너 안에 쓴 파일은 다 날아간다. Postgres처럼 데이터가 남아있어야 하는 컴포넌트는 **파드 생명주기와 분리된 저장소**가 필요하다.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: postgres-pvc }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 2Gi } }
```

PVC는 "이런 스펙의 저장 공간이 필요해"라는 **요청서**다. 실제 저장 공간(PersistentVolume, PV)을 누가 어떻게 만들어줄지는 **StorageClass**가 결정한다. 우리 클러스터는 `local-path`(Rancher의 `local-path-provisioner`)를 쓰는데, 이건 노드의 로컬 디스크 경로를 그대로 볼륨으로 쓰는 가장 단순한 방식이다 — 네트워크 스토리지가 아니라서, **한 번 특정 노드에 프로비저닝되면 그 파드는 항상 그 노드에서만 뜰 수 있다**는 제약이 생긴다(replicas를 여러 개로 못 늘리는 이유이기도 함, 그래서 `postgres`는 `replicas: 1`).

`volumeBindingMode: WaitForFirstConsumer`(우리 StorageClass의 기본값)라는 옵션 때문에, PVC는 **그 볼륨을 실제로 쓰는 파드가 스케줄될 때까지 바인딩을 미룬다.** 파드가 어느 노드에 배치될지 먼저 정해져야 "그 노드의 로컬 디스크에" 볼륨을 만들 수 있기 때문이다. 그래서 `kubectl get pvc`에 `Pending`이 떠 있는 것 자체는 정상이고(파드가 스케줄되기 전까지는), 파드가 스케줄된 후에도 계속 `Pending`이면 — 이번에 실제로 겪었듯 — 프로비저너 자체에 문제가 있다는 신호다(`03-cluster-network-debugging.md` 참고).

`subPath: pgdata`를 마운트에 쓴 이유: 볼륨 루트를 그대로 마운트하면 `lost+found` 같은 파일시스템 예약 디렉토리가 같이 보여서 Postgres가 "데이터 디렉토리가 비어있지 않다"고 오해하는 흔한 문제가 있다. 볼륨 안에 `pgdata`라는 서브디렉토리를 하나 더 파서 그 안만 마운트하면 이 문제를 피할 수 있다.

## 6. 이번에 만든 리소스들의 관계 한눈에

```
Namespace: c4i
 ├─ Secret target-tracking-secrets (db-url, db-username, db-password, gemini-api-key)
 ├─ ConfigMap target-tracking-config (kafka-bootstrap-servers, redis-host)
 ├─ PVC postgres-pvc ── Deployment postgres ── Service postgres-service:5432
 ├─ Deployment redis ── Service redis-service:6379
 ├─ Deployment zookeeper ── Service zookeeper-service:2181
 ├─ Deployment kafka (zookeeper-service 참조) ── Service kafka-service:9092
 └─ Deployment target-tracking-service (Secret + ConfigMap 참조) ── Service target-tracking-service:8080
```

Deployment는 "무엇을 띄울지", Service는 "그걸 어떻게 안정적으로 찾을지", ConfigMap/Secret은 "설정값을 어디서 가져올지", PVC는 "데이터를 어디에 남길지" — 각자 역할이 분리되어 있어서, 예를 들어 이미지 태그만 바꾸고 싶으면 Deployment만 건드리면 되고 DB 접속 정보를 바꾸고 싶으면 Secret만 건드리면 된다.
