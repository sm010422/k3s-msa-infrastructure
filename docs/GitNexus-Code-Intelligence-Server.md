# GitNexus 코드 인텔리전스 서버 상시 배포 (2026-10-05)

GitNexus(`gitnexus@1.6.12`, 레포를 그래프로 인덱싱해서 AI 에이전트가 MCP로 질의하게 해주는 npm 도구)를 `tools` 네임스페이스에 상시 서비스로 띄운 기록. 설계 논의부터 디스크 장애·VM 리사이즈까지, 실제로 겪은 삽질을 순서대로 남긴다.

## 1. 사전 확인 — 네임스페이스/노출 범위/배치

- **네임스페이스**: 기존 `c4i`(C4I 앱)도 `monitoring`(관측 도구)도 성격이 안 맞아서 새로 `tools` 생성.
- **노출 범위 — 이 클러스터에서 "Ingress"의 의미**: `docs/Public-Access-via-Tailscale-Funnel.md`를 다시 보면, 이 클러스터의 Traefik Ingress는 전부 `tailscale funnel 80`을 통해 **공인 인터넷에 통째로 노출**된다. 즉 Ingress를 쓰면 "내부 전용"이 아니라 "전 세계 공개"가 되는 구조다. 진짜 "내부 전용(VPN 안에서만)" 패턴은 Headlamp/Grafana/Prometheus가 쓰는 **NodePort**였다 — 이게 GitNexus에도 맞는 선택.
- **노드 배치**: 당시(스웜 부하 테스트 직후) 워커 두 대가 메모리 74%로 빡빡했던 반면 `k3s-master`는 CPU 2코어/메모리 여유가 더 많아서, 인덱싱 시 메모리를 꽤 쓰는 GitNexus를 **의도적으로 컨트롤 플레인에 배치**(평소 "컨트롤 플레인은 피한다"는 컨벤션을 깸).

## 2. 이미지 — 공식 Dockerfile.cli를 못 쓴 이유

GitNexus 저장소의 `Dockerfile.cli`를 그대로 쓰려고 했는데, 주석을 읽어보니 **의도적으로 web UI 번들을 뺀 API 전용 이미지**였다(Render의 분리형 아키텍처용 — API 서버 + 별도 web 프록시 컨테이너). 반면 npm 패키지 자체(`registry.npmjs.org/gitnexus/-/gitnexus-1.6.12.tgz`)를 까보면 `package/web/`에 115개 파일(빌드된 UI 번들)이 그대로 들어있다는 걸 확인했다 — 즉 **`npm install -g gitnexus@1.6.12`만으로 웹 UI까지 다 포함**된다. 처음 요청받은 대로 단순한 Dockerfile을 직접 작성했다(`node:22-bookworm-slim` + 빌드 도구 + 전역 설치).

## 3. 보안 — `serve`는 기본적으로 인증이 없다

실측으로 확인한 중요한 사실 두 가지:

**① `GITNEXUS_PUBLIC_ORIGIN`을 설정하면 서버가 시작 자체를 거부한다.** 로컬에서 직접 컨테이너를 돌려 확인:
```
Failed to start GitNexus server:
  GITNEXUS_PUBLIC_ORIGIN is set (...), but 'gitnexus serve' has no
  authentication yet. ... reach the server through a proxy that
  authenticates for it.
```
공식 README에도 같은 내용이 있었지만, 문서를 그대로 믿지 않고 실제로 컨테이너를 띄워서 재현했다. 그래서 이 값은 아예 안 넣는다.

**② 결과적으로 쓰기 라우트(POST /api/analyze, DELETE /api/repo)는 loopback 오리진만 허용.** 와일드카드 바인드(`--host 0.0.0.0`)에서 서버 자체 로그가 이렇게 경고한다:
```
[gitnexus serve] Bound to a wildcard address (0.0.0.0); browser write
routes accept only loopback origins (localhost/127.0.0.1/[::1]).
```
즉 NodePort로 접속하면 그래프 열람은 되지만, **UI에서 직접 "인덱싱 시작" 버튼은 막힌다.** `GITNEXUS_MCP_AUTH_TOKEN`은 `/api/mcp` 라우트만 보호하는 별개 메커니즘이고(로그로 `"Bearer authentication enabled for serve /api/mcp"` 확인), 이 쓰기 제약과는 무관하다.

### "그럼 서버로 띄운 의미가 없는 거 아닌가?"

