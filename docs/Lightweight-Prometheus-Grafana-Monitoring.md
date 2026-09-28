# 경량 Prometheus + Grafana 모니터링 스택 (2026-09-28)

클러스터 관측성을 올리기 위해 Prometheus + Grafana를 얹은 기록. **full `kube-prometheus-stack`은 이 홈랩 규모엔 과해서 처음부터 배제하고, 경량 구성으로 직접 짰다.**

> **정정**: 이 문서 초안엔 "`Headless-Migration-Amphetamine-to-Caffeinate.md`로 확보한 메모리 여유를 활용해서"라고 써있었는데 틀렸다. 호스트(macOS) 메모리 정리와 k3s VM(게스트) 메모리는 **서로 다른 풀**이라 호스트 쪽에서 아무리 회수해도 VM에 잡힌 고정 할당량은 안 바뀐다. 실제로 이 스택이 들어간 자리는 원래부터 있던 `worker1`의 여유 공간이었다 — 자세한 설명은 `Host-vs-Cluster-Memory-Two-Separate-Pools.md` 참고.

## 왜 kube-prometheus-stack을 안 썼나

Helm으로 흔히 까는 `kube-prometheus-stack`(Prometheus Operator + Alertmanager + node-exporter + kube-state-metrics + Grafana)은 보통 1.5~2.5GB를 먹는다. 배포 직전 기준 워커 두 대(worker1 630MB, worker2 560MB) 합쳐 여유가 1.2GB뿐이었어서, 이걸 깔면 여유를 통째로 날리고 kafka/qdrant처럼 이미 빡빡한 워크로드까지 OOM 위험에 노출시킬 수 있었다.

## 구성 — 뺀 것과 남긴 것

<table fit-page-width="true" header-row="true">
<tr><td>구성요소</td><td>포함?</td><td>이유</td></tr>
<tr><td>Prometheus (plain Deployment)</td><td>✅</td><td>Operator 없이 ConfigMap 기반 설정. retention 3일, PVC 2Gi</td></tr>
<tr><td>Grafana</td><td>✅</td><td>Prometheus 데이터소스 자동 프로비저닝, PVC 500Mi</td></tr>
<tr><td>cAdvisor 스크랩 (노드/파드 CPU·메모리)</td><td>✅ (추가 파드 0개)</td><td>kubelet이 이미 내장 노출 중인 걸 API 서버 프록시로 스크랩 — node-exporter 안 깔아도 됨</td></tr>
<tr><td>Alertmanager</td><td>❌</td><td>이미 `ai-health-check.yml` + ntfy로 알림 체계 있음, 중복</td></tr>
<tr><td>kube-state-metrics / node-exporter</td><td>❌ (나중에 필요하면 추가)</td><td>파드 개수·디플로이먼트 상태까지 보고 싶어지면 그때 ~50~80Mi로 저렴하게 추가 가능</td></tr>
<tr><td>Prometheus Operator</td><td>❌</td><td>CRD 컨트롤러 자체가 리소스 비용 — plain Deployment로 충분한 규모</td></tr>
</table>

## 리소스 사이징

<table fit-page-width="true" header-row="true">
<tr><td>컴포넌트</td><td>request</td><td>limit</td></tr>
<tr><td>Prometheus</td><td>cpu 50m / mem 100Mi</td><td>cpu 200m / mem 250Mi</td></tr>
<tr><td>Grafana</td><td>cpu 50m / mem 100Mi</td><td>cpu 200m / mem 200Mi</td></tr>
</table>

배치 스케줄링은 기존 패턴을 그대로 따랐다 — `nodeAffinity`로 control-plane(master) 회피, `podAntiAffinity`(preferred)로 kafka/qdrant/target-tracking-service/postgres가 있는 노드를 피함. 실제로 둘 다 여유가 가장 많던 `worker1`에 배치됐다.

## 스크랩 대상

이미 계측이 끝나 있어서 순수 인프라만 얹으면 됐다 — 새 앱 코드는 하나도 안 건드렸다:

<table fit-page-width="true" header-row="true">
<tr><td>job</td><td>경로</td><td>비고</td></tr>
<tr><td>`threat-intel-ai-service`</td><td>`/ai/metrics`</td><td>Python `prometheus_client`로 이미 노출 중</td></tr>
<tr><td>`target-tracking-service`</td><td>`/actuator/prometheus`</td><td>Spring Boot Actuator + Micrometer로 이미 노출 중</td></tr>
<tr><td>`kubernetes-cadvisor`</td><td>API 서버 프록시 (`/api/v1/nodes/{node}/proxy/metrics/cadvisor`)</td><td>노드별 컨테이너 CPU·메모리 — 10250 포트 직접 접근 불필요, RBAC(ClusterRole)만 있으면 됨</td></tr>
</table>

## 배포 과정

```bash
# 1. namespace + Grafana admin 비밀번호(git에 커밋하지 않음 -- target-tracking-secrets와 동일 패턴)
kubectl create namespace monitoring
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-password='<생성된 랜덤 비밀번호>'

# 2. apps/monitoring/ 매니페스트 git push 후 ArgoCD Application 최초 1회 등록
#    (이 리포는 app-of-apps/ApplicationSet이 없어서 새 Application은 수동 kubectl apply 필요)
kubectl apply -f argocd/applications/monitoring.yaml
```

## 검증

```bash
kubectl get pods -n monitoring
# grafana     1/1 Running
# prometheus  1/1 Running

curl http://<k3s-master-tailscale-ip>:30090/api/v1/targets
# kubernetes-cadvisor x3 (노드별) + target-tracking-service + threat-intel-ai-service -- 전부 up

curl http://<k3s-master-tailscale-ip>:30300/api/health
# 200

kubectl top nodes
```

**배포 전후 worker1 메모리**: 807Mi(55%) → 1005Mi(69%) — 약 200MB 증가, 예상 범위(최대 350~450MB) 안쪽. CPU는 초기 기동 직후 38%까지 튀었다가 곧 15%로 안정.

## 접속 정보

<table fit-page-width="true" header-row="true">
<tr><td>도구</td><td>주소 (Tailscale 네트워크 내부)</td><td>인증</td></tr>
<tr><td>Prometheus</td><td>`http://k3s-master.taildcdcee.ts.net:30090`</td><td>없음(내부망 전용이라 인증 미설정)</td></tr>
<tr><td>Grafana</td><td>`http://k3s-master.taildcdcee.ts.net:30300`</td><td>admin / (클러스터에 직접 생성한 Secret 값, git에는 없음)</td></tr>
</table>

기존 Qdrant(`30333`), Postgres(`30432`) NodePort와 동일하게 Tailscale 네트워크 밖으로는 노출되지 않는다.

## 남은 선택지 (필요해지면)

- **대시보드**: 지금은 데이터소스만 연결된 빈 Grafana 상태. `target-tracking-service`/`threat-intel-ai-service` 커스텀 대시보드나, cAdvisor 데이터로 노드별 리소스 대시보드를 만들면 유용할 것.
- **kube-state-metrics 추가**: 파드 재시작 횟수, 디플로이먼트 replica 상태 등을 그래프로 보고 싶어지면 ~50~80Mi로 저렴하게 추가 가능.
- **retention 조정**: 지금 3일로 짧게 잡음. 디스크 여유(worker1 기준 ~3.9GB)를 봐가며 늘릴 수 있음.
