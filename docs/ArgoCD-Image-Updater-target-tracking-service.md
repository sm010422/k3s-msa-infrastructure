# target-tracking-service 이미지 자동 배포 — ArgoCD Image Updater 도입

`target-tracking-service`는 `deployment.yaml`에 `image: sm010422/target-tracking-service:v1`로 태그가 고정돼 있어서, 코드를 고쳐 Docker Hub에 새 이미지를 올려도 인프라 리포의 태그 문자열이 그대로면 ArgoCD가 diff를 못 찾아 자동 반영이 안 됐다. 태그를 바꿀 때마다 `deployment.yaml`을 손으로 고쳐 커밋하는 걸 없애기 위해 ArgoCD Image Updater를 붙인 기록.

## 1. 배경 — 왜 필요했나

- `apps/target-tracking-service/deployment.yaml`의 `imagePullPolicy: Always`는 pod가 재시작될 때 최신 이미지를 다시 받아오게 할 뿐, ArgoCD가 알아서 재배포를 트리거해주지는 않음
- `argocd/applications/target-tracking-service.yaml`에 `syncPolicy.automated`(`selfHeal: true`)가 켜져 있어 **이 인프라 리포의 git 상태**는 자동 반영되지만, Docker Hub에 새 이미지를 올리는 것과 이 리포의 git 상태는 별개
- 결론: 이미지 태그를 이 리포에 커밋하는 과정 자체를 자동화해야 진짜 CD가 완성됨

## 2. 전체 파이프라인

```
target-tracking-service 리포 push (main)
  → GitHub Actions (.github/workflows/deploy.yml)
      → Docker 이미지 빌드
      → Docker Hub push: sm010422/target-tracking-service:<git-sha>, :latest
  → ArgoCD Image Updater (2분 간격 폴링)
      → :latest 태그의 digest 변경 감지
      → k3s-msa-infrastructure 리포에 SSH로 커밋+push (kustomize edit set image)
  → ArgoCD (selfHeal: true)
      → git 변경 감지, 자동 sync
  → k3s 클러스터에 새 이미지로 롤아웃
```

## 3. CI 파이프라인 (target-tracking-service 리포)

`.github/workflows/deploy.yml` 신규 작성. 기존 다른 프로젝트(travel-core-service)의 워크플로우를 참고했으나 다음을 이 리포 구조에 맞게 바꿈:

- `branches: [ "main" ]` — 참고 예시는 `develop`, 이 리포는 `main`만 씀
- `context: .` / `file: Dockerfile` — 이 리포는 `services/xxx` 하위구조가 아니라 루트에 Dockerfile
- PR 코멘트 스텝은 제거함 — 참고 예시가 트리거는 `push`인데 조건은 `pull_request` 이벤트라 실제로는 한 번도 실행되지 않는 죽은 코드였음
- 태그를 `${{ github.sha }}` + `latest` 둘 다 push하도록 함 (`latest`는 Image Updater가 추적, sha 태그는 특정 빌드를 명시적으로 pin하고 싶을 때 사용)

시크릿: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (Docker Hub Access Token, `Read & Write` 권한)을 `gh secret set`으로 등록. 이전 프로젝트(Sofly_Back)에는 이미 있었지만, 리포가 다르면 시크릿도 새로 등록해야 한다 — GitHub 시크릿은 리포 단위로 격리되고 공유되지 않음.

**흔한 실수**: `docker/build-push-action@v5`의 Dockerfile 경로 입력 파라미터는 `dockerfile`이 아니라 `file`이다. `dockerfile: Dockerfile`로 잘못 써도 액션이 그냥 무시하고 컨텍스트 기본 위치의 Dockerfile을 쓰기 때문에 (컨텍스트 루트에 Dockerfile이 있는 경우) 에러 없이 넘어가서 눈치채기 어렵다 — 워크플로우 실행 후 Annotations에 `Unexpected input(s) 'dockerfile'` 경고로 확인.

