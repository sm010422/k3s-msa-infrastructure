# target-tracking-service Dockerize & Gemini 전환 & K3s/ArgoCD 배포 기록

`target-tracking-service`에 Dockerfile이 없던 상태에서 시작해, 로컬 `docker compose` 전체 스택 검증 → AI 프로바이더를 OpenAI에서 Gemini로 전환 → 기존 GitOps(K3s + ArgoCD) 파이프라인에 실제로 태우기까지 진행한 기록. 계획대로 안 풀린 지점과 그 원인 판단 근거를 중심으로 남긴다.

## 1. 시작 상태

- `target-tracking-service`: Dockerfile 없음, `docker-compose.yml`은 postgres/redis/kafka/zookeeper만 있고 앱 서비스 자체가 빠져 있었음
- `k3s-msa-infrastructure`: `apps/target-tracking-service/`에 Deployment/Service YAML은 있었지만 이미지가 `c4i/target-tracking-service:latest` placeholder, `argocd/applications/target-tracking-service.yaml`도 레포에만 있고 **클러스터에는 한 번도 apply된 적 없는 상태**
- AI 기능(`ThreatAnalysisService`)은 OpenAI(`spring-ai-openai-spring-boot-starter`, GPT-4o-mini)로 구현돼 있었으나, 뒤에 나오듯 애초에 컴파일이 안 되고 있었음

## 2. Dockerfile & docker-compose 구성

### 2.1 멀티스테이지 Dockerfile
`eclipse-temurin:21-jdk-alpine`(빌드) → `eclipse-temurin:21-jre-alpine`(런타임) 2단계로 구성. non-root 유저(`spring`)로 실행, `app.jar` 하나만 최종 이미지에 남기는 방식으로 이미지 크기를 줄임.

### 2.2 docker-compose에 앱 서비스 추가 + Kafka 리스너 이중화
기존 `KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092` 하나로는, 컨테이너로 뜨는 앱이 `kafka:9092`로 초기 접속한 뒤 브로커가 되돌려주는 주소가 `localhost`라서 재연결이 끊기는 문제가 있었다. Confluent 공식 예제 패턴대로 리스너를 둘로 나눠서 해결:

```yaml
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,PLAINTEXT_HOST://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:29092,PLAINTEXT_HOST://localhost:9092
```
컨테이너 간 통신은 `kafka:29092`, 호스트에서 붙을 때는 `localhost:9092`.

## 3. 빌드 중 발견한 기존 버그 — `build.gradle`이 이미 깨져 있었음

Dockerfile로 빌드를 시도하기 전, 로컬 `./gradlew build`부터 실패하는 걸 확인했다. **Docker와 무관하게 6/30 커밋(`aa3a52f feat(build): add Spring AI 1.0.0 and pgvector dependencies`)부터 컴파일 자체가 안 되고 있던 상태.**

원인: `spring-ai-openai-spring-boot-starter`, `spring-ai-pgvector-store-spring-boot-starter`는 Spring AI 1.0.0 마일스톤(M6 이전) 시절 아티팩트 이름이고, 1.0.0 GA부터는 `spring-ai-starter-model-openai`, `spring-ai-starter-vector-store-pgvector`로 개명됐다. 로컬 Gradle 캐시의 `spring-ai-bom-1.0.0.pom`을 직접 열어서 실제 아티팩트 목록을 확인해 검증.

## 4. AI 프로바이더 전환: OpenAI → Gemini

### 4.1 전환 이유
Gemini Developer API(Google AI Studio)는 신용카드 없이 무료 티어를 제공(`gemini-2.5-flash` 계열: 1,500 req/day, 1M TPM). OpenAI는 사실상 전액 유료. 포트폴리오 성격상 무료 티어가 있는 쪽이 합리적이라 판단해 전환.

### 4.2 버전/아티팩트 확인 과정
Spring AI 1.0.0 GA에는 Gemini Developer API용 스타터가 없고(`spring-ai-vertex-ai-gemini`만 존재 — GCP 프로젝트/서비스어카운트가 필요한 Vertex AI 경로), API 키 기반 무료 티어를 쓰려면 `spring-ai-starter-model-google-genai`가 필요한데 이건 **1.1.0부터 추가**됐다는 걸 Maven Central의 `spring-ai-bom` 각 버전 POM을 직접 curl로 훑어서 확인. 최신 GA는 2.0.0이지만 기존 코드와의 호환 리스크를 줄이기 위해 같은 1.x 라인의 최신 GA인 **1.1.8**로 올림.

