# Tailscale Funnel의 동작 원리 — 포트포워딩과 뭐가 다른가

`docs/Public-Access-via-Tailscale-Funnel.md`에서 Funnel로 `target-tracking-service`를 공개한 사실 자체는 정리했는데, "그래서 외부 사람이 Tailscale 설치도 로그인도 없이 어떻게 우리집 서버에 붙는 거지?"라는 원리 자체가 헷갈려서 별도로 파고든 기록. 결론: **포트포워딩처럼 우리집 공유기에 구멍을 뚫는 게 아니라, Tailscale이 운영하는 공개 서버가 중계해준다.**

## 1. 결정적 증거 — Funnel URL이 실제로 가리키는 IP

`k3s-master.taildcdcee.ts.net`을 세 군데에서 각각 조회해보면 전부 다른 답이 나온다.

```bash
# ① 이 맥(tailnet 멤버)에서 조회 — MagicDNS가 사설 IP로 바로 답해줌
$ dig +short k3s-master.taildcdcee.ts.net
100.103.119.1                      # Tailscale 사설망(tailnet) 안에서만 유효한 IP

# ② 우리집 인터넷의 실제 공인 IP (포트포워딩이었다면 외부에 이게 노출돼야 함)
$ curl -s ifconfig.me
124.80.125.211

# ③ 진짜 외부인이 보는 것과 동일하게, 공용 DNS(구글/클라우드플레어)에 직접 질의
$ dig +short k3s-master.taildcdcee.ts.net @8.8.8.8
103.84.155.153
103.84.155.217
```

①은 이 기기가 Tailscale에 로그인돼 있어서 MagicDNS가 지름길로 사설 IP를 바로 알려준 것 — 외부인은 이 경로를 못 탄다. ③이 진짜 외부인이 보는 값인데, ②(우리집 공인 IP)도 아니고 ①(우리집 사설 tailnet IP)도 아닌 **제3의 IP 대역**이 나온다. 이게 **Tailscale이 직접 운영하는 Funnel 공개 엔드포인트**다 — 즉 외부에서 이 URL로 접속하면 우리집 네트워크 근처에도 안 가고, Tailscale의 인프라로 먼저 들어간다.

## 2. 두 방식의 근본적인 차이 — "누가 연결을 먼저 여는가"

### 포트포워딩
```
외부 클라이언트 ──(인바운드 TCP 연결)──▶ 우리집 공유기(공인 IP:포트) ──NAT──▶ 내부 서버
```
공유기가 **바깥에서 들어오는 연결을 직접 받아서** 내부로 꽂아주는 구조. 그래서:
- 진짜 공인 IP가 있어야 함 — 요즘 통신사는 CGNAT(여러 가구가 공인 IP 하나를 공유)을 쓰는 경우가 많아서, 애초에 포트포워딩이 불가능한 회선도 흔하다
- 공유기 관리자 설정 접근 권한이 필요
- 그 포트가 인터넷에 그대로 노출돼서, 전 세계에서 24시간 돌아가는 포트스캔 봇의 스캔 대상이 됨
- 공인 IP가 유동IP면 바뀔 때마다 접속 주소도 바뀜 (DDNS로 보완 가능하지만 별도 설정)

### Tailscale Funnel
```
k3s-master ──(아웃바운드 연결을 미리 맺어둠)──▶ Tailscale 공개 서버(103.84.x.x)
외부 클라이언트 ──(그냥 평범한 HTTPS)──▶ Tailscale 공개 서버 ──(그 터널로 릴레이)──▶ k3s-master
```
k3s-master는 **인바운드 포트를 여는 게 아니라, 밖으로 나가는 연결만** 미리 맺어둔다. 아웃바운드 연결은 거의 모든 공유기/방화벽이 기본 허용하므로, 공유기 설정을 하나도 안 건드려도 된다. 실제로 TCP 연결을 받는 주체는 Tailscale의 공개 서버이고, 거기서부터 우리집 노드까지는 이미 인증된 WireGuard 터널로 릴레이된다. 그 결과:
- 우리집 공인 IP(`124.80.125.211`)는 위 ③ 실험에서 보듯 **외부에 아예 노출되지 않는다**
- CGNAT 환경이든 뭐든 상관없이 동작한다 (아웃바운드만 되면 됨)
- TLS 인증서는 Tailscale이 `*.ts.net`용으로 Let's Encrypt를 통해 자동 발급/갱신 — 직접 관리할 필요 없음