이 제약을 발견하고 실제로 나온 질문. 답은: **GitNexus는 애초에 웹 UI가 메인 용도가 아니다** — README 자체가 "CLI + MCP(권장) vs 웹 UI(데모/일회성 탐색용)"로 구분해놓았다. 그래서:
- **MCP 연결**은 브라우저가 아니라 Bearer 토큰으로 직접 붙는 거라 이 제약이 아예 안 걸림
- **`auto-sync`**는 파드 안에서 도는 CLI 백그라운드 작업이라 역시 무관
- 웹 UI는 "이미 인덱싱된 그래프를 읽기 전용으로 보는 용도"로만 쓰고, 새 레포 추가는 `kubectl exec`/`port-forward`로 처리하는 쪽으로 방향을 잡았다(인증 프록시를 새로 세우는 것보다 수고 대비 이득이 큼).

## 4. SSH 배포 키 — auto-sync용

전용 읽기 전용 키를 새로 만들어서(기존 개인 키 재사용 안 함) `gh repo deploy-key add`로 `k3s-msa-infrastructure` 레포에 read-only로 등록했다. k8s Secret(`gitnexus-ssh-key`)으로 마운트하고 `GIT_SSH_COMMAND`로 identity file을 지정.

**권한 삽질**: Secret 볼륨을 `defaultMode: 0400`으로 마운트했더니 `Load key ... Permission denied` — Secret 볼륨은 root 소유로 마운트되는데 컨테이너는 `USER node`(UID 1000)로 돌아서 못 읽었다. ssh의 실제 키 권한 검사는 group/other의 **쓰기** 비트만 거부하지 읽기 비트는 상관없어서, `0444`(모두 읽기, 쓰기 없음)로 풀어서 해결.

## 5. ArgoCD와 수동 kubectl apply가 서로 되돌리는 경쟁 상태

권한 수정을 git에 push한 뒤 바로 `kubectl apply`로 직접 적용했는데, 잠시 후 확인해보니 **ArgoCD의 `selfHeal`이 내가 막 적용한 새 설정을 자기가 마지막으로 동기화했던(더 오래된) git 상태로 도로 되돌려놓고 있었다** — `defaultMode`가 다시 256(0400)으로 보임. 원인은 ArgoCD가 아직 내 최신 push를 못 가져온 상태였던 것. `kubectl annotate application gitnexus -n argocd argocd.argoproj.io/refresh=hard`로 강제 새로고침하니 바로 최신 커밋으로 동기화되면서 해결됐다 — **이후로는 수동 kubectl apply 대신 이 방식으로 통일**.

## 6. `procps` 누락 — auto-sync가 자기 자신을 못 찾음

`gitnexus auto-sync start`가 `[auto-sync] Unable to verify the watch process start time`로 실패. 공식 `Dockerfile.cli`의 주석("procps for watch process identity")을 다시 보고 발견 — auto-sync가 백그라운드 watch 프로세스를 띄운 뒤 `ps`로 자기 시작 시각을 검증하는데, 내가 처음 쓴 Dockerfile엔 `procps` 패키지가 빠져 있었다. 추가하고 재빌드/재푸시.

## 7. 장애 — 디스크 100%로 파드 축출 사고

procps를 고친 이미지를 올리다가 **k3s-master 디스크가 100%까지 차서 이미지 pull이 실패**했고, kubelet이 `DiskPressure`를 걸면서 **파드를 실제로 축출(evict)하는 사고**로 이어졌다(ReplicaSet이 계속 재생성→축출을 반복).

**즉시 조치**: `kubectl scale deployment gitnexus -n tools --replicas=0`으로 크래시 루프부터 멈추고, 축출된 파드 잔해를 정리 — 100%→81%로 일단 안정화.

**원인 진단**(짐작 대신 직접 확인):
- GitNexus 자신의 PVC 사용량은 **20KB** — 레포 인덱싱 데이터가 쌓여서 생긴 문제가 아니었다
- `crictl images --filter dangling=true` — 안 쓰는 이미지 없음, 반복 빌드가 레이어를 중복으로 쌓은 것도 아니었다
- 진짜 원인: **VM 디스크 자체가 10~13GB로 작게 잡혀 있었고**, 기본 OS(`/usr` 2.0GB) + k3s/컨테이너 이미지(`/var/lib/rancher` 3.8GB)만으로 이미 대부분 차 있던 상태에서, 685MB짜리 GitNexus 이미지가 마지막 턱을 못 넘긴 것 — "뭔가 계속 쌓이는 구조"가 아니라 "원래부터 여유가 거의 없었던 구조"였다
- `apt-get clean` + `journalctl --vacuum-time=3d` + `/tmp` 정리로 노드당 200~400MB 정도만 회수됨 — 근본 해결은 안 됨

