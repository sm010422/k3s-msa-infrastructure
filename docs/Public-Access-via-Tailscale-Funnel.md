# Tailscale Funnel로 대시보드를 공인 인터넷에 노출

## 배경

`docs/Target-Tracking-Service-Fixed-Endpoint-via-Traefik-Ingress.md`에서 Traefik Ingress를 붙인 덕에, tailnet(Tailscale 사설망) 안에서는 세 노드 IP 아무거나 80번 포트로 접속하면 `target-tracking-service`가 항상 정상 라우팅되는 상태였다. 그런데 이건 **어디까지나 같은 tailnet에 속한 기기에서만** 접속 가능하다는 뜻이라, 포트폴리오 데모 URL을 다른 사람에게 공유하려면 한 단계가 더 필요했다 — 그게 Tailscale Funnel이다.

## 개념 정리 — Tailscale mesh / Serve / Funnel 세 가지는 다른 층위다

| | 접속 범위 | 용도 |
|---|---|---|
| **Tailscale mesh** (기본) | 같은 tailnet에 속한 기기끼리만 (`100.x.x.x` IP) | `kubectl`로 클러스터 접속, 노드 간 통신 등 이번 대화에서 계속 써온 것 |
| **`tailscale serve`** | mesh 안에서, 포트를 다른 포트/경로로 매핑 | tailnet 내부용 리버스 프록시 |
| **`tailscale funnel`** | **공인 인터넷 전체** | `serve`의 매핑 중 지정한 것 하나를 인터넷에도 노출 |

즉 `funnel`은 `serve` 위에 얹히는 "이 매핑 하나만 공개해도 좋다"는 명시적 오픈 아웃 스위치다. mesh 자체나 다른 서비스 포트가 통째로 열리는 게 아니라, funnel로 지정한 포트 하나만 인터넷에 노출된다.

## 실제 확인한 설정

`k3s-master` 노드(`100.103.119.1`)에 SSH로 들어가서 `tailscale funnel status`로 확인한 현재 상태:

```
$ sudo tailscale funnel status
# Funnel on:
#     - https://k3s-master.taildcdcee.ts.net

https://k3s-master.taildcdcee.ts.net (Funnel on)
|-- / proxy http://localhost:80
```

이 상태는 그 노드에서 `sudo tailscale funnel 80`을 실행하면 만들어지는 결과와 일치한다 — 로컬 80번 포트를 `https://k3s-master.taildcdcee.ts.net`(443, TLS)으로 공개 매핑한 것.

### 인증서는 어디서 나오나

`*.ts.net` 서브도메인용 인증서는 Tailscale이 Let's Encrypt를 통해 자동으로 발급·갱신한다. 별도로 도메인을 사거나 인증서를 직접 관리할 필요가 없다 — funnel을 켜는 순간 브라우저에서 정상적인 자물쇠 아이콘이 뜨는 HTTPS가 바로 작동한다.

## 요청이 실제로 흘러가는 경로

```
인터넷 (누구나)
   │  https://k3s-master.taildcdcee.ts.net
   ▼
Tailscale Funnel (k3s-master 노드의 tailscaled)
   │  TLS 종료 후 → http://localhost:80
   ▼
k3s-master의 로컬 80번 포트
   │  Traefik Service가 LoadBalancer 타입이라 k3s 내장 ServiceLB(svclb-traefik)가
   │  클러스터의 모든 노드에서 80/443을 열어둠 → k3s-master도 예외 아님
   ▼
Traefik (kube-system, Ingress Controller)
   │  apps/target-tracking-service/ingress.yaml 규칙 매칭 (Host *, path /)
   ▼
target-tracking-service ClusterIP Service (8080)
   ▼
target-tracking-service Pod → C4I 지휘통제 대시보드 응답
```

핵심은 Funnel이 **Traefik의 기존 진입점(80번 포트)에 그대로 얹힌다**는 것 — Funnel 전용으로 별도 서비스를 만든 게 아니라, 이미 클러스터 전체 노드에 열려 있던 Traefik의 80번 포트를 그대로 인터넷에 재노출한 것뿐이다. 그래서 Ingress 규칙을 새로 만들 필요도 없었다.

실제 접속 검증:

```bash
$ curl -s -o /dev/null -w "HTTP %{http_code}\n" https://k3s-master.taildcdcee.ts.net/
HTTP 200
$ curl -s https://k3s-master.taildcdcee.ts.net/ | head -c 100
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>C4I 지휘통제 대시보드</title>...
```

## 노출 범위와 한계

- **`target-tracking-service`만 노출된다.** Traefik에 등록된 Ingress 규칙이 이것 하나뿐이라, Funnel이 뚫어준 문을 지나가도 결국 Traefik이 아는 라우팅 규칙 안에서만 응답한다. `threat-intel-ai-service`, `defense-api-gateway`는 별도 Ingress가 없어 이 URL로는 접근 불가.
- **인증/인가가 없다.** Ingress·Traefik 어느 쪽에도 인증 미들웨어가 없어서, URL을 아는 사람은 누구나 대시보드에 접근 가능하다. 포트폴리오 데모 목적으로는 허용 가능한 리스크지만, 민감한 데이터가 올라가면 Traefik BasicAuth 미들웨어나 `defense-api-gateway`의 JWT 인증을 앞단에 둬야 한다.
- **`k3s-master` 노드에 종속적이다.** Funnel은 그 노드의 `tailscaled` 프로세스가 물고 있는 설정이라, 워커 노드가 아니라 마스터에서만 켜져 있다. `k3s-master`가 꺼지면 이 공개 URL도 같이 죽는다 (반면 tailnet 내부 접속은 앞 문서에서 다룬 대로 세 노드 아무 IP로나 가능해서 이 제약이 없다).
- **클러스터/GitOps 리소스로 관리되지 않는다.** 이 설정은 `k3s-msa-infrastructure` git 리포의 어떤 매니페스트에도 없다 — 노드 위에서 `tailscale funnel` CLI로 직접 켠 상태라서, 노드를 재생성하면(Multipass VM을 새로 만드는 경우 등) 이 명령을 다시 실행해야 한다. ArgoCD의 `syncPolicy.automated`가 커버하는 범위 밖이라는 점을 기억해둘 것.

## 관련 문서

- `docs/Target-Tracking-Service-Fixed-Endpoint-via-Traefik-Ingress.md` — 이 문서에서 다루는 Traefik Ingress 자체를 붙인 기록. Funnel은 그 위에 얹힌 한 겹일 뿐, 라우팅 로직 자체는 그 문서가 설명하는 것과 동일하다.
- `docs/Tailscale-Funnel-vs-Port-Forwarding.md` — Funnel이 포트포워딩과 원리적으로 어떻게 다른지, 외부인이 Tailscale 설치·로그인 없이 접속 가능한 이유를 DNS 실측으로 파고든 개념 정리
