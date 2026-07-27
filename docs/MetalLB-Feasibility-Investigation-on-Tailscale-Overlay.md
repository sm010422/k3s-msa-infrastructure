# MetalLB 도입 타당성 조사 — 왜 klipper-lb(ServiceLB)를 그대로 유지하기로 했나

## 배경 — 뭘 하려고 했나

k3s 기본 내장 LoadBalancer 구현체인 ServiceLB(klipper-lb)를 MetalLB로 교체해서, "진짜 가상 IP(VIP) 할당 + 노드 장애 시 자동 failover"를 구현하려 했다. 계획은 다음과 같았다.

1. 현재 상태(svclb 파드, LoadBalancer 서비스, 리소스 사용량) 스냅샷
2. ServiceLB 비활성화
3. MetalLB 설치
4. IP 풀 + `L2Advertisement` 설정 (Tailscale 오버레이 환경에서 실제로 동작하는지 검증)
5. 기존 서비스 재검증, failover 테스트
6. 교체 전후 리소스 사용량 비교

**실제로는 1단계 진단만 하고 멈췄다.** 진단 과정에서 이 클러스터의 네트워크 토폴로지가 MetalLB의 두 동작 모드(L2/BGP) 어느 쪽과도 근본적으로 안 맞는다는 게 드러났고, "안 되는 걸 굳이 실증만 하기 위해 되돌리기 어려운 변경(ServiceLB 비활성화)까지 진행하는 것"보다 "왜 안 맞는지 규명하고 현재 구성을 유지하는 근거를 남기는 것"이 더 가치 있다고 판단해 여기서 멈췄다.

## 1. 진단 — 교체 전 상태

```bash
$ kubectl get pods -n kube-system | grep svclb
svclb-traefik-fa6196ab-42gvf   2/2   Running   k3s-worker1
svclb-traefik-fa6196ab-xgslk   2/2   Running   k3s-worker2
svclb-traefik-fa6196ab-z2j5p   2/2   Running   k3s-master

$ kubectl get svc -A | grep LoadBalancer
kube-system   traefik   LoadBalancer   10.43.253.202   100.103.119.1,100.122.146.63,100.83.49.100   80:31503/TCP,443:30352/TCP
```

LoadBalancer 타입 서비스는 Traefik 하나뿐이고, EXTERNAL-IP가 **세 노드의 Tailscale IP 전부**로 찍혀 있다 — klipper-lb는 노드마다 파드를 하나씩 띄워서 각 노드의 지정 포트를 hostPort로 열어두는 방식이라(자세한 내부 동작은 `docs/Tailscale-Funnel-vs-Port-Forwarding.md`의 NodePort/iptables 설명 참고), 세 IP 중 아무거나로 접속해도 다 된다.

```bash
$ kubectl top nodes
NAME          CPU     MEM
k3s-master    194m/9%   1269Mi/42%
k3s-worker1    84m/8%    769Mi/52%
k3s-worker2   132m/13%  1151Mi/67%

$ kubectl top pods -n kube-system | grep svclb
svclb-traefik-fa6196ab-42gvf   0m   0Mi
svclb-traefik-fa6196ab-xgslk   0m   0Mi
svclb-traefik-fa6196ab-z2j5p   0m   0Mi
```

svclb 파드 3개가 CPU/메모리를 사실상 전혀 안 쓴다. 이유는 이미 다른 조사에서 확인한 바 있다 — klipper-lb는 실제 프록시 프로세스가 아니라 **iptables DNAT 규칙만 심어두는 셸 스크립트**라서(`docs/Tailscale-Funnel-vs-Port-Forwarding.md` 참고), 상시 실행되는 워크로드가 없다. MetalLB의 `speaker`/`controller`는 실제 Go 프로세스로 BGP/ARP 처리와 리더 election을 수행하므로, 구조적으로 klipper-lb보다 더 많은 리소스를 쓸 수밖에 없다 — 이 시점에서 이미 "리소스 대비 효용"에 물음표가 붙는다.

## 2. 결정적 문제 — 노드 네트워크 인터페이스 실측

`kubectl debug node/<노드>`로 각 노드의 네트워크 네임스페이스를 직접 들여다봤다 (SSH 없이, 호스트 네임스페이스에 컨테이너를 붙이는 방식).

