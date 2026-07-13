# 개념 정리 — 클러스터 네트워크 원리 & 디버깅 방법론

배포 마지막 단계에서 postgres pod가 계속 `Pending`이었고, 원인을 찾아가는 과정 자체가 "쿠버네티스 네트워킹이 실제로 어떻게 동작하는지"를 배울 수 있는 좋은 사례라 따로 정리.

## 1. ClusterIP는 실체가 없는 "가상 IP"다

`kubectl get svc`를 치면 각 Service마다 IP가 하나씩 있다(예: `10.43.21.196`). 이게 어떤 서버의 진짜 IP가 아니라는 게 핵심이다. **ClusterIP는 어느 노드에도 실제로 존재하지 않는 가상 주소**고, 클러스터의 모든 노드에서 동작하는 `kube-proxy`가 iptables(또는 IPVS) 규칙으로 "이 가상 IP로 온 패킷은 실제 파드 IP 중 하나로 바꿔치기해서 보내라"는 규칙을 심어놓는다.

그래서 `postgres-service:5432`로 접속한다는 건 실제로는:
1. DNS가 `postgres-service.c4i.svc.cluster.local`을 ClusterIP(`10.43.x.x`)로 풀어주고
2. 그 IP로 나가는 패킷을 커널의 iptables 규칙이 가로채서 실제 postgres 파드의 IP(`10.42.x.x`)로 목적지를 바꿔치기(DNAT)한다

**즉 ClusterIP 통신이 되려면 DNS와 kube-proxy(iptables) 둘 다 정상이어야 한다.** 이번에 겪은 문제는 이 두 계층 모두에서 증상이 나왔다.

## 2. CoreDNS — 서비스 이름을 IP로 바꿔주는 것

파드 안에서 `nslookup postgres-service`가 되는 이유는 모든 파드의 `/etc/resolv.conf`가 기본적으로 클러스터 내부 DNS 서버(CoreDNS, 이것도 결국 Service+ClusterIP로 떠 있다)를 가리키도록 kubelet이 자동 설정해주기 때문이다. 이번에 앱 로그에 찍힌:

```
Caused by: java.net.UnknownHostException: postgres-service.c4i.svc.cluster.local
```

이건 "postgres 파드가 아직 안 떠서 연결이 거부됐다"(그럼 `Connection refused`가 났을 것)가 아니라 **이름 자체를 못 찾았다**는 뜻이다. Service는 이미 만들어져 있었으니 DNS 레코드 자체는 있어야 하는데 못 찾았다는 건, CoreDNS에게 가는 경로(이것도 ClusterIP)가 막혀 있었다는 신호다.

## 3. 증상을 계층별로 좁혀나간 순서

문제를 마주쳤을 때 실제로 밟은 순서 (위에서 아래로 갈수록 더 근본적인 계층):

```
1. kubectl get pods -n c4i          → postgres만 Pending, 나머지는 Running
2. kubectl describe pod postgres    → Events 비어있음 (스케줄링 문제 아님을 확인)
3. kubectl get pvc                  → Pending, "waiting for first consumer"
4. kubectl describe pvc             → "ExternalProvisioning ... verify provisioner is running"
5. kubectl logs local-path-provisioner → "dial tcp 10.43.0.1:443: no route to host"
                                        (10.43.0.1 = 쿠버네티스 API 서버 ClusterIP!)
```

동시에 별개 경로로:
```
1. ArgoCD Application sync status → Unknown
2. kubectl describe application    → "dial tcp 10.43.21.196:8081: i/o timeout" (repo-server)
3. controller 로그 상세               → 진짜 실패 지점은 argocd-redis(10.43.241.26:6379) 캐시 저장
```

그리고 앱 pod 로그:
```
UnknownHostException: postgres-service.c4i.svc.cluster.local
```

**세 가지 완전히 다른 컴포넌트**(local-path-provisioner, argocd-application-controller, 우리 Spring Boot 앱)에서 **똑같은 패턴**(ClusterIP 대상 연결/조회 실패)이 나왔다. 이게 "개별 컴포넌트를 하나씩 고친다"가 아니라 "공통 원인을 의심한다"로 방향을 트는 근거였다. 만약 postgres pod만 문제였다면 postgres 매니페스트를 계속 의심했겠지만, 서로 무관한 세 시스템이 동시에 같은 방식으로 실패한다는 건 그 세 시스템이 공유하는 더 아래 계층(kube-proxy/CNI)이 원인일 확률이 훨씬 높다.

## 4. 왜 "일단 재시작해보자"를 함부로 하면 안 되는가

`argocd-redis` pod를 재시작해서 문제가 해결되는지 시도했다(사용자 승인 후). 이건 **가설을 검증하는 실험**이었다: "혹시 이 특정 pod의 스터크(stuck)된 커넥션 상태 때문인가?"를 확인하려는 목적. 재시작 후 다른 노드에서 새 pod가 떴는데도 동일 증상이 재현됐다는 결과 자체가 유의미한 정보였다 — **"pod 자체 문제가 아니다"를 반증**함으로써 원인을 kube-proxy/CNI 레벨로 더 좁힐 수 있었다.

반대로 공유 컨트롤플레인 컴포넌트(이번 세션에서 내가 만들지 않은 리소스)를 함부로 재시작/삭제하는 건 다른 워크로드에 영향을 줄 수 있는 조치라, 실행 전에 반드시 "왜 이걸 하려는지, 데이터 유실 위험이 있는지"를 명확히 하고 승인을 구하는 게 맞다. 이번엔 "캐시 전용이라 데이터 유실 없음"이라는 걸 먼저 확인하고 진행했다.

## 5. 이 문제를 나중에 직접 진단한다면 확인할 순서

1. **kube-proxy 자체가 살아있는지**: `kubectl get pods -n kube-system -l k8s-app=kube-proxy` (k3s는 기본적으로 kube-proxy 대신 자체 구현을 쓸 수도 있어서, `k3s` 프로세스 자체의 상태도 같이 봐야 할 수 있음)
2. **CNI(플러그인) 상태**: `kubectl get pods -n kube-system` 전체에서 flannel/CNI 관련 pod가 재시작 반복(CrashLoopBackOff)하고 있는지 — `k3s-cni-crashloop-troubleshooting.md`에 이미 기록된 것과 같은 패턴인지 대조
3. **노드 간 raw 연결성**: 문제가 특정 노드 쌍(예: server1 ↔ server3)에서만 나는지, 전체적으로 나는지 — `kubectl get pods -o wide`로 어느 노드에 뭐가 떠 있는지 보고, 같은 노드끼리는 되는데 다른 노드로 넘어가면 안 되는 패턴인지 확인
4. **iptables 규칙이 실제로 존재하는지**: 문제가 nftables/iptables 모드 불일치, 혹은 규칙이 아예 안 심어지는 버그일 수도 있음 — 노드에 직접 접속해서 `iptables-save | grep <ClusterIP>` 확인

지금 상태(2026-07-13 기준)에서는 여기까지 진단하지 않고 멈췄다 — 다음 세션에서 이어서 진단할 부분.
