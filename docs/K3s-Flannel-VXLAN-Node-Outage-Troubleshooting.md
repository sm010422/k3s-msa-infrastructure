# server1 flannel.1 인터페이스 소실로 인한 전체 크로스노드 통신 장애 — 트러블슈팅 기록

`https://100.116.194.42:8080` (server1의 `target-tracking-service`)가 "예전엔 됐었는데 갑자기 안 된다"는 증상으로 시작해서, 실제로는 **server1(Control Plane) 노드의 flannel VXLAN 인터페이스 자체가 사라진 클러스터 전역 장애**였던 걸 밝혀낸 과정. `docs/concepts/03-cluster-network-debugging.md`에서 "다음 세션에서 이어서 진단할 부분"으로 남겨뒀던 크로스노드 연결성 확인이 실제로 필요했던 사례이기도 하다.

## 1. 증상

- 브라우저로 `https://100.116.194.42:8080/` 접속 시 `ERR_CONNECTION_REFUSED`
- "원래 됐었는데" — 즉 회귀(regression). 코드 변경 없이 갑자기 끊긴 상황이라 인프라/네트워크 계층을 먼저 의심.

## 2. 진단 — 계층을 하나씩 좁혀나간 순서

### 2-1. 언더레이(Tailscale) 자체는 살아있는가

```bash
tailscale status
ping -c 3 100.116.194.42
```

→ `tailscale status`에 server1이 `active`로 표시되고, ping도 정상 응답. **VPN/언더레이 네트워크 자체는 문제가 없다**는 걸 가장 먼저 확인해서, "네트워크가 아예 끊겼다"는 가설을 제거.

### 2-2. 포트 자체가 열려있는가

```bash
curl -vk https://100.116.194.42:8080/
nc -zv 100.116.194.42 8080
```

→ `Connection refused`. 방화벽에 막혀 패킷이 드롭되는 것(그 경우 보통 타임아웃)이 아니라, **그 포트에 리스닝하는 프로세스가 아예 없다**는 신호.

### 2-3. 클러스터 상태 확인 — 진짜 문제 발견

```bash
kubectl get pods -A
```

`c4i` 네임스페이스에서 예상 밖의 상태 발견:

```
kafka-...                    0/1  CrashLoopBackOff   41 restarts
target-tracking-service-...  0/1  CrashLoopBackOff   39 restarts   (server1)
target-tracking-service-...  1/1  Running            42 restarts  (server2)
```

target-tracking-service가 **같은 앱인데 노드에 따라 결과가 다르다**는 게 첫 번째 결정적 단서였다. 코드/이미지 문제였다면 모든 replica가 동일하게 실패해야 한다.

### 2-4. 로그로 실패 지점 좁히기

```bash
kubectl -n c4i logs deploy/kafka --tail=40
kubectl -n c4i logs -l app=target-tracking-service --tail=40
```

- **kafka** → server3에서 실행 중, zookeeper(server1)에 소켓은 열리지만 40초간 응답이 없어 타임아웃:
  ```
  Opening socket connection to server zookeeper-service.../10.43.169.120:2181.
  ERROR Timed out waiting for connection to Zookeeper server
  ```
- **target-tracking-service** (server1 replica) → postgres(server2) 이름 자체를 못 찾음:
  ```
  Caused by: java.net.UnknownHostException: postgres-service.c4i.svc.cluster.local
  ```

두 실패의 공통점: **실패하는 두 서비스 쌍이 전부 서로 다른 노드에 떠 있다.** kafka(server3)↔zookeeper(server1), target-tracking-service(server1)↔postgres(server2). 반면 정상 동작하던 target-tracking-service replica는 postgres와 **같은 노드(server2)**에 있었다. → "노드 내부 통신은 되는데 노드 간 통신이 안 된다"는 가설 수립.

## 3. 가설 검증 — 디버그 파드로 크로스노드 연결성 직접 테스트

같은 네임스페이스에 임시 디버그 파드(`nicolaka/netshoot`)를 특정 노드에 강제 스케줄링해서 파드 간 통신을 직접 찔러봤다.

```yaml
# server3에 고정
nodeSelector:
  kubernetes.io/hostname: server3
```

```bash
# server3 파드 → server1 파드 IP로 기본 ping
kubectl exec netdebug-server3 -- ping -c 5 10.42.0.18
# → 5 packets transmitted, 0 received, 100% packet loss
```

**기본 ICMP조차 100% 유실.** 큰 페이로드나 특정 서비스 프로토콜만 문제였다면 MTU를 의심했겠지만, 가장 작은 ping조차 안 됐다는 건 MTU 문제가 아니라 **경로 자체가 끊겨있다**는 뜻이었다. (참고로 `-M do -s 1450` 같은 MTU 테스트도 같이 돌려봤지만, 기본 ping부터 실패한 시점에서 MTU 가설은 기각.)

