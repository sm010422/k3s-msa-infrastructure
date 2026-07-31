# VMware Fusion vs Multipass — 실측 기반 장단점 비교

`docs/VMware-to-Multipass-Cluster-Migration.md`에서 진행한 마이그레이션 과정에서 실제로 관찰한 사실을 바탕으로 정리. 마이그레이션 착수 전 예상했던 것과, 실제로 겪고 나서 확인된 것을 구분해서 기록한다.

## 1. 결론부터

| | 예상(착수 전) | 실측(마이그레이션 후) |
|---|---|---|
| 하이퍼바이저 교체 자체의 메모리 절감 | "있긴 한데 크지 않을 것" | **예상보다 확실히 체감됨** — 아래 3절 참고 |
| 가장 큰 이득의 원천 | VM 스펙 재설계(5.6GB→6GB는 사실 큰 차이 아님) | 재설계보다 **런타임 안정성**(스왑 미사용, DiskPressure 외 메모리 압박 없음) 쪽이 더 크게 체감됨 |
| 운영 편의성 | Multipass가 CLI라 더 가벼울 것 | 가볍긴 하지만 **VMware가 가진 GUI 콘솔/스냅샷 부재가 실제 트러블슈팅에서 아쉬웠음** |

## 2. Multipass의 장점

### 2.1 하이퍼바이저 오버헤드가 실제로 낮다

같은 "합계 메모리 할당"(구성 기준 VMware 5.6GB vs Multipass 6GB, 큰 차이 없음)인데도 결과가 다르다.

- **VMware 운영 중**: `memory_pressure` 기준 호스트 여유 메모리 260MB, `top`에서 `vmware-vmx` 프로세스 3개가 압축 메모리(CMPRS)로 각각 3975M/2619M/2513M을 잡아먹고 있었음 — VM 자체 메모리 외에 하이퍼바이저가 소모하는 관리 오버헤드가 상당했다.
- **Multipass 운영 중**: 동일 8GB 호스트에서 워커 노드 available 535~674Mi, swap 사용량 268Ki~8.6Mi(사실상 미사용) — 스왑까지 갈 일 없이 여유 있게 돌아갔다.

이건 예상한 "체감상 수백MB 차이" 수준을 넘어서는 결과였다. Apple Silicon 네이티브 `Virtualization.framework`가 SVGA 3D 에뮬레이션, VMware Tools 데몬, 체크포인트 관리 같은 걸 아예 안 하기 때문으로 보인다.

### 2.2 CLI 자동화가 훨씬 쉽다

`multipass launch/exec/transfer/stop/start/set` 만으로 VM 생성부터 파일 전달, 리소스 조정까지 전부 스크립트화 가능했다. VMware는 `vmrun`으로 start/stop 정도는 되지만, 게스트 내부 조작은 결국 SSH에 의존해야 했다.

### 2.3 디스크/메모리 증설이 명령 한 줄

`multipass set local.<vm>.disk=14G` 로 디스크를 늘릴 수 있었다 (VM 정지 필요). VMware도 `vmware-vdiskmanager`로 가능은 하지만 파티션/파일시스템까지 직접 늘려야 해서 번거롭다.

## 3. Multipass의 단점 / 실제로 겪은 문제

### 3.1 디스크 온라인 리사이즈 불가 — 실제 장애 유발

Multipass는 **VM이 정지된 상태에서만** 디스크를 늘릴 수 있다. 마이그레이션 중 워커 디스크를 6GB로 잡았다가 ArgoCD 이미지 pull 도중 `no space left on device`로 실패했고, `DiskPressure` 컨디션까지 발생해 파드가 무더기로 멈췄다. VM을 내렸다 올리는 과정에서 진행 중이던 파드들이 `ContainerStatusUnknown`으로 붕 떠서 수동 정리가 필요했다.

→ **교훈**: 처음부터 이미지 pull 용량까지 감안해서 여유 있게 잡아야 한다. VMware는 실행 중에도(스냅샷 없이) 확장 가능한 경우가 많아 이 부분은 VMware가 더 유연했다.

### 3.2 이미지 캐시 손상 이슈

`multipass launch 24.04`가 첫 시도에서 `Hash of .../ubuntu-24.04-server-cloudimg-arm64.img does not match ...` 에러로 실패했다. 캐시된 이미지가 손상돼 있었던 것으로 보이며, 재시도하니 자동 재다운로드되어 해결됐다. VMware는 이런 이미지 캐시 계층이 없어(직접 ISO/OVA를 다루므로) 이 종류의 실패 자체가 존재하지 않는다.

