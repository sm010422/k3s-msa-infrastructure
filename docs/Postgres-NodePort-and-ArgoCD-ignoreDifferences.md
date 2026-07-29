# postgres NodePort 노출과 ArgoCD `ignoreDifferences` 동작 원리

DB 클라이언트(TablePlus 등)로 `postgres-service`에 직접 접속하려다가 겪은 문제와, ArgoCD의 selfHeal이 왜 수동 변경을 되돌리는지, 그리고 `ignoreDifferences`로 어떻게 우회했는지 정리.

## 1. 문제 상황

`postgresql://admin:admin@100.122.146.63:5432/defense_db` 형태로 워커 노드의 Tailscale IP에 직접 접속을 시도했는데 연결이 안 됐다.

**원인**: `postgres-service`는 기본 `ClusterIP` 타입이다. ClusterIP는 클러스터 **내부**에서만 유효한 가상 IP(`10.43.x.x`)이고, 노드 자체의 물리/오버레이 네트워크 IP(`100.x.x.x`)에는 아무 포트도 바인딩되지 않는다. postgres pod가 우연히 특정 워커에 떠 있다고 해서 그 워커의 IP:5432로 연결되는 게 아니다.

계정/비밀번호(`admin`/`admin`)와 DB명(`defense_db`)은 `target-tracking-secrets` 시크릿 값과 일치했으므로 그 부분은 문제가 아니었다.

## 2. 1차 시도 — 그냥 NodePort로 패치 → 되돌아감

```bash
kubectl patch svc postgres-service -n c4i -p '{"spec": {"type": "NodePort", "ports": [
  {"port":5432,"targetPort":5432,"protocol":"TCP","nodePort":30432}
]}}'
```

패치 직후 `kubectl get svc`로는 `NodePort`로 잘 바뀐 걸 확인했는데, 몇 십 초 뒤 다시 확인하니 **`ClusterIP`로 되돌아가 있었다.**

### 왜 되돌아갔나 — ArgoCD selfHeal의 동작 원리

ArgoCD Application의 `syncPolicy.automated.selfHeal: true`는 다음과 같이 동작한다.

1. ArgoCD는 주기적으로(기본 3분 polling + 리소스 변경 감지 시 즉시) **git에 정의된 desired state**와 **클러스터의 live state**를 diff한다.
2. `postgres-service`는 `apps/target-tracking-service/postgres.yaml`(git)에 `type` 필드가 없다 → 기본값 `ClusterIP`가 desired state다.
3. `kubectl patch`로 live state를 `NodePort`로 바꾸면, 다음 reconcile 때 ArgoCD가 "git과 다르다"고 판단하고 **selfHeal이 live state를 git 상태(ClusterIP)로 강제로 되돌린다.**

반면 `argocd-server`의 NodePort(30443, `docs/VMware-to-Multipass-Cluster-Migration.md` 8.2절)는 왜 안 되돌아갔을까 — **`argocd-server` 자체는 어떤 ArgoCD Application에도 속하지 않는 리소스이기 때문이다.** ArgoCD는 기본적으로 자기 자신(ArgoCD 설치 리소스들)을 GitOps로 관리하지 않는다(이 리포에는 app-of-apps 패턴이 없다). 그래서 그쪽은 감시 대상이 아니라 수동 패치가 그대로 유지된 것이고, `postgres-service`는 `target-tracking-service` Application이 감시하는 리소스라서 되돌아간 것 — **"어떤 리소스가 어느 Application에 속해 있는가"가 selfHeal 적용 여부를 가른다.**

## 3. 해결 — `ignoreDifferences`

ArgoCD Application 스펙에 `ignoreDifferences`를 추가하면, 지정한 JSON 경로에 대해서는 **diff 비교 자체를 하지 않는다.** git 값이 무엇이든, live에 무슨 값이 들어있든 ArgoCD가 신경 쓰지 않으므로 selfHeal도 발동하지 않는다.

`argocd/applications/target-tracking-service.yaml`:

```yaml
spec:
  # ...
  ignoreDifferences:
    - group: ""              # core API group (Service는 group이 빈 문자열)
      kind: Service
      name: postgres-service
      jsonPointers:
        - /spec/type          # ClusterIP ↔ NodePort 차이를 무시
        - /spec/ports         # nodePort 번호 등 포트 관련 차이도 무시
```

적용:

```bash
kubectl apply -f argocd/applications/target-tracking-service.yaml   # Application 자체를 갱신
kubectl patch svc postgres-service -n c4i -p '{"spec": {"type": "NodePort", "ports": [
  {"port":5432,"targetPort":5432,"protocol":"TCP","nodePort":30432}
]}}'
```