### 4.3 실제 설정 (프로퍼티 이름은 jar의 `spring-configuration-metadata.json`을 직접 까서 검증)
```yaml
spring:
  ai:
    google:
      genai:
        api-key: ${GEMINI_API_KEY:PLACEHOLDER}
        chat:
          options:
            model: gemini-2.5-flash
        embedding:
          api-key: ${GEMINI_API_KEY:PLACEHOLDER}
          text:
            options:
              model: gemini-embedding-001
              dimensions: 1536
```
- `project-id`/`location`을 설정하면 클라이언트가 Vertex AI 모드로 전환되며 API 키가 거부되므로 **절대 넣지 않음** — 무료 Developer API 경로를 유지하는 핵심 조건.
- 임베딩 모델은 처음엔 `text-embedding-004`를 쓰려 했으나, 이 모델이 2026-01-14부로 deprecate되고 `gemini-embedding-001`로 대체된 걸 확인해서 바로 최신 모델로 선택. 기본 출력 차원은 3072이지만 Matryoshka 표현학습(MRL) 덕에 `dimensions: 1536`으로 줄여서 기존 pgvector 스키마(1536차원)를 그대로 재사용.

### 4.4 코드 변경
`ThreatAnalysisService`, `ThreatKnowledgeInitializer`, `ThreatAnalysisController`의 `@Value("${spring.ai.openai.api-key:...}")` 및 안내 메시지를 전부 `spring.ai.google.genai.api-key` / `GEMINI_API_KEY`로 교체. `ChatModel`/`VectorStore` 인터페이스만 의존하고 있어서 OpenAI 전용 타입을 직접 참조하는 코드는 없었음 — 설정값 치환만으로 전환 완료.

## 5. 로컬 docker compose 전체 스택 검증

`docker compose up -d --build`로 postgres(pgvector)/redis/kafka/zookeeper/app 5개 컨테이너를 한 번에 띄워서 확인:
- Kafka producer/consumer가 정상적으로 메시지를 주고받고, `TargetService`가 DB에 저장, WebSocket으로 브로드캐스트되는 것까지 로그로 확인
- `GET /actuator/health` → `UP`
- `GET /api/v1/threat-analysis/status` → `{"aiEnabled": false, ...}` (GEMINI_API_KEY가 PLACEHOLDER인 상태에서 정상적인 graceful degradation 동작)

## 6. 멱등성 버그 발견 및 수정

`ThreatKnowledgeInitializer.run()`이 애플리케이션 시작마다 무조건 `vectorStore.add(documents)`를 실행하는 구조였다. `deployment.yaml`이 `replicas: 2`인 것을 고려하면 배포 즉시 지식 베이스가 2배로 중복 삽입되고, 이후 재배포/재시작마다 계속 누적되는 문제. `JdbcTemplate`으로 `vector_store` 테이블에 `metadata->>'source' = 'c4i-threat-kb'`인 row가 이미 있는지 카운트 체크해서 있으면 skip하도록 가드 추가 (`ThreatKnowledgeInitializer.isAlreadySeeded()`). 두 pod가 동시에 처음 뜨는 순간의 레이스 컨디션까지는 막지 못하지만(advisory lock 등은 오버엔지니어링으로 판단해 보류), 반복 재시작 시 무한 누적되는 문제는 해결.

## 7. K3s + ArgoCD 배포 — 계획과 실제 갭

사용자가 정리해둔 "이미지 빌드 → push → 매니페스트 반영 → git push → ArgoCD 자동 배포" 4단계 계획을 실행하기 전에, 클러스터를 직접 조사해서 다음 갭들을 먼저 확인했다:

| 가정 | 실제 |
|---|---|
| ArgoCD가 이미 GitOps로 연결되어 있다 | `argocd/applications/target-tracking-service.yaml` 파일은 레포에 있었지만 `kubectl get application -n argocd` 결과 없음 → **클러스터에 한 번도 등록된 적 없음** |
| `c4i` 네임스페이스는 있을 것이다 | 없음 (한 번도 배포된 적 없는 서비스였음) |
| DB 시크릿/Kafka·Redis 서비스가 있을 것이다 | `target-tracking-secrets`, `kafka-service`, `redis-service` 전부 미존재 |
| GEMINI_API_KEY가 매니페스트에 반영돼 있을 것이다 | 아예 없음 (OpenAI 시절 매니페스트라 관련 env 자체가 없었음) |

architecture.md에는 원래 Postgres/Kafka/Redis를 server1~3 노드에 직접(Tailscale IP) 띄우는 구조로 적혀 있었는데, 사용자와 확인한 결과 **`c4i` 네임스페이스 안에 새로 배포하는 쪽으로 방향을 바꿔** 진행하기로 결정.

