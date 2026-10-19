# Personal Knowledge Graph MCP 서버 배포 — 클러스터 쪽 기록 (2026-10-19)

## 배경

C4I 앱들을 일시 중지(`docs/Pausing-Legacy-Apps-for-New-Project.md`)하고 확보한 메모리에, 새 프로젝트 [personal-knowledge-graph-mcp](https://github.com/sm010422/personal-knowledge-graph-mcp)를 올렸다. Claude에게 장기 기억을 주는 MCP 서버(Python/FastMCP)와 Neo4j다.

앱 자체의 설계, 매니페스트 설명, 운영 절차(토큰 교체, 롤백, 장애 대응)는 앱 레포의 `docs/deployment.md`에 있다. 이 문서는 **이 클러스터 입장에서 무엇이 추가됐고, 기존 구성과 무엇이 다르고, 무엇을 조심해야 하는지**만 다룬다.

## 이 레포에 추가된 것

`argocd/applications/personal-kg.yaml` 하나다.

```yaml
source:
  repoURL: https://github.com/sm010422/personal-knowledge-graph-mcp.git
  targetRevision: main
  path: k8s
destination:
  namespace: personal-kg
syncPolicy:
  automated: { prune: true, selfHeal: true }
  syncOptions: [CreateNamespace=true]
```

다른 Application들처럼 `kubectl apply -f argocd/applications/personal-kg.yaml`로 한 번 등록했다. 등록 직후 `Synced / Healthy`를 확인했다.

## 기존 앱과 다른 점

| | 기존 앱 (target-tracking, threat-intel) | personal-kg |
|---|---|---|
| 매니페스트 위치 | 이 레포 `apps/<name>/` | **앱 레포** `k8s/` |
| 이미지 갱신 | Image Updater가 `:latest` digest 추적 → 이 레포에 `.argocd-source-*.yaml` write-back | **앱 CI가** `k8s/kustomization.yaml`의 `newTag`를 커밋 SHA로 커밋 |
| 클러스터에 필요한 git 자격증명 | `argocd/git-creds` (이 레포 쓰기) | 없음 (public 레포 읽기만) |
| 배포된 버전 확인 | digest → 레지스트리 조회 | 매니페스트의 SHA = 커밋 |

방식을 다르게 한 이유는 앱 레포의 ADR-0008에 있다. 요약하면, 앱 레포에 대한 쓰기 키를 클러스터에 하나 더 두지 않으려는 것과, 매니페스트만 보고도 정확한 버전을 알 수 있게 하려는 것이다.

## 클러스터에 생긴 리소스

| 리소스 | 노드 | 실측 메모리 |
|---|---|---|
| StatefulSet `neo4j` (+ PVC `data-neo4j-0`, local-path 2Gi) | **k3s-master** (nodeAffinity + master taint toleration) | 629~669Mi (limit 1Gi) |
| Deployment `personal-kg-mcp` | worker (첫 배포 시 worker1) | 95~106Mi (limit 256Mi) |
| Ingress `personal-kg-mcp` (`/mcp`) | — | — |
| NetworkPolicy `neo4j-from-mcp-only` | — | — |
| Secret `personal-kg-secrets` | — | git에 없음, `kubectl create secret`으로 생성 |

노드 메모리 변화:

| 노드 | C4I 앱 중지 직후 | personal-kg 배포 후 |
|---|---|---|
| k3s-master | 46% | 67% |
| k3s-worker1 | 39% | 52% |
| k3s-worker2 | 57% | 53% |

## 주의 1 — C4I 앱을 복구할 때 master 메모리

**gitnexus(약 1.27GB)와 Neo4j(약 0.65GB)는 둘 다 k3s-master에 고정돼 있다.** master는 약 2.9GiB이고 지금 67%를 쓰고 있다. 이 상태에서 `git revert 244a066`으로 C4I 앱을 모두 되살리면, gitnexus가 master에 들어갈 자리가 없어서 `Pending`이 되거나 노드가 메모리 압박을 받는다.

복구할 때는 다음 중 하나를 고른다.
- personal-kg를 먼저 replicas 0으로 내린다(앱 레포에서 커밋). PVC는 남는다.
- gitnexus만 빼고 복구한다.
- Multipass로 master VM 메모리를 늘린다(`multipass set local.k3s-master.memory=...`, VM 정지 필요, `docs/Multipass-Operations-Guide.md` 3절).

`docs/Pausing-Legacy-Apps-for-New-Project.md`의 복구 절차에도 같은 경고를 추가했다.

## 주의 2 — Funnel이 Ingress를 전부 공개한다

k3s-master의 Tailscale Funnel은 Traefik 80번을 통째로 인터넷에 공개한다(`docs/Public-Access-via-Tailscale-Funnel.md`). 그래서 Ingress `/mcp`를 추가하는 순간 `https://k3s-master.taildcdcee.ts.net/mcp`가 공개 URL이 됐다.

- MCP 서버는 Bearer 토큰 없이는 401을 반환한다(공개 URL에서 실측).
- Ingress는 `/mcp`만 연다. 프로브 경로와 Neo4j는 외부에 노출되지 않는다.
- **앞으로 이 클러스터에 Ingress를 추가할 때도 같다.** 인증 없는 서비스에 Ingress를 붙이면 그대로 인터넷에 열린다.

## 주의 3 — 첫 배포 때의 CrashLoopBackOff

첫 배포에서 MCP 파드가 4번 재시작했다. headless Service(`neo4j`)는 Neo4j 파드가 Ready가 되기 전까지 DNS가 해석되지 않는데, 서버는 시작할 때 DB 연결에 실패하면 종료하는 구조였다.

`docs/Chuseok-Power-Outage-Recovery.md`의 Kafka consumer 사례와 같은 종류다(시작 순서 경쟁 + 재시도 없음). 서버가 백그라운드에서 백오프 재시도를 하도록 고쳤다. 두 파드를 동시에 삭제해서 재현했더니 재시작 0회, 39초 만에 정상화됐다.

이 클러스터에서 같은 패턴을 두 번 겪었으니 원칙으로 남겨둘 만하다. **의존 서비스 연결은 시작 조건이 아니라 readiness 조건이어야 한다.**

## 확인 명령

```bash
kubectl get application personal-kg -n argocd          # Synced / Healthy
kubectl get pods -n personal-kg -o wide
kubectl top pods -n personal-kg
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://k3s-master.taildcdcee.ts.net/mcp   # 401 (토큰 없음)
```
