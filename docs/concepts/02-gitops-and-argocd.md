# 개념 정리 — GitOps와 ArgoCD

"git push만 하면 자동으로 배포된다"는 말을 그대로 믿고 진행했다면 어디서 막혔을지, 그리고 실제로 어디서 막혔는지 정리.

## 1. GitOps의 핵심 아이디어

전통적인 배포는 "명령형(imperative)"이다 — 사람이나 CI가 `kubectl apply`, `ssh + 스크립트 실행` 같은 **동작**을 실행시킨다. 클러스터의 실제 상태와, "이게 맞는 상태다"라고 기록해둔 문서가 따로 놀기 쉽다(누가 급하게 `kubectl edit`으로 수동 패치하면 git에는 안 남는 식).

**GitOps**는 반대다: **Git 저장소 안의 YAML이 "유일한 진실"**이고, 클러스터는 그 상태를 계속 "따라가려고" 하는 대상이다. 사람은 클러스터에 직접 명령하지 않고 git에 커밋만 한다. 클러스터 쪽의 별도 컨트롤러(여기선 ArgoCD)가 git을 주기적으로 보고, git과 클러스터 실제 상태가 다르면 알아서 맞춘다.

이번 작업에서 이 원칙을 지키려고 한 부분: DB 비밀번호/`GEMINI_API_KEY` 같은 시크릿은 **git에 넣지 않고** `kubectl`로 클러스터에 직접 주입했다. 이건 순수 GitOps 원칙에서 보면 예외(git이 유일한 진실이 아니게 됨)지만, public 레포에 평문 시크릿을 커밋하는 것보다는 훨씬 안전한 실용적 타협이다. (더 정석적인 방법은 Sealed Secrets나 External Secrets Operator로 "암호화된 시크릿"만 git에 커밋하는 것 — 이번 클러스터엔 아직 없어서 안 씀.)

## 2. ArgoCD `Application`이라는 오브젝트 — GitOps의 실제 연결고리

git 저장소에 YAML을 올려놓는 것만으로는 아무 일도 안 일어난다. **"이 git 레포의 이 경로를, 이 클러스터의 이 네임스페이스에 동기화해라"**라는 매핑을 ArgoCD에게 알려주는 리소스가 필요한데, 그게 `Application`이다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: target-tracking-service
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/sm010422/k3s-msa-infrastructure.git
    targetRevision: HEAD
    path: apps/target-tracking-service
  destination:
    server: https://kubernetes.default.svc
    namespace: c4i
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

이번에 가장 중요했던 발견: **이 YAML 파일이 `k3s-msa-infrastructure` 레포 안에 있다는 사실 자체는 아무 의미가 없다.** `Application`도 결국 하나의 쿠버네티스 리소스라서, `argocd` 네임스페이스에 **`kubectl apply`로 실제로 생성**해야 ArgoCD 컨트롤러가 그 존재를 인식한다.

```bash
kubectl get application -n argocd   # → No resources found
```

사용자가 공유한 4단계 계획("이미지 push → 매니페스트 반영 → git push → ArgoCD가 감지해서 자동 배포")은 **이 Application이 이미 등록되어 있다는 전제** 위에서만 성립한다. 실제로는 한 번도 apply된 적이 없어서, git에 아무리 정확한 YAML을 push해도 그걸 지켜보는 컨트롤러 자체가 없는 상태였다 — "감지해서 자동 배포"할 대상 매핑이 클러스터에 존재하지 않았던 것.

```bash
kubectl apply -f argocd/applications/target-tracking-service.yaml
```
이 한 줄이 빠지면 GitOps 파이프라인의 "관측하는 쪽"이 아예 없는 셈이다.

## 3. `syncPolicy`가 의미하는 것

- **`automated`**: 사람이 ArgoCD UI에서 "Sync" 버튼을 눌러야만 반영되는 수동 모드가 기본값인데, 이걸 켜면 git 변경을 감지하는 즉시 자동으로 적용한다.
- **`prune: true`**: git에서 리소스를 지우면, 클러스터에서도 그 리소스를 자동으로 삭제한다. (→ `postgres.yaml`을 실수로 지우면 PVC까지 자동 삭제된다는 이번 문서의 경고가 여기서 나온 것.)
- **`selfHeal: true`**: 누가 `kubectl edit`으로 클러스터를 git과 다르게 수동으로 고쳐놔도, ArgoCD가 주기적으로 다시 git 상태로 되돌린다. GitOps의 "git이 유일한 진실"을 실제로 강제하는 옵션.
- **`CreateNamespace=true`**: destination 네임스페이스(`c4i`)가 없으면 ArgoCD가 알아서 만들어준다 — 그래서 `kubectl create namespace c4i`를 미리 안 해도 Application 등록만으로 네임스페이스는 해결됐을 것(다만 이번엔 Secret을 먼저 넣어야 해서 namespace를 수동으로 먼저 만들었다).

## 4. Sync Status가 `Unknown`이라는 것의 의미

ArgoCD가 리소스를 실제로 배포하려면 내부적으로 여러 단계를 거친다: git에서 매니페스트를 가져오고(`repo-server`), 클러스터의 실제 상태와 비교(`diff`)하고, 그 비교 결과를 캐시(`redis`)에 저장한다. `Sync Status`는 "git이 원하는 상태"와 "클러스터의 실제 상태"를 비교한 **결론**이다:

- `Synced`: 둘이 일치
- `OutOfSync`: 다름 (git을 반영해야 함)
- `Unknown`: **비교 자체를 못 했다**

이번에 겪은 `Unknown`은 비교 로직이 캐시 저장(`argocd-redis`) 단계에서 타임아웃 나면서 결론을 못 내린 상태였다. 그래서 `automated.selfHeal`이 있어도 "Skipping auto-sync: application status is Unknown" 로그처럼 **자동 동기화 자체가 스킵**됐다 — 비교가 안 된 상태에서 무언가를 밀어붙이는 건 위험하니, ArgoCD가 의도적으로 아무것도 안 하는 안전한 선택을 한 것. 이 문제의 근본 원인은 GitOps/ArgoCD 개념과는 무관한 클러스터 네트워킹 이슈였다 (`03-cluster-network-debugging.md` 참고).

## 5. 이번에 실제로 쓴 GitOps 우회 — kubectl apply 직접 실행

ArgoCD의 캐시 문제로 자동 동기화가 막히자, `kubectl apply -f`로 직접 리소스를 만들었다. 이게 GitOps 원칙을 깨는 건 아니다 — git에 있는 내용과 정확히 같은 걸 적용했기 때문에, **나중에 ArgoCD가 다시 정상 작동하면 git과 클러스터 상태가 이미 일치하므로 그냥 `Synced`로 인식**될 것이다(충돌 없음). GitOps의 "관측 경로"(ArgoCD)가 일시적으로 고장났다고 해서 "실제 배포"(kubectl apply)까지 막힐 필요는 없다 — 다만 이후로는 반드시 git을 통해서만 변경해야 두 경로가 다시 벌어지지 않는다.
