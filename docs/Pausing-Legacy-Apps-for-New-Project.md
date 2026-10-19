# 기존 앱 일시 중지 — 새 프로젝트를 위한 리소스 확보와 복구 절차 (2026-10-19)

## 배경

이 클러스터에서 진행하던 C4I MSA 작업을 잠시 멈추고, 새 프로젝트(Personal Knowledge Graph MCP Server — Python/FastMCP + Neo4j)를 시작한다. 새 프로젝트는 **이 클러스터를 그대로 재사용**한다(Phase 2부터 k3s 배포, 기존 Prometheus/Grafana 활용). 그래서 클러스터나 VM을 내리는 게 아니라, **이전 프로젝트의 앱 워크로드만 0으로 내려 메모리를 비우는** 방식을 택했다.

중지 직전 노드 메모리 사용률은 master 83% / worker1 75% / worker2 74%로, Neo4j(최소 1GB 안팎)를 올릴 여유가 없었다.

## 검토한 선택지

| 선택지 | 복구 가능성 | 판단 |
|---|---|---|
| VM 3대 `multipass stop` | 완벽 (디스크 그대로) | VM 자체를 새 프로젝트에 다시 써야 해서 탈락 |
| VM 안에서 `systemctl disable --now k3s` | 완벽 (`/var/lib/rancher` 보존) | 새 프로젝트도 k3s를 쓰므로 불필요하게 큼 |
| 클러스터 삭제 후 재구축 | **불완전** — git에 없는 Secret 10개, PVC 데이터 5개 유실 | 탈락 |
| **앱 Deployment만 replicas 0 (GitOps)** | 완벽 (PVC·Secret·Service·Ingress·ArgoCD App 보존) | **채택** |

### 왜 `kubectl scale`이 아니라 git인가

모든 ArgoCD Application이 `syncPolicy.automated.selfHeal: true`라서, `kubectl scale --replicas=0`을 하면 ArgoCD가 몇 초 안에 git 상태(replicas 1)로 되돌린다. auto-sync를 끄고 scale하는 방법도 있지만, 그러면 "현재 클러스터 상태"가 git에 남지 않는다. 매니페스트의 `replicas`를 0으로 바꾸고 push하면 ArgoCD가 스스로 내리고, 복구도 `git revert` 한 번이면 끝난다.

## 수행한 작업

### 1. AI Health Check 워크플로 비활성화

매시간 클러스터를 점검해 ntfy로 다운 알림을 보내는 워크플로라, 앱이 내려간 동안 알림이 계속 울린다.

```bash
gh workflow disable ai-health-check.yml
```

### 2. replicas 1 → 0 (커밋 `244a066`)

| 파일 | 워크로드 | namespace |
|---|---|---|
| `apps/gitnexus/deployment.yaml` | gitnexus | tools |
| `apps/target-tracking-service/deployment.yaml` | target-tracking-service | c4i |
| `apps/target-tracking-service/kafka.yaml` | kafka | c4i |
| `apps/target-tracking-service/postgres.yaml` | postgres | c4i |
| `apps/target-tracking-service/redis.yaml` | redis | c4i |
| `apps/threat-intel-ai-service/deployment.yaml` | threat-intel-ai-service | c4i |
| `apps/threat-intel-ai-service/qdrant.yaml` | threat-intel-qdrant | c4i |

각 줄에 `# paused 2026-10-19 — see docs/Pausing-Legacy-Apps-for-New-Project.md` 주석을 달아, 매니페스트만 보고도 왜 0인지 알 수 있게 했다.

### 3. 그대로 둔 것

