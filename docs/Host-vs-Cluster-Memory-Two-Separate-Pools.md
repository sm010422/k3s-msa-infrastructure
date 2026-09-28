# 호스트 메모리 vs 클러스터(VM) 메모리 — 서로 다른 풀이라는 정정 (2026-09-28)

## 배경

`Lightweight-Prometheus-Grafana-Monitoring.md` 초안에 "`Headless-Migration-Amphetamine-to-Caffeinate.md`로 확보한 메모리 여유를 활용해서 Prometheus/Grafana를 올렸다"고 썼는데, 사용자가 "저번엔 메모리가 전혀 없었는데 어떻게 갑자기 생겼냐"고 물어본 걸 계기로 다시 짚어보니 **틀린 인과관계**였다. 이 문서는 그 정정 내용을 남긴다.

## 결론부터 — 이 컴퓨터엔 메모리 풀이 두 개다

<table fit-page-width="true" header-row="true">
<tr><td>풀</td><td>정체</td><td>오늘 한 일</td><td>영향 범위</td></tr>
<tr><td>호스트(macOS) 메모리</td><td>물리 랩탑 자체의 RAM. macOS + 그 위에서 도는 모든 것(Finder, Spotlight, 3개의 qemu-system-aarch64 프로세스 등)이 공유</td><td>Spotlight 인덱싱 끄기, 개인용 앱(Magnet/Hammerspoon/WakaTime/Logi Options+) 종료, GUI 세션 로그아웃(헤드리스 전환)</td><td>랩탑 자체의 안정성(스왑 위험, 정전 재발 시 회복력 등)</td></tr>
<tr><td>k3s VM(게스트) 메모리</td><td>multipass가 각 VM에 **고정 할당**한 크기 — master 3G, worker1 1.5G, worker2 1.75G. `kubectl top nodes`가 보는 게 이쪽</td><td>(오늘은 안 건드림 — 예전에 worker2만 1.5G→1.75G로 늘린 적 있음, `Host-Memory-Reclamation-for-Multipass-VMs.md`)</td><td>실제로 파드가 쓸 수 있는 메모리</td></tr>
</table>

**핵심**: multipass VM은 진짜 컴퓨터 한 대처럼 동작한다. 호스트에 RAM이 얼마나 남아있든, VM 내부에서 보는 "총 메모리"는 `multipass set local.<vm>.memory=...`로 명시적으로 바꾸지 않는 한 절대 안 바뀐다. 호스트 쪽 정리는 그 VM들을 돌리는 QEMU 프로세스 자체가 호스트 메모리 압박으로 스와핑당할 위험을 줄여주는 것뿐이지, 게스트 안의 가용 메모리를 늘려주는 게 아니다.

## 그럼 Prometheus/Grafana는 어디서 자리를 찾았나

배포 시점 `kubectl top nodes` 기준, VM 고정 할당량 안에서 원래 있던 여유였다:

<table fit-page-width="true" header-row="true">
<tr><td>노드</td><td>고정 할당</td><td>당시 사용중</td><td>여유(=새 자리)</td><td>왜 여유가 있었나</td></tr>
<tr><td>worker1</td><td>1.4GB</td><td>807Mi (55%)</td><td>~630Mi</td><td>postgres(가벼움)+redis(가벼움)+target-tracking-service만 배치됨</td></tr>
<tr><td>worker2</td><td>1.7GB</td><td>1142Mi (67%)</td><td>~560Mi</td><td>kafka+qdrant+threat-intel-ai-service까지 몰려서 항상 더 빡빡함</td></tr>
</table>

**"저번엔 메모리가 전혀 없었다"는 기억은 아마 `worker2` 기준**일 것이다 — `Host-Memory-Reclamation-for-Multipass-VMs.md`에서 이 노드가 535Mi까지 빡빡해져서 호스트 쪽 회수분(256Mi)을 VM 할당량 자체에 반영(1.5G→1.75G)해준 적이 있다. `worker1`은 그때도, 지금도 상대적으로 한산했다. Prometheus/Grafana를 배치할 때 `nodeAffinity`/`podAntiAffinity`로 일부러 더 빡빡한 worker2를 피하고 worker1에 앉혔기 때문에, 오늘 호스트에서 확보한 메모리와는 무관하게 원래 있던 공간에 들어간 것이다.

## 두 풀이 실제로 연결되는 유일한 경로

호스트 메모리 회수분을 VM에 실제로 반영하려면, `Host-Memory-Reclamation-for-Multipass-VMs.md`에서 했던 것처럼 **명시적으로** 이 과정을 거쳐야 한다:

```bash
multipass stop <vm-name>
multipass set local.<vm-name>.memory=<새 크기>
multipass start <vm-name>
```

이걸 안 하면(오늘처럼) 호스트에서 아무리 회수해도 VM들의 메모리 할당량은 그대로다. 두 풀은 이 한 가지 수동 조작으로만 이어진다.