## 8. multipass VM 디스크 리사이즈

**호스트 확인 실수**: 처음에 `df -h /`를 이 작업을 실행하던 로컬 환경에서 돌려서 "569GB 여유"라는 잘못된 수치를 얻었다 — 실제 서버(맥북 에어, `100.112.104.24`)가 아니라 엉뚱한 머신을 본 것. 사용자가 바로 잡아줘서 SSH로 실제 서버에 재확인: **228GB 중 72GB 여유** — 여전히 충분했다(multipass의 qcow2 디스크는 가상 크기만큼 바로 차지하는 게 아니라 쓴 만큼만 커지는 sparse 방식이라, 가상 디스크 37GB를 할당해둔 지금도 호스트 실사용은 12GB뿐이었다).

**리사이즈 절차**(노드당 `multipass stop` → `multipass set local.<노드>.disk=30G` → `multipass start`), **master → worker1 → worker2 순서로 하나씩** 진행하며 매번 클러스터 상태 확인:

```
k3s-master   10.6GiB → 29.0GiB (cloud-init이 재부팅 시 자동으로 growpart)
k3s-worker1  13.5GiB → 29.0GiB
k3s-worker2  13.5GiB → 29.0GiB
```

worker2를 멈췄다 올리는 동안 거기 떠 있던 ArgoCD 컴포넌트들이 잠깐 `Unknown`/재시작됐지만, 전부 자동으로 정상 복구됐다(`kubectl get pods -A` 재확인, `Running` 아닌 것 0개). 최종 디스크 여유: 세 노드 다 19~20GB(30~35% 사용).

## 9. auto-sync 설정 — 한 번 더 걸린 검증 규칙

procps 수정 + 디스크 여유 확보 후 재시도하니 이번엔 설정값 검증에 걸렸다:
```
[auto-sync] Invalid watch_config.yml: analyze_timeout must not exceed
half of sync_interval_minutes (5m). Auto sync is skipped.
```
`sync_interval_minutes: 10` + `analyze_timeout: 10m` 조합이 "분석 제한시간이 동기화 주기의 절반을 넘으면 안 된다"는 규칙에 걸린 것. `sync_interval_minutes`를 30으로 올려서 해결.

**최종 성공**:
```
[auto-sync] Watch loop started at 2026-10-05T13:52:50.942Z.
[auto-sync] Watch loop finished: synced=1 analyzed=1 skipped=0 failed=0.
```
`auto-sync status` → `state=running` — 30분마다 자동 재동기화. 클론된 레포 PVC 사용량은 33MB(작은 인프라 레포라 부담 없음).

## 10. 접속/사용법

```
URL: http://k3s-master.taildcdcee.ts.net:30747   (tailnet 내부 전용, Funnel 안 탐)
MCP 인증 토큰: Secret gitnexus-secrets의 mcp-auth-token (git에 없음, kubectl로 조회)
```

- **그래프 열람(읽기 전용)**: 위 URL 그대로 브라우저 접속
- **MCP로 AI 에이전트 연결**: `http://k3s-master.taildcdcee.ts.net:30747/api/mcp` + `Authorization: Bearer <토큰>`
- **새 레포 인덱싱/쓰기 작업**(UI 버튼 등): loopback 제약 때문에 아래 둘 중 하나 필요
  ```bash
  kubectl exec -it -n tools deploy/gitnexus -- gitnexus analyze <경로>
  # 또는
  kubectl port-forward -n tools deploy/gitnexus 4747:4747   # 그 다음 http://localhost:4747
  ```
- **auto-sync 대상 레포 추가**: `watch_config.yml`(`/data/.gitnexus/watch_config.yml`)의 `remote_urls`에 SSH URL 추가 후 `gitnexus auto-sync restart` — 단, 레포마다 전용 읽기 전용 배포키를 새로 만들어서 등록하는 걸 권장(지금 키는 `k3s-msa-infrastructure` 전용)

## 관련 문서

- `docs/Headlamp-Kubernetes-Dashboard.md` — NodePort+tailnet-전용 패턴의 원조, 리소스 사전 확인 방식
- `docs/Public-Access-via-Tailscale-Funnel.md` — 왜 이 클러스터의 Ingress가 곧 "공개"를 의미하는지
- `target-tracking-service/docs/concepts/09-swarm-load-generator-design-discussion.md` — 워커 노드 메모리가 74%까지 빡빡해졌던 배경(master를 선택한 이유와 직결)