### 3.3 SSH 접속 경험이 기본적으로 다르다

VMware VM은 게스트 OS를 설치할 때 정한 계정/비밀번호로 바로 `ssh server1@<ip>` 접속이 됐다. Multipass는:

- 기본 계정이 `ubuntu`이고, Multipass 자체 관리 키로 `multipass exec/shell`만 지원 — 호스트를 거치지 않고 다른 기기에서 곧장 SSH 붙는 걸 기본으로 지원하지 않는다.
- Ubuntu cloud image 기본값이 `PasswordAuthentication no`라, 비밀번호 로그인을 켜려면 `/etc/ssh/sshd_config.d/`에 별도 override 파일을 추가해야 한다 (그것도 `Include`되는 다른 conf 파일보다 알파벳순으로 먼저 와야 우선 적용됨 — sshd는 "첫 번째 값이 우선" 규칙).

→ 이번에 `server1/server2/server3` 계정을 새로 만들고 `PasswordAuthentication yes`를 강제로 override해서 예전과 동일한 `ssh server1@<ip>` 접속 경험을 복원했다 (VM 이름은 k3s-master/worker1/worker2로 유지, **로그인 계정명만 server1/2/3으로 매핑**). 참고로 `tailscale up --ssh`를 켜뒀기 때문에, 같은 tailnet에 속한 신뢰된 기기에서는 비밀번호 없이도 Tailscale SSH로 접속이 가능하다 — 다만 이번엔 사용자가 익숙한 예전 워크플로우(비밀번호 기반)를 우선해서 병행 설정했다.

### 3.4 GUI 콘솔 부재

VMware Fusion은 부팅 실패, 네트워크 미기동 등 SSH조차 안 붙는 상황에서 콘솔 GUI로 직접 화면을 볼 수 있다. Multipass는 기본적으로 headless라 이런 저수준 디버깅이 어렵다 (다행히 이번 마이그레이션에서는 이 상황까지는 가지 않았다).

### 3.5 스냅샷/체크포인트 부재

VMware Fusion은 스냅샷으로 특정 시점 롤백이 가능하다 (Multipass도 최근 버전에 스냅샷 기능이 생기긴 했으나 VMware만큼 성숙하지 않음). 이번엔 GitOps로 상태 대부분이 git에 있어 크게 아쉽지 않았지만, `target-tracking-secrets`처럼 git 밖에 있는 상태는 스냅샷이 없으면 결국 수동 백업에 의존할 수밖에 없다는 걸 이번에 체감했다 (`docs/VMware-to-Multipass-Cluster-Migration.md` 5.5절 참고).

## 4. VMware의 장점 (그럼에도 남아있는 이유)

- **GUI 콘솔**: 위 3.4절. 저수준 장애 디버깅에 유리.
- **스냅샷**: 위 3.5절. 실험적 변경 전 롤백 지점 확보가 쉬움.
- **범용성**: Windows/Linux/기타 OS를 가리지 않고 폭넓게 지원 (Multipass는 Ubuntu/리눅스 계열에 최적화).
- **온라인 디스크 확장**: 위 3.1절. 실행 중에도 유연하게 조정 가능한 경우가 많음.

이런 이유로 이번 마이그레이션에서도 기존 VMware VM 3대는 **삭제하지 않고 정상 종료 상태로 보존**했다 — 언제든 다시 켜서 GUI 콘솔이 필요한 디버깅이나 롤백 용도로 쓸 수 있게.

## 5. 종합 판단

이 프로젝트(8GB RAM 제약이 있는 온프레미스 홈랩)에서는 Multipass 쪽이 명백히 더 적합했다:

- 메모리 오버헤드가 실측으로 확인될 만큼 낮았고,
- CLI 자동화 덕분에 노드 3대를 스크립트로 재현 가능한 상태로 만들 수 있었고,
- 부족한 부분(SSH 접속 경험, 디스크 온라인 리사이즈, GUI 콘솔)은 대부분 설정으로 우회하거나(3.3절) 애초에 GitOps 구조 덕분에 크게 아쉽지 않았다(3.5절).

다만 "회사/프로덕션" 맥락이라면 VMware의 스냅샷·GUI 콘솔·다양한 OS 지원이 여전히 더 중요한 시나리오가 있을 수 있다는 점은 유효하다. 이번 판단은 어디까지나 **개인 홈랩 + Apple Silicon + 8GB RAM + Ubuntu 전용**이라는 조건에서 내려진 것이다.