## 4. ArgoCD Image Updater 설치

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml
```

v1.x부터 설정 방식이 Application 어노테이션 기반에서 **`ImageUpdater` CRD** 기반으로 바뀌었다 (구버전 문서/블로그 글에 흔한 `argocd-image-updater.argoproj.io/image-list` 어노테이션 방식은 legacy).

### 4.1 Git write-back용 Deploy Key

Image Updater가 이 인프라 리포에 커밋을 push해야 하므로, 계정 전체 권한 토큰 대신 **이 리포 전용 SSH Deploy Key(쓰기 권한)**를 새로 발급했다:

```bash
ssh-keygen -t ed25519 -f ./image-updater-deploy-key -N "" -C "argocd-image-updater@target-tracking"
gh repo deploy-key add ./image-updater-deploy-key.pub -R sm010422/k3s-msa-infrastructure \
  --title "argocd-image-updater" --allow-write

kubectl create secret generic git-creds -n argocd \
  --from-file=sshPrivateKey=./image-updater-deploy-key
# 이후 로컬 키 파일은 삭제
```

Deploy Key는 계정 전체가 아니라 등록한 리포 하나에만 유효해서, 컨트롤러가 뚫려도 피해 범위가 이 리포로 한정된다는 게 개인 액세스 토큰(PAT) 대비 장점.

### 4.2 kustomization.yaml 추가 (필수 트러블슈팅 포인트)

처음엔 이 파일 없이 진행했는데, 컨트롤러 로그에 아래 경고가 남으며 아무 것도 처리되지 않았다:

```
skipping app 'argocd/target-tracking-service' of type 'Directory' because it's not of supported source type
```

Image Updater의 git write-back은 내부적으로 `kustomize edit set image`를 실행하는 방식이라, ArgoCD Application의 source type이 (raw YAML을 나열한) `Directory`가 아니라 `Kustomize`여야 한다. `apps/target-tracking-service/`에 아래 파일을 추가하고 git에 push하니 ArgoCD가 자동으로 `Kustomize` 타입으로 재인식했다 (`kubectl patch application ... -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`로 강제 refresh 확인):

```yaml
# apps/target-tracking-service/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - kafka.yaml
  - postgres.yaml
  - redis.yaml
  - service.yaml
```

적용되는 매니페스트 내용 자체는 이전과 동일 — ArgoCD가 인식하는 소스 타입만 바뀐다.

### 4.3 ImageUpdater CR

```yaml
# argocd/image-updater.yaml
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
  name: target-tracking-service-updater
  namespace: argocd
spec:
  writeBackConfig:
    method: "git:secret:argocd/git-creds"
    gitConfig:
      repository: "git@github.com:sm010422/k3s-msa-infrastructure.git"
      branch: "main"
  applicationRefs:
    - namePattern: "target-tracking-service"
      images:
        - alias: "target-tracking-service"
          imageName: "sm010422/target-tracking-service:latest"
          commonUpdateSettings:
            updateStrategy: "digest"
```

`updateStrategy: digest`는 태그(`latest`)는 그대로 두고, 그 태그가 가리키는 실제 이미지 내용(SHA256)이 바뀌었는지를 감지한다. 새 빌드가 감지되면 매니페스트의 이미지 참조를 `sm010422/target-tracking-service@sha256:...` 형태로 고쳐 쓴다.

### 4.4 두 번째 트러블슈팅 — "live하지 않다"며 스킵됨

CR을 만들고도 `APPS 0 IMAGES 0`로 계속 아무 것도 안 잡혔다. `--loglevel=debug`로 컨트롤러 로그를 올려서 확인:

```
Image 'sm010422/target-tracking-service' seems not to be live in this application, skipping
```

Image Updater는 git의 "원하는 상태"가 아니라 **클러스터에 실제로 떠있는 pod의 이미지**를 기준으로 추적 대상을 판단한다. 이 시점엔 정리 작업 도중 `target-tracking-service`의 replicas를 0으로 내려둔 상태라 비교할 살아있는 이미지가 없었던 것 — 설정 자체의 결함은 아니고, **서비스가 실제로 떠 있어야 Image Updater가 그 이미지를 인식하고 추적을 시작**한다.

## 5. 검증 방법

```bash
# CR 상태 (APPS/IMAGES가 0이면 아직 추적 안 되는 중)
kubectl get imageupdater -n argocd

# 상세 상태
kubectl get imageupdater target-tracking-service-updater -n argocd -o jsonpath='{.status}' | jq .