```
세 노드 공통 인터페이스 구성:
  enp0s1      192.168.252.x/24   <BROADCAST,MULTICAST,UP,LOWER_UP>
  cni0        10.42.N.1/24       (Flannel CNI 브리지, 노드별 파드 대역)
  tailscale0  100.x.x.x/32       <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
  flannel.1   10.42.N.0/32       (VXLAN 오버레이)
```

| 노드 | enp0s1 | tailscale0 |
|---|---|---|
| k3s-master | 192.168.252.2/24 | 100.103.119.1/32 |
| k3s-worker1 | 192.168.252.3/24 | 100.122.146.63/32 |
| k3s-worker2 | 192.168.252.4/24 | 100.83.49.100/32 |

### 2.1 `tailscale0`는 애초에 ARP를 지원하지 않는다

핵심은 `tailscale0` 인터페이스 플래그에 박혀 있는 **`NOARP`**다. 이건 "설정을 잘못해서 ARP가 안 되는" 상태가 아니라, **커널이 그 인터페이스에서 ARP 프로토콜 자체를 취급하지 않는다고 선언해둔 것**이다. Tailscale의 `tailscale0`는 WireGuard 기반의 point-to-point L3 터널 인터페이스라서 원래 ARP가 필요 없다 — 상대 피어를 MAC 주소가 아니라 이미 암호학적으로 확정된 키/라우팅으로 찾아가기 때문이다.

MetalLB의 L2 모드(`L2Advertisement`)는 "이 IP는 내가 담당한다"를 **ARP(IPv4) / NDP(IPv6) 응답**으로 네트워크에 광고하는 방식으로 동작한다. `tailscale0`가 ARP를 지원하지 않으므로, **이 인터페이스를 대상으로 L2Advertisement를 걸면 MetalLB의 speaker가 ARP 응답을 보낼 방법 자체가 없다** — 설정을 아무리 다르게 해도 커널 인터페이스 속성이 막고 있어서, 별도로 트래픽을 흘려 실증할 필요도 없이 결론이 나는 문제다.

### 2.2 진짜 L2 세그먼트(enp0s1)는 있지만, 실제 클라이언트가 못 쓴다

ARP가 정상 동작하는 진짜 L2 브로드캐스트 세그먼트는 `enp0s1`(`192.168.252.0/24`)이다 — 세 노드가 전부 이 대역에 물려 있어서 기술적으로는 여기에 MetalLB L2Advertisement를 걸 수 있다.

문제는 이 `192.168.252.0/24`가 **Multipass가 이 세 VM을 호스팅하는 물리 macOS 머신(macbookair, Tailscale IP `100.112.104.24`) 안에서만 유효한 사설 가상 네트워크**라는 것이다 (`docs/Multipass-Operations-Guide.md`에서 이미 "호스트에 먼저 SSH로 들어간 다음에만 `multipass shell` 사용 가능"이라고 정리된 것과 같은 제약). 반면 이 클러스터에 실제로 붙는 모든 경로 — 다른 맥에서의 `kubectl` 접속, Tailscale Funnel로 들어오는 공인 인터넷 트래픽(`docs/Public-Access-via-Tailscale-Funnel.md`) — 는 전부 Tailscale(`100.x.x.x`)이나 그 바깥의 공인 인터넷을 거친다. `192.168.252.0/24`를 거치는 경로가 하나도 없다.

**결론**: `enp0s1`에 L2Advertisement를 걸면 MetalLB가 기술적으로는 정상 동작해서 `192.168.252.x` 대역의 VIP를 할당하겠지만, 그 VIP는 Multipass 호스트 밖의 그 누구도(다른 기기, Tailscale Funnel 사용자) 접근할 수 없다. **동작은 하되 목적(장애 시에도 실제 클라이언트가 접근 가능한 고정 진입점)을 달성 못 하는 결과**다.

### 2.3 BGP 모드도, VRRP(keepalived) 대안도 마찬가지

- **MetalLB BGP 모드**: 물리/가상 네트워크 어느 쪽에도 BGP를 말하는 라우터가 없다 (가정용 공유기는 BGP 라우터가 아님). 애초에 상대할 피어가 없어서 불가능.
- **keepalived(VRRP) 같은 대안**: VRRP도 멀티캐스트/L2 브로드캐스트에 의존하는 프로토콜이라, `tailscale0`에서는 2.1과 완전히 동일한 이유(NOARP·L3 전용 인터페이스)로 막힌다. `enp0s1`에 건다 해도 2.2와 동일하게 Multipass 내부망에 갇힌 VIP가 될 뿐이다. 즉 "MetalLB 대신 다른 온프레미스 LB 도구를 쓰면 되지 않을까"라는 질문에도 이 토폴로지에서는 근본적으로 같은 답이 나온다.