### 7.1 리소스 사이징 근거
`kubectl describe nodes`로 확인한 가용 메모리가 server1 ~1.9GB, server2/server3 ~950MB로 매우 협소(`K3s-Node-Resource-Planning-Troubleshooting.md`에 기록된 저사양 환경과 동일 계열). 신규로 추가하는 postgres/redis/kafka+zookeeper는 보수적으로 사이징:

| 컴포넌트 | requests | limits | 비고 |
|---|---|---|---|
| postgres | 128Mi/100m | 512Mi/500m | PVC 2Gi (`local-path`), `subPath: pgdata`로 lost+found 이슈 회피 |
| redis | 32Mi/50m | 128Mi/150m | ephemeral (docker-compose와 동일하게 무상태 취급) |
| zookeeper | 128Mi/100m | 256Mi/300m | ephemeral |
| kafka | 256Mi/200m | 512Mi/500m | `KAFKA_HEAP_OPTS=-Xmx256M -Xms256M`로 힙 명시 제한 (기본 힙이 컨테이너 리밋을 넘기지 않도록) |

`redis-service`/`kafka-service` 이름은 기존에 이미 있던 `target-tracking-config` ConfigMap이 참조하고 있던 값(`kafka-service.c4i.svc.cluster.local:9092`, `redis-service.c4i.svc.cluster.local`)에 정확히 맞춰서 지음 — ConfigMap 자체는 손대지 않음.

### 7.2 시크릿 관리 — git에는 절대 안 올림
`k3s-msa-infrastructure`가 **GitHub public 레포**라는 걸 `gh repo view`로 먼저 확인했다. DB 비밀번호, `GEMINI_API_KEY` 같은 값은 YAML로 커밋하지 않고 `kubectl create/patch secret`으로 클러스터에 직접 주입:

```bash
kubectl create namespace c4i
kubectl create secret generic target-tracking-secrets -n c4i \
  --from-literal=db-url=jdbc:postgresql://postgres-service.c4i.svc.cluster.local:5432/defense_db \
  --from-literal=db-username=defense \
  --from-literal=db-password=defense_password
# gemini-api-key는 사용자가 터미널에서 직접 patch (에이전트 트랜스크립트에 값이 남지 않도록)
kubectl patch secret target-tracking-secrets -n c4i -p '{"stringData":{"gemini-api-key":"<실제 값>"}}'
```

### 7.3 신규/변경 매니페스트
`apps/target-tracking-service/`에 `postgres.yaml`, `redis.yaml`, `kafka.yaml` 신규 추가. 기존 `deployment.yaml`은 이미지와 env만 변경:
```diff
- image: c4i/target-tracking-service:latest
- imagePullPolicy: IfNotPresent
+ image: sm010422/target-tracking-service:v1
+ imagePullPolicy: Always
...
+ - name: GEMINI_API_KEY
+   valueFrom:
+     secretKeyRef:
+       name: target-tracking-secrets
+       key: gemini-api-key
```
전부 `kubectl apply --dry-run=server`로 검증 후 커밋.

> **주의**: 이 리소스들이 기존 ArgoCD Application 하나(`path: apps/target-tracking-service`, `prune: true`)로 관리된다. 나중에 이 yaml들 중 하나를 지우면 ArgoCD가 대응 리소스(PVC 포함)를 자동 삭제하므로, `postgres.yaml`을 실수로 지우면 데이터도 함께 날아간다.

## 8. 배포 실행 및 발견한 클러스터 네트워킹 이슈

이미지 빌드(`docker build`, 로컬 맥북/클러스터 노드 모두 arm64라 buildx 불필요) → push → 시크릿 생성 → 매니페스트 커밋/push까지는 문제없이 끝났다. 이후 두 가지 문제가 연속으로 발생:

### 8.1 ArgoCD Application 등록 후 Sync Status가 계속 `Unknown`
`kubectl apply -f argocd/applications/target-tracking-service.yaml`로 처음 등록. `kubectl describe application`으로 보니:
```
Failed to load target state: ... dial tcp 10.43.21.196:8081: i/o timeout
```
`argocd-application-controller` 로그를 더 보면 실제로는 매니페스트 생성(git fetch)은 22초 정도 걸려 성공했고, 그 다음 **`argocd-redis`(10.43.241.26:6379) 캐시 저장 단계에서 타임아웃**이 나는 게 진짜 원인이었다. 이 타임아웃은 내가 Application을 만들기 전인 07:18경부터 이미 반복되고 있었던 것으로 로그에서 확인 — 즉 이 작업과 무관한 기존 증상.

시도한 조치: `argocd-redis` pod를 재시작(`kubectl delete pod`, Deployment가 즉시 재생성 — 캐시 전용이라 데이터 유실 없음). 새 pod가 다른 노드(server2 → server1)에서 뜬 뒤에도 **동일한 타임아웃이 재현**돼서, pod 자체 문제가 아니라 ClusterIP 라우팅 레벨의 문제라고 판단.