# 컨트롤러 로그
kubectl logs -n argocd deploy/argocd-image-updater-controller -f
```

## 6. 이 방식의 트레이드오프 — 실무에서도 이렇게 하나?

이 셋업이 "유일한 정석"은 아니다. 실무에서 갈리는 지점을 정리:

| 방식 | 채택도 | 비고 |
|---|---|---|
| **CI가 인프라 리포에 직접 커밋** (`sed`/`yq`로 태그 갱신 후 push) | 가장 흔함 | 어떤 커밋이 왜 배포됐는지 git 히스토리에 그대로 남아 감사(audit)하기 쉬움. 별도 컨트롤러 불필요 |
| **ArgoCD Image Updater** (이 문서) | ArgoCD 생태계 공식이지만 코어 ArgoCD보다 유지보수 활발도가 낮고, 설정 스키마가 버전마다 바뀜 (v1.x에서 어노테이션 → CRD로 전환된 것도 그 예) | 컨트롤러가 하나 더 늘고, 디버깅이 까다로움 (이번에도 원인 파악에 로그 레벨을 debug로 올려야 했음) |
| **Flux CD Image Automation** | Flux를 쓰는 조직의 사실상 표준 | ArgoCD 대신 Flux 기반이면 이쪽이 네이티브 |

가장 논쟁적인 지점은 **`latest` 태그를 digest로 추적하는 것 자체**다. 태그가 불변(immutable)하지 않아서 "이 배포가 정확히 어떤 커밋의 코드인지"를 태그만 보고는 알 수 없다. 프로덕션급 환경에서는 보통:

- 이미지 태그를 git-sha나 semver로 고정(불변)하고
- 새 태그로의 승격(promotion)을 PR 리뷰를 거치게 하거나 (Image Updater도 `pullRequest` write-back 모드를 지원)
- 최소한 롤백 시 "이전 커밋으로 git revert = 이전 이미지로 롤백"이 명확히 성립하게

만드는 걸 선호한다. 지금 구성(`latest` + digest 추적)은 개인 프로젝트 규모에서 자동 배포 파이프라인을 직접 구현해보는 데는 충분히 합리적이지만, 그대로 프로덕션에 옮긴다면 이 지점부터 다시 고민할 부분이다.

## 7. 남은 작업

- `target-tracking-service`를 다시 배포(`kubectl scale deployment/target-tracking-service -n c4i --replicas=2` 또는 replicas 값 원복)해서 Image Updater가 살아있는 이미지를 인식하는지 확인
- 첫 자동 커밋이 실제로 이 리포에 push되는지, ArgoCD가 그걸 받아 재배포하는지 end-to-end 검증

## 8. 컨트롤러 resources 조정 (2026-07-22)

`k9s`로 전체 파드의 메모리 사용률(`%MEM/R`, `%MEM/L`)을 점검하던 중 `argocd-image-updater-controller`가 눈에 띄었다:

| | request | limit | 실제 사용량 |
|---|---|---|---|
| 변경 전 (install.yaml 기본값) | cpu 250m / mem 512Mi | cpu 500m / mem 1Gi | cpu ~3m / mem ~33Mi |

`%MEM/R`이 6%대로 나온다는 건 반대로 **너무 과하게 예약**해뒀다는 뜻 — 위험 신호가 아니라 홈랩처럼 노드 자원이 넉넉하지 않은 환경에서 다른 워크로드가 쓸 수 있는 스케줄링 여유(request 기준 allocatable)를 512Mi나 묶어두고 낭비하는 상태였다.

### 8.1 이 Deployment는 이 리포의 GitOps 대상이 아님

`argocd-image-updater-controller`는 4장에 나온 대로 `kubectl apply -f .../install.yaml`로 클러스터에 직접 설치한 것이라, 이 리포엔 `ImageUpdater` CR(`argocd/image-updater.yaml`)만 있고 Deployment 자체를 정의한 매니페스트는 없다. 6번 섹션 표에 나온 Application(`target-tracking-service`)도 `apps/target-tracking-service` 경로만 보고 있어서 `argocd/` 아래 변경은 자동 sync 대상이 아니다.

그래서 실제 리소스 값을 바꾸는 절차는 두 단계로 나뉜다 — ① 변경 이력을 리포에 문서화/보관하기 위한 patch 매니페스트 커밋, ② 그 patch를 클러스터에 수동으로 적용.

### 8.2 patch 매니페스트

```yaml
# argocd/image-updater-resources-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-image-updater-controller
  namespace: argocd