이후 30초~1분 정도 ArgoCD의 reconcile 주기를 기다려서 되돌아가지 않는지 확인:

```bash
kubectl get svc postgres-service -n c4i        # Type이 NodePort로 유지되는지
kubectl get application target-tracking-service -n argocd  # Synced/Healthy 유지되는지
```

`ignoreDifferences`를 추가한 뒤에는 재패치 즉시가 아니라, **ArgoCD가 이 리소스는 더 이상 diff 대상이 아니라고 인식한 이후부터** 안정적으로 유지된다.

## 4. 이 방식의 장단점 — git에 직접 NodePort를 박는 것과 비교

| | `ignoreDifferences` (이번 선택) | git에 `type: NodePort` 직접 커밋 |
|---|---|---|
| DB 외부 노출 여부가 git에 드러나는가 | 아니오 (운영자의 수동 설정으로 남음) | 예 (배포 매니페스트에 영구 기록) |
| 재배포/재마이그레이션 시 자동 재현 | 안 됨 (매번 수동 패치 필요) | 자동으로 재현됨 |
| "앱 배포 스펙"과 "운영 편의용 노출"의 분리 | 분리됨 | 섞임 |

이번엔 "DB 직접 접속은 운영자 개인의 편의 목적이고, 앱 배포 스펙 자체에 영구히 박아둘 이유는 없다"는 판단으로 `ignoreDifferences` 쪽을 선택했다. 다만 이 문서에 그 사실을 기록해뒀으니(그리고 `ignoreDifferences` 자체는 git에 커밋됐으니), 다음에 클러스터를 다시 만들 때 "postgres NodePort 패치를 다시 해줘야 한다"는 걸 잊지 않을 수 있다.

## 5. 최종 접속 정보

```
postgresql://admin:admin@100.103.119.1:30432/defense_db
```

Tailscale IP는 마스터든 워커든 아무 노드나 써도 된다 (kube-proxy가 NodePort를 전 노드에 동일하게 프로그래밍하기 때문). 계정/비밀번호/DB명은 `target-tracking-secrets` 시크릿(`docs/VMware-to-Multipass-Cluster-Migration.md` 5.5절)에서 온 값과 동일하다.

## 6. 같은 방식이 필요할 다른 상황

`kafka-service`, `redis-service`도 같은 이유(ClusterIP만 있고 NodePort 없음)로 외부 클라이언트에서 직접 접속이 안 된다. 필요해지면 동일한 패턴을 반복하면 된다 — `ignoreDifferences`에 해당 Service 이름만 추가하고, 원하는 nodePort로 패치.

## 7. 2026-07-28 경과 — 결국 git에 `type: NodePort` 직접 커밋으로 전환

위 4번 항목에서 예상했던 단점이 그대로 현실화됐다. **재현성 없음**: 클러스터를 다시 만들거나 어떤 이유로든 수동 패치가 사라지면(정확한 원인은 특정 못 함 — Application/Service가 재생성됐거나 누군가 재배포한 것으로 추정), `postgres-service`는 git에 적힌 대로 조용히 `ClusterIP`로 돌아가 있었다. `ignoreDifferences`는 git에 남아있었지만, "패치를 다시 해야 한다"는 사실 자체를 잊어서 다음에도 DBUI 접속이 막혀 있었다.

이후 이를 고치려던 커밋(`5d3ad0c`)이 `nodePort: 30432` 필드만 추가하고 `type: NodePort`로의 변경을 빠뜨렸다. 그 결과 ArgoCD sync가 매번 다음 에러로 실패했다:

```
Service "postgres-service" is invalid: spec.ports[0].nodePort: Forbidden: may not be used when `type` is 'ClusterIP'
```

`ignoreDifferences`가 `/spec/type`, `/spec/ports`를 무시하도록 걸려 있었기 때문에, git이 어떻게 바뀌든 ArgoCD가 diff로도 잡아내지 못해 이 실패가 한동안 눈에 띄지 않았다.

**최종 조치 (커밋 `8bc99d2`)**: `postgres.yaml`에 `type: NodePort`를 정식으로 커밋하고, `argocd/applications/target-tracking-service.yaml`의 `ignoreDifferences` 블록을 완전히 제거했다. 이제 "DB 외부 노출"은 운영자 개인 설정이 아니라 **배포 매니페스트의 일부**다. 4번 표의 트레이드오프 판단이 뒤집힌 셈 — 편의를 위한 분리보다 재현성이 실제로 더 중요했다.

이 판단은 `qdrant`에도 그대로 적용했다 (`docs/Qdrant-NodePort-and-Dashboard-Access.md` 참고) — 처음부터 `ignoreDifferences` 없이 git에 `type: NodePort`를 바로 커밋함.