- **플랫폼**: ArgoCD(+Image Updater), Traefik, CoreDNS, metrics-server — 새 프로젝트도 사용
- **monitoring** 앱 전체(Prometheus, Grafana, kube-state-metrics, node-exporter, Headlamp) — 새 프로젝트 Phase 3에서 사용
- **PVC 5개** (local-path, 모두 `Bound` 유지): `c4i/postgres-pvc`, `c4i/threat-intel-qdrant-pvc`, `tools/gitnexus-data`, `monitoring/grafana-pvc`, `monitoring/prometheus-pvc`
- **Secret**: `c4i/target-tracking-secrets`, `tools/gitnexus-secrets`, `tools/gitnexus-ssh-key`, `argocd/git-creds` 등 (git에 없는 것들이라 지우면 복구 불가)
- **Service / Ingress / ArgoCD Application** — 엔드포인트만 비어 있는 상태 (Ingress로 들어오면 503)

## 결과

| 노드 | 중지 전 메모리 | 중지 후 메모리 (파드 정리 완료 후) |
|---|---|---|
| k3s-master | 2465Mi (83%) | 1369Mi (46%) |
| k3s-worker1 | 1094Mi (75%) | 576Mi (39%) |
| k3s-worker2 | 1277Mi (74%) | 976Mi (57%) |

합계 약 **1.9GB 확보**. master에서 gitnexus(~1.27GB)가 빠진 효과가 가장 크다. `c4i`·`tools` namespace의 파드는 0개.

ArgoCD 4개 앱은 모두 `Synced / Healthy` 유지(replicas 0도 원하는 상태이므로 Healthy).

## 복구 절차

### 1. 앱 되살리기

```bash
cd k3s-msa-infrastructure
git revert 244a066        # replicas 0 → 1 원복
git push origin main
```

ArgoCD가 기본 폴링 주기(최대 3분) 안에 sync한다. 바로 반영하려면:

```bash
kubectl annotate application -n argocd gitnexus target-tracking-service threat-intel-ai-service \
  argocd.argoproj.io/refresh=normal --overwrite
```

> 새 프로젝트를 이 클러스터에 올린 뒤라면, 먼저 노드 메모리(`kubectl top nodes`)를 확인할 것. 두 프로젝트를 동시에 띄울 만큼 여유가 없으면 새 프로젝트 쪽을 같은 방식(replicas 0)으로 내리고 복구한다.

### 2. 확인

```bash
kubectl get pods -n c4i
kubectl get pods -n tools
curl -s http://100.103.119.1/ai/health     # threat-intel-ai-service (Ingress /ai)
```

- **Kafka → threat-intel-ai-service 순서 문제**: 모든 파드가 동시에 뜨면 consumer가 Kafka보다 먼저 시작할 수 있다. 추석 정전 때 고친 재시도 로직 + `kafka_consumer_running` 기반 livenessProbe(`docs/Chuseok-Power-Outage-Recovery.md`)가 있으므로 잠시 재시작이 보여도 스스로 정상화된다.
- **local-path PVC의 노드 고정**: local-path 볼륨은 처음 생성된 노드에 묶여 있다(PV의 nodeAffinity). 파드는 자동으로 그 노드에 스케줄되므로 따로 할 일은 없지만, 해당 노드 메모리가 부족하면 `Pending`이 될 수 있다.

### 3. 헬스체크 다시 켜기

```bash
gh workflow enable ai-health-check.yml
```

## 중지 기간 동안 하면 안 되는 것

- PVC / namespace(`c4i`, `tools`) / Secret 삭제 — 데이터와 git에 없는 자격증명이 사라진다
- ArgoCD Application 삭제 — `prune: true`라서 Service·Ingress·PVC까지 같이 지워질 수 있다
- `k3s-uninstall.sh`, `k3s-agent-uninstall.sh` 실행
- 노드의 Tailscale 로그아웃 — k3s가 `tailscale0`(`--flannel-iface`)로 통신한다

## 참고: 중지 기간에도 돌아가는 것

- **ArgoCD Image Updater**: `target-tracking-service` / `threat-intel-ai-service` 이미지 digest가 바뀌면 여전히 `.argocd-source-*.yaml`을 git에 write-back한다. replicas는 건드리지 않으므로 앱이 다시 뜨지는 않는다. 다만 이 레포에 자동 커밋이 생길 수 있으니 push 전 `git pull`할 것.
- **Notion Doc Sync** 워크플로: 그대로 활성.