## 3. 그래서 지금 구성(klipper-lb)이 오히려 이 토폴로지에 맞는 답이었다

klipper-lb가 하는 일은 "가상 IP 하나를 여러 노드가 나눠 갖는 것"이 아니라, **NodePort를 세 노드 전부에 열어두고, 어느 IP로 들어오든 kube-proxy가 실제 파드가 떠 있는 곳으로 다시 라우팅**하는 것이다 (`docs/Tailscale-Funnel-vs-Port-Forwarding.md`의 iptables DNAT 체인 설명 참고). 그 결과:

- 노드 하나가 죽어도, 살아있는 나머지 두 노드의 Tailscale IP는 여전히 정상 응답한다 (그 IP로 들어온 트래픽이 kube-proxy를 거쳐 살아있는 파드로 라우팅되므로) — **단일 VIP의 자동 failover는 아니지만, "N개 중 아무 IP나 접속 가능"이라는 실질적으로 동등한 가용성**을 이미 제공하고 있다.
- 이 구조는 Tailscale이 이미 제공하는 IP 체계(각 노드의 고정 `100.x.x.x` 주소) 위에서 그대로 동작하므로, ARP/BGP 같은 L2/L3 라우팅 프로토콜에 전혀 의존하지 않는다 — 애초에 Tailscale 오버레이와 상성이 맞는 방식이었던 것.
- 리소스도 사실상 0에 수렴한다 (1절 참고).

MetalLB가 주려는 가치("클라이언트가 IP 하나만 알면 되고, 그 IP가 항상 살아있는 노드를 가리킨다")는 **물리 L2 네트워크 위에서 홈랩을 구성했을 때** 의미가 있는 모델이다. 이 클러스터처럼 접근 경로 자체가 처음부터 Tailscale 오버레이(L3, 노드별 개별 IP가 이미 안정적으로 고정된 환경)인 경우엔, MetalLB가 해결하려는 문제가 애초에 다른 방식(노드별 고정 IP + kube-proxy 라우팅)으로 이미 해소돼 있었다.

## 4. 결정

- ServiceLB(klipper-lb)를 그대로 유지한다. MetalLB로 교체하지 않는다.
- 만약 이 클러스터가 나중에 **진짜 물리 L2 네트워크**(가정용 공유기 하나에 물리 서버들을 유선으로 직접 묶는 구성 등, Tailscale 오버레이가 아닌 환경)로 바뀐다면, 그때는 이 문서의 2.1/2.2에서 막혔던 전제 자체가 사라지므로 MetalLB L2 모드를 재검토할 가치가 있다.

## 5. 회고 — 왜 이 판단 과정 자체가 남길 가치가 있는가

"온프레미스에 LB 붙이기"라는 작업을 받았을 때, 레퍼런스 문서대로 설치 명령어부터 따라 치기 전에 **먼저 이 네트워크가 그 도구의 전제 조건(L2 브로드캐스트 도달성)을 만족하는지 인터페이스 플래그 수준에서 확인**했다. 그 결과 "설치는 되지만 목적을 달성 못 하는" 조합이라는 걸 되돌리기 어려운 변경(ServiceLB 비활성화) 전에 미리 걸러냈다 — 실제로 되돌리기 어려운 단계까지 가서 실패를 겪고 되돌리는 것보다, 진단 단계에서 근거를 가지고 "이 도구는 안 맞는다"고 판단해 멈추는 쪽이 훨씬 저렴하다.

## 관련 문서

- `docs/Tailscale-Funnel-vs-Port-Forwarding.md` — klipper-lb/NodePort의 iptables DNAT 동작 원리
- `docs/Public-Access-via-Tailscale-Funnel.md` — 이 클러스터의 실제 외부 접근 경로 (Tailscale Funnel)
- `docs/Multipass-Operations-Guide.md` — `192.168.252.0/24`가 왜 Multipass 호스트 내부 전용인지의 배경