### 3-1. 언더레이와 오버레이를 분리해서 테스트

파드 네트워크(flannel 오버레이)와 노드 자체 네트워크(Tailscale 언더레이)를 구분하기 위해, 이번엔 `hostNetwork: true`로 디버그 파드를 띄워 **호스트 자체의 네트워크 네임스페이스**에서 테스트했다.

```bash
# hostNetwork 파드로 server3 → server1 (Tailscale IP) ping
kubectl exec hostnet-server3 -- ping -c 5 100.116.194.42
# → 0% packet loss, 정상

# VXLAN 캡슐화에 쓰이는 UDP 8472 포트 자체도 열려있는지 확인
kubectl exec hostnet-server3 -- sh -c "echo test | nc -u -w 2 100.116.194.42 8472"
# → 정상 도달
```

**언더레이(Tailscale)와 VXLAN 포트(UDP 8472)는 완전히 정상.** 그런데 파드 대 파드(오버레이) 통신은 100% 실패. → 결론적으로 문제는 "네트워크가 끊겼다"가 아니라 **"각 노드의 flannel VXLAN 인터페이스 설정/상태" 자체**에 있다는 뜻.

## 4. 근본 원인 발견

```bash
kubectl exec hostnet-server1 -- ip -d link show flannel.1
# → Device "flannel.1" does not exist.

kubectl exec hostnet-server3 -- ip -d link show flannel.1
# → 정상 존재 (vxlan id 1 local <server3 tailscale ip> dev tailscale0 ...)
```

**server1(Control Plane)에만 `flannel.1` VXLAN 인터페이스가 아예 없었다.** server3에는 정상적으로 있었고, FDB(VXLAN 목적지 매핑 테이블)도 올바르게 다른 노드들을 가리키고 있었다. 즉 다른 노드들이 server1로 보내는 VXLAN 캡슐화 패킷이 server1에 도착은 해도, 그걸 디캡슐레이션해서 파드 브리지로 넘겨줄 인터페이스 자체가 없어서 전부 드롭되고 있었던 것.

**결론**: server1에서 flannel을 관리하는 k3s 프로세스가 어떤 이유로든(재시작 실패, 일시적 크래시 등) VXLAN 인터페이스를 재생성하지 못한 상태였다. 이 인터페이스 하나가 없어지는 것만으로 해당 노드로 향하는 모든 노드 간 파드 통신이 마비된다 — CNI(Container Network Interface) 계층 장애가 왜 "무관해 보이는 여러 서비스가 동시에 같은 패턴으로 실패"를 만드는지 실감한 부분.

## 5. 1차 해결 — k3s 재시작

server1에 직접 SSH 접속 후:

```bash
sudo systemctl restart k3s
ip -d link show flannel.1   # 재생성 확인
```

재시작 후 확인:

```bash
kubectl -n c4i get pods -o wide
```

`kafka`, `target-tracking-service`(server1 replica) 모두 CrashLoopBackOff에서 벗어나 `Running`으로 전환. 크로스노드 파드 통신이 정상화됐다는 뜻.

## 6. 2차 문제 — 클러스터는 정상인데 여전히 8080이 refused

클러스터 자체는 복구됐는데도 `https://100.116.194.42:8080/`은 여전히 연결이 안 됐다. 원인을 다시 좁혀보니:

```bash
kubectl -n c4i get svc target-tracking-service -o yaml | grep -E "type:|port:"
# type: ClusterIP
```

**서비스가 ClusterIP였다.** ClusterIP는 클러스터 내부에서만 유효한 가상 IP라, 원래도 `100.116.194.42:8080`처럼 노드의 실제 IP로 외부에서 직접 접속되려면 별도의 노출 수단(hostPort/NodePort/Ingress 또는 임시 `kubectl port-forward`)이 있어야 한다. 즉 **"예전엔 됐었다"는 것 자체가, 어딘가에서 임시로 띄워둔 port-forward 프로세스에 의존하고 있었다는 뜻**이었고, 그 프로세스가 이번 장애(k3s 재시작 등) 와중에 같이 죽어서 다시 안 살아난 것.

## 7. GitOps 제약 — 클러스터를 직접 고치면 안 되는 이유

```bash
kubectl -n argocd get applications
# target-tracking-service   Synced   Healthy
```

이 앱은 ArgoCD가 `sm010422/k3s-msa-infrastructure` 저장소의 `apps/target-tracking-service` 경로를 `automated: { prune: true, selfHeal: true }`로 감시하고 있었다. **이 상태에서 `kubectl patch`로 클러스터에 직접 hostPort를 추가해도, ArgoCD의 selfHeal이 Git의 상태와 다르다고 판단해서 곧 되돌려버린다.** 그래서 영구적인 노출 설정은 클러스터가 아니라 **이 저장소의 매니페스트**에서 해야 한다.

