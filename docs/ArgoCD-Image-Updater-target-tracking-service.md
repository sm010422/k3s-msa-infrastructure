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
