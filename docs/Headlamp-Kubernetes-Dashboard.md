# Headlamp — 경량 Kubernetes 대시보드 연동 (2026-09-30)

`apps/monitoring/`(Prometheus/Grafana/kube-state-metrics/node-exporter가 이미 있는 그 네임스페이스)에 [Headlamp](https://headlamp.dev/)를 추가한 기록. 지금까지는 클러스터 상태를 보려면 SSH로 들어가서 `kubectl` 명령을 직접 치거나 `k9s`(터미널 UI)를 써야 했는데, 웹 대시보드 하나 정도는 붙여도 될 만큼 여유가 있는지부터 확인하고 진행했다.

## 진행 전 리소스 확인

<table fit-page-width="true" header-row="true">
<tr><td>노드</td><td>사용중</td><td>여유</td></tr>
<tr><td>master</td><td>1832Mi/3G (61%)</td><td>~1.14GB</td></tr>
<tr><td>worker1</td><td>1037Mi/1.4G (71%)</td><td>~400MB</td></tr>
<tr><td>worker2</td><td>1229Mi/1.7G (72%)</td><td>~470MB</td></tr>
</table>

Headlamp은 단일 파드(Go 백엔드 + 정적 프론트엔드, k8s API 프록시 역할만)라 kube-state-metrics(~30MB 실사용)나 Grafana(~100~150MB)와 비슷한 체급 — request 64Mi/limit 200Mi로 잡아도 여유 안에 충분히 들어간다고 판단하고 진행.

## 왜 Headlamp인가

- 공식 `kubernetes-dashboard`(레거시)보다 가볍고, 최근 kubernetes-sigs로 이관되며 사실상 공식 후속 대시보드로 자리잡음
- k9s(터미널 UI, 이미 쓰고 있음)와 겹치지만, 브라우저에서 바로 볼 수 있고 다른 사람에게 화면 공유하기 쉬움 — 용도가 겹치는 도구를 완전히 대체하기보다 "터미널 없이 훑어볼 때" 보완용

## 배포

공식 매니페스트(`kubernetes-sigs/headlamp` 저장소의 `kubernetes-headlamp.yaml`)를 이 리포 컨벤션에 맞게 손봤다.

<table fit-page-width="true" header-row="true">
<tr><td>항목</td><td>값</td><td>비고</td></tr>
<tr><td>이미지</td><td>`ghcr.io/headlamp-k8s/headlamp:v0.41.0`</td><td>공식 예시는 `:latest`인데, 이 리포의 다른 모니터링 컴포넌트(Prometheus/Grafana/kube-state-metrics/node-exporter)가 전부 버전 고정이라 그 컨벤션을 따름</td></tr>
<tr><td>배치</td><td>기존 패턴대로 control-plane 회피 + kafka/qdrant/target-tracking-service/postgres 회피</td><td>실제로 worker1에 배치됨</td></tr>
<tr><td>리소스</td><td>request 50m/64Mi, limit 200m/200Mi</td><td></td></tr>
<tr><td>노출</td><td>NodePort `30466`</td><td>Prometheus(30090)/Grafana(30300)와 동일하게 Tailscale 밖으로는 안 나감</td></tr>
</table>

### 공식 예시에서 뺀 것 — tracing/OTLP, 그리고 존재하지 않는 9090 포트

공식 매니페스트엔 `HEADLAMP_CONFIG_TRACING_ENABLED`, `HEADLAMP_CONFIG_OTLP_ENDPOINT: otel-collector:4317` 같은 env가 있는데, 이 클러스터엔 OTel 콜렉터가 없어서 존재하지 않는 엔드포인트를 가리키게 된다 — 에러만 남기고 아무 이득이 없어서 뺐다. `HEADLAMP_CONFIG_METRICS_ENABLED=true`만 남겨서 Prometheus가 스크랩하도록 새 job을 추가했다.

**배포 직후 스크랩 타겟이 "down"으로 떴다.** 공식 매니페스트는 metrics를 별도 `containerPort: 9090`으로 노출하는 것처럼 선언해두는데, 실제로 파드 로그(`"Listen address: :4466"`, `"prometheus metrics endpoint: /metrics"`)를 확인해보니 **메인 HTTP 포트(4466)의 `/metrics` 경로**로 같이 나오고 있었다 — 9090엔 아무것도 안 물려 있어서 `wget`도 타임아웃. 컨테이너 포트 선언에서 9090을 빼고 스크랩 대상을 `4466/metrics`로 바로잡았다. "공식 예시니까 맞겠지"라고 믿지 않고 `kubectl exec`로 직접 찔러본 덕에 바로 잡을 수 있었다.

### RBAC — cluster-admin, 의도적으로 넓게

로그인 토큰용 `ServiceAccount` + `ClusterRoleBinding`을 `cluster-admin`으로 걸었다. 보통은 과하다고 볼 수 있지만, 이 클러스터는 이미 SSH로 들어가서 `kubectl`을 직접 칠 수 있는 상태라 **대시보드 토큰 권한을 좁혀도 실질적인 위협 모델이 줄지 않는다** — Prometheus/Grafana NodePort와 동일하게 Tailscale 밖으로는 애초에 노출이 안 되는 구조이기 때문. 나중에 이 클러스터를 여러 사람이 쓰게 되거나 공개 노출을 고려하게 되면, 그때는 `view`/`edit` ClusterRole로 좁히는 게 맞다.

## 접속

```bash
# 로그인 토큰 조회
kubectl get secret headlamp-admin -n monitoring -o jsonpath='{.data.token}' | base64 -d
```

`http://k3s-master.taildcdcee.ts.net:30466` 접속 → 위 토큰을 로그인 화면에 붙여넣기.

## 검증

```bash
kubectl get pods -n monitoring -l app=headlamp
# 1/1 Running

curl http://<k3s-master-tailscale-ip>:30466/
# 200

curl http://<k3s-master-tailscale-ip>:30090/api/v1/targets
# job=headlamp health=up
```

배포 완료 후 최종 확인: Grafana/Prometheus/kube-state-metrics/node-exporter/cAdvisor/앱 서비스 2개까지 포함해서 **스크랩 타겟 11개 전부 `up`**.