spec:
  template:
    spec:
      containers:
        - name: argocd-image-updater-controller
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
```

이 리포의 다른 매니페스트들처럼 ArgoCD가 자동으로 diff를 감지해 적용해주는 게 아니라서, strategic merge patch로 수동 적용해야 한다:

```bash
kubectl patch deployment argocd-image-updater-controller -n argocd \
  --type strategic --patch-file argocd/image-updater-resources-patch.yaml
```

### 8.3 검증

```bash
kubectl get deployment argocd-image-updater-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
# {"limits":{"cpu":"250m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}

kubectl top pods -n argocd -l control-plane=argocd-image-updater-controller
```

적용 직후 새 파드가 뜨면서 실사용량은 그대로(수십 Mi 수준)인데 request/limit만 실제 사용 패턴에 맞게 줄어, `%MEM/R`이 6%대에서 60%대로(과다 예약 → 적정 예약) 정상화된 것을 k9s에서 확인.

**참고**: install.yaml을 다시 apply(업그레이드 등)하면 이 patch는 덮어써진다 — 업그레이드 후에는 8.2의 patch를 재적용해야 한다.

## 9. "not live" 재발 진단 + replicas 확장 가능 범위 분석 (2026-07-22)

### 9.1 target-tracking-service 리포에 push했는데 왜 반영이 안 됐나

`target-tracking-service` 리포에 커밋을 push한 뒤 인프라 레포에 자동 write-back이 안 되는 현상을 재현/진단. 파이프라인을 단계별로 추적한 결과:

| 단계 | 상태 |
|---|---|
| GitHub Actions (`Deploy target-tracking-service`) | ✅ 성공 (`gh run list`) |
| Docker Hub `:latest` 태그 갱신 | ✅ 새 digest로 갱신됨 (`last_updated` 확인) |
| ArgoCD Image Updater | ❌ 매 폴링 주기(2분)마다 skip |

컨트롤러 로그:
```
Image 'sm010422/target-tracking-service' seems not to be live in this application, skipping
```

**원인**: `apps/target-tracking-service/deployment.yaml`의 `replicas: 0` (`chore scale down target-tracking-service` 커밋으로 내려간 상태). 클러스터에 이 앱의 살아있는 pod가 없어서 Image Updater가 비교할 이미지 자체를 못 찾는 것 — 4.4절에서 이미 겪었던 것과 완전히 동일한 원인의 재발이다. CI/CD와 Image Updater 설정 자체는 정상이고, **"서비스가 실제로 떠 있어야 추적이 시작된다"**는 이 툴의 근본 동작 방식이 원인.

진단만 하고 조치는 보류(수동 실습 목적) — `replicas`를 1 이상으로 올리면 다음 폴링 주기 내에 `images_considered`가 0에서 늘어나는지로 재개 여부를 확인할 수 있다.

### 9.2 replicas를 얼마나 올릴 수 있나

`replicas: 0`을 복구할 때 몇까지 늘릴 수 있을지 점검한 기록.

**구조적 상한 — `hostPort: 8080`**: `deployment.yaml`의 컨테이너 포트가 `hostPort: 8080`으로 노드 포트에 직접 바인딩되어 있다. hostPort는 한 노드에 pod 하나만 뜰 수 있게 막기 때문에, 클러스터 노드가 3대(server1/2/3)인 이 환경에서는 **replicas 4 이상은 스케줄 자체가 불가능**하다 (4번째 pod는 바인딩할 노드가 없어 영구히 `Pending`). 즉 hostPort 방식을 쓰는 한 3이 물리적 상한.

**노드별 실사용 메모리 여유 (`kubectl top nodes` 기준)**:

| 노드 | 실사용률 | 여유 |
|---|---|---|
| server1 | 54% (1308Mi/2394Mi) | ~1086Mi |
| server2 | 70% (1028Mi/1453Mi) | ~425Mi |
| server3 | 38% (566Mi/1453Mi) | ~887Mi |

target-tracking-service 1 replica당 request 256Mi / limit 512Mi 기준:

- **replicas=2**: server1·server3 위주로 배치되면 여유롭게 가능
- **replicas=3 (hostPort상 최댓값)**: request 기준으론 3노드 모두 들어가지만, 이미 70%인 server2가 가장 타이트함. 이 앱이 Spring Boot(JVM) 기반이라 kafka에서 관찰했던 것과 비슷하게 재시작 직후엔 낮다가 시간이 지나며 limit(512Mi) 근처까지 서서히 증가하는 패턴을 보일 가능성이 있어, server2에 배정된 replica가 warm-up하면서 그 노드를 90%대까지 밀어붙일 수 있음

**결론**: 2는 안전, 3은 hostPort 제약상 이론적 상한이자 스케줄은 되지만 server2의 메모리 추이를 지켜보며 시도할 값.

## 10. kafka ↔ target-tracking-service podAntiAffinity 추가 (2026-07-22)

### 10.1 문제 상황

`k9s`로 c4i 네임스페이스 pod 분포를 보니 `kafka`, `redis`, `target-tracking-service` 3개가 전부 `server2`에 몰려있고(`postgres`만 `server1`), `server3`는 애플리케이션 워크로드 없이 놀고 있었다. 각 Deployment에 affinity 설정이 하나도 없어서 스케줄러가 그때그때 자리가 되는 노드에 배치한 결과가 누적된 것 — k8s는 이미 뜬 pod를 알아서 재배치(리밸런싱)해주지 않는다.

노드 3대에 c4i 앱 pod가 4개(kafka, postgres, redis, target-tracking-service)라 비둘기집 원리상 완전히 1노드 1pod로 흩어지는 건 애초에 불가능하다. 그래서 "무조건 다 떨어뜨리기"가 아니라, **실제로 위험한 조합만 피하는 쪽으로 접근**했다.

### 10.2 실사용량 기준 위험도 판단

| pod | 실사용 | limit | 증가 패턴 |
|---|---|---|---|
| kafka | 348Mi | 512Mi | JVM, warm-up 하며 지속 증가 (8절 참고) |
| target-tracking-service | 363Mi | 512Mi | JVM(Spring Boot), 마찬가지로 증가 추세 |
| postgres | 59Mi | 512Mi | 안정적, 거의 안 늘어남 |
| redis | 5Mi | 128Mi | 무시 가능한 수준 |

`kafka`와 `target-tracking-service`는 둘 다 JVM 기반이라 시간이 지나며 limit(512Mi) 근처까지 커질 수 있는 놈들이고, 같은 노드에 몰리면 그 노드 하나에서 최대 1Gi 가까이 먹을 수 있는 위험한 조합이다. 반면 `redis`·`postgres`는 사용량이 작고 안정적이라 누구랑 같은 노드를 써도 무방 — 그래서 **kafka ↔ target-tracking-service 사이에만** `podAntiAffinity`를 걸고, redis/postgres는 그대로 자유롭게 뒀다.

### 10.3 적용한 설정

`preferred`(soft) 방식으로 넣었다 — `required`(hard)로 걸면 노드 하나가 죽었을 때 "조건 만족하는 노드가 없다"며 pod가 영구히 `Pending`에 걸릴 수 있는데, 노드가 3대뿐인 홈랩 규모에선 이 리스크가 더 크다고 판단.

```yaml
# apps/target-tracking-service/kafka.yaml (spec.template.spec 아래)
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - target-tracking-service
          topologyKey: kubernetes.io/hostname
```

`apps/target-tracking-service/deployment.yaml`에도 대칭되게 `values: [kafka]`로 반대 방향 규칙을 추가.

### 10.4 참고 — nodeAffinity가 아니라 podAntiAffinity를 쓴 이유

- `nodeAffinity`는 **노드 자체의 라벨** 기준이라 "kafka는 server1/server3에만" 식으로 노드를 하드코딩해야 함 — 유연성이 떨어지고, 노드 구성이 바뀌면 매번 고쳐야 함
- `podAntiAffinity`는 **다른 pod의 라벨** 기준이라 "이 라벨 가진 pod가 있는 노드는 피해라"는 식으로, 어느 노드가 어떤 이름이든 상관없이 상대적으로 동작 — 이번처럼 "특정 두 워크로드끼리만 안 겹치면 됨"인 경우에 맞는 도구

이 설정은 스케줄링 시점에만 적용되는 힌트라, 이미 떠 있는 pod를 강제로 옮기지는 않는다 — 다음 재배포(새 이미지 반영 등으로 pod가 재생성될 때)부터 효과가 나타난다.