## 8. 영구 해결 — hostPort 추가

`apps/target-tracking-service/deployment.yaml`:

```diff
           ports:
             - containerPort: 8080
+              hostPort: 8080
               protocol: TCP
```

`replicas: 2`라 pod가 server1/server2/server3 중 어디에 스케줄되든, 뜬 노드의 실제 IP:8080으로 바로 접속 가능해진다 (같은 노드에 hostPort 8080을 쓰는 다른 파드만 없으면 충돌 없음).

```bash
git add apps/target-tracking-service/deployment.yaml
git commit -m "feat(target-tracking-service): expose 8080 via hostPort for direct node access"
git push origin main

# 폴링 주기를 기다리지 않고 즉시 반영하려면
kubectl -n argocd patch application target-tracking-service \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## 9. 검증

```bash
kubectl -n c4i get pods -l app=target-tracking-service -o wide
# 새 ReplicaSet 파드의 containers[0].ports에 hostPort:8080 반영 확인

curl -v http://100.116.194.42:8080/actuator/health
# HTTP/1.1 200
# {"status":"UP","groups":["liveness","readiness"]}
```

정상 응답 확인. 단, **접속 시 `https://`가 아니라 `http://`를 써야 한다** — 이 서비스는 Spring Boot의 liveness/readiness probe가 `scheme: HTTP`로 설정된 순수 HTTP 서버라, TLS 없이 8080에 떠 있다. `https://`로 접속하면 이번 장애와 무관하게 별도로 실패한다.

## 10. 배운 점

- **"같은 배포인데 결과가 다르다"는 것 자체가 강력한 단서다.** target-tracking-service의 두 replica 중 하나만 실패한 시점에, "이 앱/이미지 자체의 버그"가 아니라 "그 파드가 위치한 환경(노드) 차이"를 의심할 수 있었다. 무관해 보이는 여러 컴포넌트(kafka, target-tracking-service)가 **노드 쌍 기준으로 동일한 패턴**(크로스노드만 실패, 동일 노드는 정상)을 보인다면 공통 원인(CNI/네트워크 계층)을 우선 의심해야 한다.
- **증상만으로 원인 계층을 단정하지 않는다.** "연결 실패"라는 같은 증상도 `UnknownHostException`(DNS/이름 해석 실패)과 `Connection timeout`(경로는 있는데 응답 없음)은 서로 다른 계층의 문제를 가리킨다. 로그의 정확한 예외 종류를 구분해서 읽는 게 진단 방향을 결정했다.
- **가설은 최소 단위로 쪼개서 검증한다.** "네트워크가 이상하다"를 바로 고치려 하지 않고, 언더레이(Tailscale) → VXLAN 포트(UDP 8472) → 오버레이(파드 간 ping) → MTU 순으로 각각 독립적으로 테스트해서, 정말로 문제인 계층(flannel.1 인터페이스 부재)만 남을 때까지 좁혔다.
- **회귀(regression) 증상은 두 겹일 수 있다.** 이번 건도 "1차: 클러스터 네트워크 장애"와 "2차:애초에 임시방편(port-forward)에 의존하던 노출 방식"이 겹쳐 있었다. 1차를 고쳤다고 바로 만족하지 않고 원래 증상(포트 접속 자체)이 실제로 해소됐는지 끝까지 재현 테스트한 게 2차 문제를 놓치지 않은 이유였다.
- **GitOps(ArgoCD selfHeal) 환경에서는 "빠른 kubectl patch"가 함정이 될 수 있다.** 당장은 되는 것처럼 보여도 다음 sync 주기에 원복되기 때문에, 영구적인 변경은 반드시 소스(Git)에서 해야 한다는 걸 다시 확인.

## 11. 후속 조치 제안

- **flannel.1 인터페이스 소실 재발 감지**: 왜 server1에서만 이 인터페이스가 사라졌는지 근본 원인(k3s 프로세스 재시작 이력, OOM, 네트워크 드라이버 이슈 등)은 아직 특정하지 못했다. 재발 시 빠르게 알아채기 위해, `flannel.1` 존재 여부나 크로스노드 ping을 주기적으로 체크하는 간단한 헬스체크(cron/스크립트)를 고려.
- **외부 노출 방식 표준화**: 지금은 서비스별로 hostPort를 개별적으로 추가하는 방식인데, 노출해야 할 서비스가 늘어나면 Traefik(이미 클러스터에 설치돼 있음) 기반 Ingress/IngressRoute로 통합하는 게 포트 충돌 관리 측면에서 더 안전하다.
- **HTTP/HTTPS 접속 규칙 명확화**: 현재 이 서비스는 TLS 종료 지점이 없다. 외부에 도메인 기반으로 노출할 계획이 있다면 Traefik에서 TLS termination을 붙이는 방안도 검토 대상.
