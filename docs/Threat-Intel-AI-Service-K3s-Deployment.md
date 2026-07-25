# threat-intel-ai-service K3s/ArgoCD 배포 기록

새 Python AI 마이크로서비스(`threat-intel-ai-service` — FastAPI + LangGraph + Qdrant, 별도 리포)를 GitHub 리포 생성부터 실제 클러스터에 트래픽이 흐르는 상태까지 올린 기록. `target-tracking-service`가 이미 깔아둔 CI/CD 관례(Docker Hub + GitHub Actions + ArgoCD Image Updater)를 그대로 재사용했고, 재사용 과정에서 이 파이프라인의 숨은 전제 조건 하나를 새로 발견했다.

## 1. 클러스터에 얹기 전에 먼저 한 것 — 리소스 여유 확인

배포하기 전에 `kubectl top nodes` / `kubectl describe node`로 실측한 결과, `k3s-worker1`(1 core/1.45GB)은 이미 memory limit 96%까지 차 있어서 새 워크로드를 얹기엔 빡빡했고, `k3s-worker2`(1 core/1.7GB)는 memory request 15%만 쓰는 중이라 여유가 있었다. `k3s-master`는 control-plane taint로 애초에 배제. 자세한 수치와 판단 근거는 `threat-intel-ai-service` 리포의 `docs/concepts/08-k3s-cluster-capacity-check.md`에 있다. 결론만 요약하면: **새 서비스는 worker2에 붙인다.**

## 2. 매니페스트 설계

`apps/threat-intel-ai-service/`에 세 파일을 추가했다.

- `deployment.yaml` — FastAPI 앱 (`sm010422/threat-intel-ai-service:latest`, containerPort 8000)
- `qdrant.yaml` — Qdrant Deployment + PVC(`local-path`, 1Gi) + Service. `target-tracking-service/postgres.yaml`과 동일하게 `strategy: Recreate`(RWO 볼륨이라 롤링 업데이트 시 두 pod가 동시에 마운트를 시도하면 안 됨)
- `service.yaml` — 앱용 ClusterIP Service (포트 8000)

### 2.1 worker2로 스케줄을 강제한 방법

노드 이름을 직접 하드코딩(`nodeSelector: kubernetes.io/hostname: k3s-worker2`)하는 대신, `kafka.yaml`/`target-tracking-service/deployment.yaml`이 이미 쓰고 있던 것과 같은 패턴을 재사용했다:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - target-tracking-service
                - postgres
                - redis
        topologyKey: kubernetes.io/hostname
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
```

worker1에 이미 떠 있는 세 앱(`target-tracking-service`, `postgres`, `redis`)과 같은 노드에는 못 뜨게 하는 required anti-affinity. master는 taint로 이미 막혀 있어서 이 두 조건을 합치면 남는 노드가 worker2뿐이라, 결과적으로 노드 이름을 하드코딩한 것과 같은 효과를 얻으면서도 "왜 이 노드인지"가 라벨 기반으로 명시적으로 드러난다. `threat-intel-ai-service`와 `threat-intel-qdrant` 둘 다 같은 규칙을 걸어서 worker2에 같이 뜨게 했다 — 실제로 배포해보니 예측대로 둘 다 worker2에 스케줄됐다.

### 2.2 시크릿/컨피그맵을 새로 안 만들고 기존 것 재사용

```yaml
env:
  - name: GEMINI_API_KEY
    valueFrom:
      secretKeyRef: { name: target-tracking-secrets, key: gemini-api-key }
  - name: KAFKA_BOOTSTRAP_SERVERS
    valueFrom:
      configMapKeyRef: { name: target-tracking-config, key: kafka-bootstrap-servers }