### 8.2 postgres pod가 Pending에서 멈춤 — 근본 원인은 클러스터 전체 ClusterIP/DNS 장애
ArgoCD sync를 우회해서 `kubectl apply -f`로 직접 리소스를 배포. redis/kafka/zookeeper는 정상 기동했지만 postgres pod가 계속 `Pending`. `local-path-provisioner` 로그를 보니:
```
Failed to watch ... dial tcp 10.43.0.1:443: no route to host
```
`10.43.0.1`은 **쿠버네티스 API 서버 자체의 ClusterIP**다. PVC 프로바이저가 API 서버 ClusterIP조차 못 붙고 있었다는 뜻. 여기에 더해 앱 pod 로그에서도:
```
Caused by: java.net.UnknownHostException: postgres-service.c4i.svc.cluster.local
```
DNS 조회 자체가 실패. 세 군데(ArgoCD-redis, local-path-provisioner→API 서버, 앱→CoreDNS)에서 독립적으로 같은 패턴(ClusterIP 대상 연결/조회 실패)이 나온 걸 근거로, **`target-tracking-service`와 무관한 클러스터 전체의 kube-proxy/CoreDNS/CNI 레벨 장애**라고 결론지었다. `k3s-cni-crashloop-troubleshooting.md`에 기록된 것과 같은 계열의 문제로 추정.

### 8.3 이 시점에서 작업 범위를 결정
공유 클러스터의 코어 네트워킹(kube-proxy/CNI)을 더 깊이 진단/수정하는 건 이번 배포 작업과는 다른 성격의 작업이라 판단해, 사용자와 상의 후 여기서 멈췄다. `target-tracking-service` 자체의 배포 준비(이미지, 시크릿, 매니페스트, ArgoCD 등록)는 전부 정상 완료된 상태이므로, 네트워킹이 복구되면 **추가 조치 없이 postgres pod가 자동으로 Running이 되고 앱도 정상 기동**할 것으로 예상.

## 9. 배운 점

- **"컴파일이 되는 것"과 "예전에 컴파일이 됐을 것"은 다르다.** Dockerfile을 쓰기 전에 로컬 빌드부터 실행해서, Docker와 무관하게 이미 깨져 있던 `build.gradle` 버그를 먼저 잡을 수 있었다. Dockerfile만 작성하고 바로 push했다면 이 버그를 이미지 빌드 실패로만 마주쳤을 것.
- **라이브러리 아티팩트/프로퍼티 이름은 릴리스 노트를 믿지 말고 실제 BOM/jar를 까본다.** Spring AI는 마일스톤 사이에 아티팩트명이 여러 번 바뀌어서(`-spring-boot-starter` → `-starter-model-*`), Maven Central의 실제 POM과 jar 안 `spring-configuration-metadata.json`을 직접 확인하는 게 문서보다 빨랐다.
- **"GitOps가 연결돼 있다"는 가정을 그대로 믿지 않고 클러스터 상태를 먼저 확인한 게 시간을 아꼈다.** `kubectl get application -n argocd`, `kubectl get ns` 몇 줄로 4단계 계획의 전제 자체가 틀렸다는 걸 미리 알 수 있었다.
- **증상이 여러 컴포넌트에 걸쳐 같은 패턴으로 나타나면 각 컴포넌트를 개별로 고치려 하지 말고 공통 원인을 의심한다.** ArgoCD-redis, PVC 프로비저너, 앱의 DNS 조회 — 셋 다 "ClusterIP/서비스 이름 대상 연결 실패"라는 동일한 신호였다.
- **공유 인프라(다른 세션이 만들지 않은 리소스)에 대한 조치는 반드시 먼저 확인받는다.** `argocd-redis` pod 재시작처럼 되돌릴 수 있는 조치라도, 범위를 벗어나는 액션은 사용자 승인 후 진행.

## 10. 다음 단계

- 클러스터 kube-proxy/CoreDNS/CNI(flannel 추정) 상태 진단 — 별도 세션에서 진행 예정
- 네트워킹 복구 후 확인 절차:
  ```bash
  kubectl get pods -n c4i -w
  kubectl get application target-tracking-service -n argocd -o wide   # Synced/Healthy 확인
  kubectl port-forward -n c4i svc/target-tracking-service 8080:8080
  curl localhost:8080/actuator/health
  curl localhost:8080/api/v1/threat-analysis/status                   # aiEnabled:true 확인
  ```
- 정상 기동 확인되면 `docs/architecture.md`(target-tracking-service 레포)의 인프라 배치 설명을 "server 노드 직접 배치" → "c4i 네임스페이스 in-cluster 배포"로 갱신 필요
