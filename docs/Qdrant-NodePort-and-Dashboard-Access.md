# qdrant NodePort 노출과 DBUI 대신 웹 대시보드로 접속하기

`threat-intel-qdrant-service`를 postgres와 같은 이유로 NodePort로 열면서 겪은 일과, 범용 DB 클라이언트("DBUI")로는 왜 Qdrant에 붙을 수 없는지 정리.

## 1. 문제 상황

postgres(`postgres-service`)를 NodePort로 열어 DBUI에서 접속에 성공한 뒤, 같은 네임스페이스(`c4i`)의 `threat-intel-qdrant-service`도 원격에서 접속하려 했다.

**원인은 postgres와 동일**: `threat-intel-qdrant-service`가 `type: ClusterIP`였다. ClusterIP는 클러스터 내부 전용 가상 IP라서, 노드의 Tailscale IP(`100.x.x.x`)로는 애초에 도달할 수 없다.

```yaml
# apps/threat-intel-ai-service/qdrant.yaml (변경 전)
spec:
  type: ClusterIP
  selector:
    app: threat-intel-qdrant
  ports:
    - port: 6333
      targetPort: 6333
      protocol: TCP
```

## 2. 조치 — git에 바로 `type: NodePort` 커밋

postgres 사례(`docs/Postgres-NodePort-and-ArgoCD-ignoreDifferences.md` 7절)에서 "`ignoreDifferences` + 수동 패치"는 재현성이 없어서 재해가 반복된다는 걸 확인했으므로, 이번엔 처음부터 git에 직접 커밋하는 쪽을 택했다.

```yaml
# apps/threat-intel-ai-service/qdrant.yaml (변경 후, 커밋 0dc7c1c)
spec:
  type: NodePort
  selector:
    app: threat-intel-qdrant
  ports:
    - port: 6333
      targetPort: 6333
      nodePort: 30333
      protocol: TCP
```

`nodePort: 30333`은 postgres 때 쓴 "30000 + 원래 포트 마지막 3자리"(5432 → 30432) 패턴을 따른 것 (6333 → 30333).

`argocd/applications/threat-intel-ai-service.yaml`에는 postgres Application과 달리 애초에 `ignoreDifferences`가 없었기 때문에, `selfHeal: true`가 이 변경을 그대로 반영했다 — 별도 예외 처리가 필요 없었다.

기존 NodePort들과 충돌 여부 확인:

| Service | NodePort |
|---|---|
| `postgres-service` | 30432 |
| `defense-api-gateway` | 30081 |
| `argocd-server` | 31525 / 30443 |
| `threat-intel-qdrant-service` | **30333** (신규, 충돌 없음) |

## 3. 다른 컴포넌트에 미치는 영향 — 없음

- **내부 통신 불변**: `threat-intel-ai-service`가 `QDRANT_HOST=threat-intel-qdrant-service` 환경변수로 접속하는 경로(`deployment.yaml:59-61`)는 ClusterIP가 그대로 유지되므로 영향 없음. `type`만 바뀌었고 `clusterIP` 필드 자체는 변경되지 않는다.
- **NetworkPolicy**: `c4i` 네임스페이스에는 NetworkPolicy가 없어서(있는 건 `argocd` 네임스페이스뿐) 접근을 막는 요소가 없다.
- **포트 충돌**: 위 표 참고, 없음.

## 4. 인증이 없다 — postgres와의 결정적 차이

postgres는 `target-tracking-secrets`에서 `POSTGRES_USER`/`POSTGRES_PASSWORD`를 주입받지만, `threat-intel-qdrant` Deployment에는 **컨테이너 env가 하나도 없다**:

```bash
kubectl get deploy threat-intel-qdrant -n c4i -o jsonpath='{.spec.template.spec.containers[0].env}'
# → 빈 값
```

Qdrant는 `QDRANT__SERVICE__API_KEY` 환경변수(또는 config)를 명시적으로 설정해야만 API 키 인증이 켜진다. 지금은 그게 없으므로 **30333에 도달할 수 있는 누구나 인증 없이 컬렉션을 읽고/쓰고/지울 수 있다.** Tailscale 오버레이 안이라는 것만이 유일한 방어선이다. 필요해지면 Secret으로 API 키를 만들어 컨테이너에 주입하고 클라이언트 쪽에도 같은 키를 넣는 작업이 별도로 필요하다 (아직 미적용).

## 5. DBUI(범용 DB 클라이언트)로는 왜 안 되나 — `no adapter for http`

NodePort까지 다 열어놓고 DBUI(TablePlus류 범용 DB 클라이언트)의 연결 필드에 `http://100.x.x.x:30333`을 넣었더니 다음 에러가 났다:

```
DB: no adapter for http
```

**원인**: postgres 때와 달리 이건 네트워크/K8s 문제가 아니라 **클라이언트 소프트웨어의 한계**다. TablePlus/DBeaver 같은 범용 DB 클라이언트는 `postgres://`, `mysql://`, `mongodb://`처럼 정해진 DB 와이어 프로토콜의 어댑터만 내장한다. Qdrant는 그런 프로토콜이 아니라 순수 **HTTP REST API**(+ 선택적 gRPC)로 통신하는 벡터 DB라서, "http"라는 어댑터 자체가 클라이언트 목록에 없어 연결 시도 단계에서 바로 거부당한다.

### 대안

Qdrant 이미지(`qdrant/qdrant:v1.12.4`)에는 REST 포트(6333/30333)에 웹 대시보드가 내장되어 있다. 이건 DBUI 앱이 아니라 **브라우저로 직접 열면 되는 웹페이지**다:

```
http://100.83.49.100:30333/dashboard
```

브라우저가 아닌 다른 방식으로 접근하려면:

| 방법 | 용도 |
|---|---|
| 브라우저 (`/dashboard`) | 컬렉션/포인트 GUI 조회 — 가장 간단 |
| Postman / Insomnia | `GET /collections` 등 REST 요청으로 조회·조작 |
| `curl` | 빠른 확인: `curl http://100.83.49.100:30333/collections` |
| `qdrant-client` (Python/JS) | 코드로 직접 쿼리 |

gRPC(6334)로 접속하는 전용 클라이언트를 쓰려면 현재 컨테이너에 6334 포트 자체가 열려있지 않아 `qdrant.yaml`의 `containerPort`/Service에 포트를 추가로 열어야 한다 (아직 미적용, 필요 시 진행).

## 6. 최종 접속 정보

```
REST API / 웹 대시보드: http://<노드 Tailscale IP>:30333  (예: http://100.83.49.100:30333/dashboard)
```

노드 IP는 마스터/워커 아무거나 사용 가능 (kube-proxy가 NodePort를 전 노드에 동일하게 프로그래밍하기 때문):

| 노드 | Tailscale IP |
|---|---|
| k3s-master | 100.103.119.1 |
| k3s-worker1 | 100.122.146.63 |
| k3s-worker2 | 100.83.49.100 |

인증 없음 (4절 참고).
