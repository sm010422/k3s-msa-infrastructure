# threat-intel-ai-service — 비용/리소스 실측 기록

`threat-intel-ai-service`를 자체 호스팅 k3s 클러스터에 얹은 뒤 "이거 계속 켜놔도 되나(리소스든 비용이든)"를 확인한 기록. 결론부터: **Gemini API가 유일한 변동비 구성요소이고, 상시 백그라운드 루프가 없어서 방치해도 비용/리소스가 누적되지 않는 구조**다.

## 1. 이번에 추가된 것 중 실제로 돈이 나갈 수 있는 항목 점검

| 구성요소 | 비용 여부 | 근거 |
|---|---|---|
| Gemini API (chat + embedding) | **유일한 변동비** | 사용량 기반. 아래 2절에서 실측 |
| Docker Hub (`sm010422/threat-intel-ai-service`) | 무료 | public 리포 — 저장 용량/pull 횟수 제한 없음 |
| GitHub Actions (`threat-intel-ai-service` 리포) | 무료 | **public 리포는 Actions 실행 시간이 완전 무료(무제한)**. private였다면 계정당 월 무료 한도 초과 시 과금 |
| GitHub 리포 호스팅 | 무료 | public |
| k3s 클러스터, Qdrant, Kafka | 무료(자체 호스팅) | 전부 본인 하드웨어(Multipass VM) 위에서 구동. 클라우드 청구서 없음, 전기세만 |

`target-tracking-service`용으로 이미 있던 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`과 별개로 이 리포용 시크릿을 새로 등록했지만(GitHub 시크릿은 리포 단위로 격리되어 공유 안 됨), 계정 자체는 동일해서 추가 가입/과금 없음.

## 2. Gemini API 실사용량 — Kafka consumer가 얼마나 호출했나

가장 걱정되는 지점은 Kafka consumer가 이벤트를 받을 때마다 임베딩 API를 호출한다는 것이었다. 실제로 몇 번이나 호출됐는지 Kafka 브로커에 직접 물어봤다.

```bash
kubectl exec -n c4i <kafka-pod> -- kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 --topic target-tracking
# target-tracking:0:30

kubectl exec -n c4i <kafka-pod> -- kafka-consumer-groups \
  --bootstrap-server localhost:9092 --describe --group threat-intel-ai-service
# CURRENT-OFFSET=30  LOG-END-OFFSET=30  LAG=0
```

토픽에 지금까지 쌓인 메시지가 총 30개, 우리 서비스가 30개 다 소비해서 lag 0(더 처리할 게 없어 idle) — **지금까지의 임베딩 API 호출은 총 30번**이다.

### 2.1 왜 30개뿐이고, 앞으로도 폭증할 걱정이 없는지

메시지 발행 주체인 `target-tracking-service`의 `DroneSimulator.simulate(int rounds)`를 직접 열어봤다:

```java
// API 호출로만 실행됨 (SimulatorController). rounds 회만큼 드론 3대 위치를 생성해 Kafka에 발행하고 종료.
public void simulate(int rounds) {
    for (int i = 0; i < rounds; i++) {
        DRONE_IDS.forEach(droneId -> { ... targetProducer.send(event); });
    }
}
```

`@Scheduled`가 아니라 **컨트롤러 API를 호출해야만 실행되는 일회성 메서드**다. 즉 아무도 시뮬레이터 API를 안 건드리면 Kafka에 새 메시지 자체가 안 생기고, `threat-intel-ai-service`의 consumer도 소비할 게 없어 그냥 대기 상태로 남는다. **상시로 이벤트를 찍어내며 Gemini를 계속 호출하는 백그라운드 루프는 이 시스템 어디에도 없다.**

`/chat`, `/ingest/doc`도 마찬가지로 요청이 와야만 Gemini를 호출하는 구조(`app/routers/chat.py`, `app/routers/ingest.py`)라, 이 서비스를 켜놓기만 하고 아무도 안 쓰면 Gemini 호출은 0에 수렴한다.

## 3. Pod 리소스 사용량 — 실제로 얼마나 쓰고 있나

```bash
kubectl top pods -n c4i -l 'app in (threat-intel-ai-service,threat-intel-qdrant)'
```

| Pod | CPU 사용 / limit | 메모리 사용 / limit | RESTARTS |
|---|---|---|---|
| threat-intel-ai-service | 6m / 300m (2%) | 138Mi / 384Mi (36%) | 0 |
| threat-intel-qdrant | 2m / 300m (1%) | 25Mi / 384Mi (7%) | 0 |

배포 직후(문서/이력 몇 건만 색인된 상태) 기준으로는 거의 idle 수준이고, 둘 다 재시작 없이 안정적으로 떠 있다. `docs/Threat-Intel-AI-Service-K3s-Deployment.md`에서 다룬 대로 `k3s-worker2`에 배치했는데, worker2의 기존 여유(memory request 15%만 사용 중)를 생각하면 이 정도 추가는 전혀 부담이 안 된다.

`/health` 엔드포인트가 k8s liveness/readiness probe에 의해 10~15초 간격으로 계속 호출되는 게 로그에 찍히는데, 이건 Qdrant 연결 상태만 확인하는 저비용 로컬 호출이라 Gemini 사용량과는 무관하다 — "로그에 뭔가 계속 찍힌다"는 것과 "돈이 나간다"는 것은 이 서비스에서는 별개다.

## 4. 결론

- 이번에 추가한 것 중 유료 리스크는 Gemini API 하나뿐이고, 나머지(Docker Hub, GitHub Actions, 클러스터 자체)는 public 리포 + 자체 호스팅 조합이라 구조적으로 무료.
- Gemini 호출은 "누가 실제로 액션을 취했을 때"만 발생하는 이벤트 기반 구조라, 배포된 채로 방치해도 사용량이 스스로 누적되지 않는다.
- Pod 리소스도 idle에 가까운 수준(limit 대비 CPU 1~2%, 메모리 7~36%)이라 클러스터에 부담을 주지 않는다.
- 다만 이건 "지금까지의" 실측이라는 한계가 있다 — 시뮬레이터를 대량으로 돌리거나 `/chat`을 반복 호출하는 시나리오에서는 당연히 그만큼 Gemini 호출이 늘어난다. 이 문서는 "저절로 계속 늘어나는 구조는 아니다"를 확인한 것이지, "얼마를 써도 무료"라는 뜻은 아니다.