## 3. "외부인은 왜 Tailscale 설치·로그인이 필요 없나"

가장 헷갈렸던 지점. 답은 **외부인이 tailnet 안으로 들어오는 게 아니기 때문**이다.

Tailscale의 통신 방식은 사실 두 층위로 나뉜다.

| 층위 | 접속 주체 | Tailscale 계정 필요? | 이번 대화에서의 예시 |
|---|---|---|---|
| **tailnet mesh** (`100.x.x.x` IP로 접속) | 같은 계정에 로그인된 기기끼리 | **필요** | `server1@100.103.119.1`로 SSH 접속한 것 |
| **Funnel URL** (`https://*.ts.net`) | 아무나 | **불필요** | `curl https://k3s-master.taildcdcee.ts.net/` |

Funnel URL은 브라우저 입장에서 그냥 평범한 공인 웹사이트일 뿐이다 — Tailscale 클라이언트가 설치돼 있는지조차 상대는 알 필요가 없다. tailnet 안으로 외부인을 "초대"하는 게 아니라, **우리 노드가 Tailscale의 공개 인프라를 빌려서 서비스 하나만 일반 웹사이트처럼 대신 내보내주는 것**이 Funnel의 정체다. mesh 자체의 인증/권한 체계와는 완전히 분리된 별개의 경로.

## 4. 노출 범위는 그대로 노드 하나 + 포트 슬롯 3개로 제한됨

Funnel이라고 전체가 뚫리는 게 아니라는 것도 실측으로 확인했다.

```bash
# k3s-worker1, k3s-worker2는 Funnel을 켠 적이 없어서
$ tailscale funnel status   # (각 워커 노드에서)
No serve config
```

Funnel/Serve 설정은 클러스터나 계정 단위가 아니라 **각 노드의 `tailscaled`가 로컬로 들고 있는 상태**라, `k3s-master`에서만 켰다면 딱 그 노드만 공개된다. 게다가 그 안에서도 `tailscale funnel --help` 기준으로 공개 가능한 포트 슬롯은 **443 / 8443 / 10000 세 개로 고정**돼 있고, 임의 포트(예: 22)를 그대로 공개 슬롯에 노출할 수는 없다 — 지금은 443 슬롯 하나(`localhost:80`, target-tracking-service)만 쓰는 중이고 나머지 두 슬롯은 비어 있다.

```bash
$ sudo tailscale funnel status
https://k3s-master.taildcdcee.ts.net (Funnel on)
|-- / proxy http://localhost:80
```

포트 22(SSH)는 이 목록에 없으므로 인터넷에서 SSH로 접속하는 건 불가능하다 — sshd가 `0.0.0.0:22`로 리스닝 중인 건 맞지만, 그건 tailnet mesh 안에서만 유효한 바인딩이고 Funnel이 별도로 뚫어주지 않는 한 공인 인터넷과는 무관하다.

## 5. 요약

| | 포트포워딩 | Tailscale Funnel |
|---|---|---|
| 연결을 먼저 여는 쪽 | 공유기 (인바운드 허용) | 우리 서버 (아웃바운드만) |
| 공인 IP 필요 | 필요, CGNAT이면 불가 | 불필요 |
| 공유기 설정 | 필요 | 불필요 |
| 우리집 IP 노출 | 그대로 노출 | 노출 안 됨 (Tailscale IP로 대체) — DNS 실측으로 확인 |
| TLS 인증서 | 직접 관리 | Tailscale이 자동 관리 |
| 외부 접속자가 설치할 것 | 없음 | 없음 (둘 다 그냥 HTTPS/TCP) |
| 노출 범위 | 지정 포트가 그대로 스캔 대상 | Tailscale 인프라 뒤에 숨음, 노드별로 최대 3개 포트 슬롯(443/8443/10000)만 |
| 적용 단위 | 공유기 전체 정책 | 노드 단위 (`tailscaled` 로컬 상태), 다른 노드엔 영향 없음 |

## 관련 문서

- `docs/Public-Access-via-Tailscale-Funnel.md` — 지금 이 클러스터에 실제로 적용된 Funnel 설정과 요청 경로(Funnel → Traefik → Ingress → target-tracking-service)