```

`target-tracking-secrets`, `target-tracking-config`는 `target-tracking-service`용으로 이미 만들어져 있던 것들이다. 새 Secret/ConfigMap을 또 만드는 대신 그대로 참조했다 — 어차피 같은 Gemini 계정, 같은 Kafka 브로커를 두 서비스가 공유하는 게 맞는 그림이라, 값을 이중으로 관리할 이유가 없었다. (참고로 이 Secret은 GitOps 대상이 아니라 클러스터에 `kubectl create secret`으로 직접 만들어진 것 — git에는 안 올라간다.)

### 2.3 배포 전 검증

실제로 push하기 전에 `kubectl apply --dry-run=server -k apps/threat-intel-ai-service`로 살아있는 클러스터의 API 서버에 대고 스키마 검증을 했다. 로컬 `kubectl kustomize` dry-run만으로는 CRD 존재 여부나 실제 API 버전 호환성까지는 못 잡아서, `--dry-run=server`로 한 번 더 확인하는 습관을 들이는 중이다.

## 3. ArgoCD 등록 — "git에 Application yaml이 있다고 자동 등록되는 게 아니다"

`argocd/applications/threat-intel-ai-service.yaml`을 만들어서 커밋했는데, push만으로는 아무 일도 안 일어났다. `kubectl get applications -n argocd`에 새 Application이 안 잡혀서 원인을 보니, 이 리포에는 **app-of-apps 패턴(루트 Application이 `argocd/applications/` 폴더 자체를 감시하는 구조)이 없다** — 기존 `target-tracking-service` Application도 처음엔 누군가 `kubectl apply -f`로 수동 등록했을 것이고, `defense-api-gateway.yaml`도 리포에 파일은 있지만 실제로 `kubectl get applications`에는 안 잡히는 상태였다 (교차 확인함).

```bash
kubectl apply -f argocd/applications/threat-intel-ai-service.yaml
```

이 한 줄로 등록하니 바로 `Synced`로 넘어갔다. **이 리포의 GitOps는 "매니페스트 변경은 자동 반영(`syncPolicy.automated`)"이지만, "새 Application을 추가하는 것 자체"는 최초 1회 수동 개입이 필요한 구조**라는 걸 이번에 명확히 확인했다 — 다음에 세 번째 서비스를 추가할 때도 이 단계를 잊으면 안 된다.

## 4. ArgoCD Image Updater 연결 — 기존 CR에 항목만 추가

`argocd/image-updater.yaml`은 `ImageUpdater` CRD 하나(`target-tracking-service-updater`)가 `applicationRefs` 리스트로 여러 앱을 동시에 추적하는 구조라, 새 CR을 만들 필요 없이 리스트에 항목 하나만 추가했다:

```yaml
applicationRefs:
  - namePattern: "target-tracking-service"
    images: [...]
  - namePattern: "threat-intel-ai-service"      # 추가한 부분
    images:
      - alias: "threat-intel-ai-service"
        imageName: "sm010422/threat-intel-ai-service:latest"
        commonUpdateSettings:
          updateStrategy: "digest"
```

git write-back에 쓰는 SSH Deploy Key(`argocd/git-creds` Secret)도 이미 `k3s-msa-infrastructure` 리포 전체에 쓰기 권한이 있는 것 하나가 있어서, 새로 발급할 필요가 없었다 — 이 키는 서비스별이 아니라 인프라 리포 단위로 스코프돼 있다.

### 4.1 실제로 자동 파이프라인이 작동하는 걸 확인

CI가 Docker Hub에 이미지를 올리자마자 (몇 분 안에) 컨트롤러 로그에 이렇게 찍히는 걸 확인했다:

```
Setting new image to sm010422/threat-intel-ai-service:latest@sha256:cd5af034...
Successfully updated image ... but pending spec update (dry run=false)
Committing 1 parameter update(s) for application threat-intel-ai-service
git push origin main
Successfully updated the live application spec
```

`git log`로 확인해보니 `argocd-image-updater` 계정 명의로 `build: automatic update of threat-intel-ai-service` 커밋이 실제로 push돼 있었고, `apps/threat-intel-ai-service/.argocd-source-threat-intel-ai-service.yaml`(kustomize image override 파일)이 자동 생성돼 있었다 — `target-tracking-service`용으로 이미 검증된 파이프라인이 두 번째 앱에서도 별도 설정 추가(Deploy Key 재발급, CRD 재생성) 없이 그대로 작동한다는 걸 확인한 셈.

이후 코드 버그 두 개를 고쳐서(자세한 내용은 `threat-intel-ai-service` 리포의 `docs/concepts/10-live-verification-chat-and-ingest.md`) 다시 push했을 때도, **2분 폴링 주기** 안에 컨트롤러가 새 digest를 감지해서 write-back → pod 롤아웃까지 사람 개입 없이 자동으로 끝났다. `kubectl patch application ... -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`로 강제 refresh를 걸면 폴링 주기를 안 기다리고 즉시 반영시킬 수 있다는 것도 확인.

## 5. 최종 확인

```bash
kubectl get pods -n c4i -l 'app in (threat-intel-ai-service,threat-intel-qdrant)'
# threat-intel-ai-service-xxx   1/1   Running   0   ...   k3s-worker2
# threat-intel-qdrant-xxx       1/1   Running   0   ...   k3s-worker2

kubectl port-forward -n c4i svc/threat-intel-ai-service 18000:8000
curl http://localhost:18000/health
# {"status":"ok","ai_enabled":true,"qdrant_connected":true,"kafka_consumer_running":true}
```

두 pod 모두 예측한 대로 worker2에 배치됐고, 재시작 없이 안정적으로 떠 있다. Gemini 키(기존 Secret 재사용), Qdrant, Kafka(기존 브로커) 세 연동 모두 살아있는 상태로 확인 완료.
