# 추석 정전 사건 — 복구 과정과 소프트웨어 보완 (2026-09-27)

## 배경

추석 연휴로 본가에 내려가면서 충전기 전원을 내리고 나갔다. 홈서버(물리 macOS 호스트, 그 위에서 multipass VM 3대 — `k3s-master`/`k3s-worker1`/`k3s-worker2`를 돌림)가 배터리로 계속 돌다가 방전되어 하드 다운됐다. `Remote-Wake-and-Downtime-Alerting.md`에서 다룬 "잠들어서 Tailscale에서 사라짐" 사건과는 원인이 다르다 — 이번엔 **전원 자체가 끊긴 것**이라 그 문서의 caffeinate/Amphetamine 대책(잠들지 않게 하기)은 이 케이스에 적용되지 않는다.

## 복구 과정

### 1. 물리 호스트 특정

Tailscale에 `k3s-master`/`k3s-worker1`/`k3s-worker2`가 각자 별도 피어로 잡혀 있어서(각 VM이 자체 Tailscale 클라이언트를 가짐) 처음엔 그쪽으로 바로 SSH를 시도했으나 호스트 키 미스매치로 실패 — 이 세 피어는 Tailscale SSH(자체 데몬이 sshd 역할)를 쓰고 있어서 일반 `ssh`가 아니라 `tailscale ssh`로 붙어야 했는데, tailnet 정책(ACL)이 이 계정으로의 SSH를 막고 있어서 이 경로도 실패했다.

실제로 붙어야 하는 곳은 VM들이 올라가 있는 **물리 macOS 호스트**(`tailscale status`에서 `macbookair`, `100.112.104.24`)였다 — `ssh sangmin@100.112.104.24`로 접속.

```bash
tailscale status                     # macbookair(물리 호스트) IP 확인
ssh sangmin@100.112.104.24           # 물리 호스트에 직접 접속
```

### 2. multipass/k3s 상태 확인

물리 호스트에서 `multipass`가 PATH에 없어서(비대화형 ssh 셸이라 `.zprofile` 미로드) 풀패스(`/usr/local/bin/multipass`)로 호출해야 했다.

```bash
/usr/local/bin/multipass list
```

**결과: VM 3대 모두 `Running`.** multipass의 launchd 데몬이 호스트 부팅 시 VM을 자동 기동하도록 이미 구성돼 있어서, 전원이 복구되고 macOS가 재부팅되자 별도 조치 없이 VM들이 스스로 다시 떴다.

```bash
multipass exec k3s-master -- sudo k3s kubectl get nodes -o wide     # 3대 모두 Ready
multipass exec k3s-master -- sudo k3s kubectl get pods -A -o wide   # 전 파드 Running, RESTARTS 1회(재부팅 시점과 일치)
multipass exec k3s-master -- sudo k3s kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
  # target-tracking-service / threat-intel-ai-service 둘 다 Synced/Healthy
```

k3s, ArgoCD, 앱 파드까지 **전부 스스로 복구되어 있었다** — systemd/launchd 기반 자동 기동 체인이 정전 이후 재부팅에도 그대로 먹혔다는 뜻.

### 3. 유일하게 스스로 복구되지 않은 것: threat-intel-ai-service의 Kafka consumer

외부 헬스체크 엔드포인트를 직접 두드려서 최종 확인하는 중 발견:

```bash
curl -s https://k3s-master.taildcdcee.ts.net/ai/health
# {"status":"ok","ai_enabled":true,"rerank_enabled":false,"qdrant_connected":true,"kafka_consumer_running":false}
```

`kafka_consumer_running: false` — Kafka 파드 자체는 `Running`인데, AI 서비스의 컨슈머만 안 붙어 있었다. 로그 확인:

```bash
kubectl logs -n c4i deploy/threat-intel-ai-service --since=6h | grep -iE 'kafka|error'
# ERROR:aiokafka:Unable connect to "kafka-service.c4i.svc.cluster.local:9092": [Errno 111] Connection refused
```

**원인**: 정전 후 재부팅 시 모든 파드가 동시에 재시작되면서, `threat-intel-ai-service`가 Kafka 브로커보다 먼저 뜨는 경쟁이 발생했다. `app/kafka/consumer.py`의 `run_consumer()`는 `consumer.start()`가 실패하면 **재시도 없이 그냥 죽는** 구조였다 — 최초 1회 연결 실패 = 그 프로세스가 살아있는 동안 영구 다운. 4시간 넘게 이 상태로 떠 있었지만 `/health`가 항상 `200 OK`를 반환하는 바디 구조라(상태값은 JSON 필드일 뿐 HTTP 코드에 반영 안 됨) 기존 `livenessProbe`도 이걸 못 잡았다.

**즉시 복구**: 수동으로 롤아웃 재시작해서 Kafka가 이미 떠 있는 지금은 정상 연결됨.

```bash
kubectl rollout restart deploy/threat-intel-ai-service -n c4i
kubectl rollout status deploy/threat-intel-ai-service -n c4i --timeout=90s
curl -s https://k3s-master.taildcdcee.ts.net/ai/health
# {"status":"ok", ..., "kafka_consumer_running":true}   ✅
```

## 소프트웨어 보완 — 재시도 로직 추가 (완료, 배포됨)

`threat-intel-ai-service` 커밋 `209ea27` (`main`에 push, CI가 이미지 빌드 → ArgoCD Image Updater가 자동 반영):

`app/kafka/consumer.py`의 `run_consumer()`를 `while True` 재시도 루프로 감싸서, `consumer.start()`가 실패하면 5초 후 재시도하도록 고쳤다. 마찬가지로 `async for` 루프 자체가 죽는 예외(연결이 끊기는 경우 등)도 잡아서 재시도한다 — `asyncio.CancelledError`(앱 종료 시 정상 취소)만 그대로 올려보낸다.

```python
while True:
    consumer = AIOKafkaConsumer(...)
    try:
        await consumer.start()
    except Exception:
        logger.exception("Kafka consumer failed to connect, retrying in %ss", _RETRY_BACKOFF_SECONDS)
        await asyncio.sleep(_RETRY_BACKOFF_SECONDS)
        continue
    is_running = True
    try:
        async for message in consumer:
            ...
    except asyncio.CancelledError:
        raise
    except Exception:
        logger.exception("Kafka consumer loop crashed, restarting in %ss", _RETRY_BACKOFF_SECONDS)
        await asyncio.sleep(_RETRY_BACKOFF_SECONDS)
    finally:
        is_running = False
        await consumer.stop()
```

이제 다음에 똑같이 전체 재부팅으로 브로커-기동-순서 경쟁이 나도, 사람이 `rollout restart`를 안 해도 5초 뒤 알아서 다시 붙는다. `tests/test_kafka_consumer.py`에서 최초 연결 실패 → 재시도 → `is_running=True` 회복 시나리오를 가짜 컨슈머로 재현해서 검증(pytest-asyncio 없이 `asyncio.run()` + 태스크 취소 패턴으로 작성, 기존 스위트가 전부 동기 테스트라 새 의존성 추가를 피했다).

## 확인했지만 지금 당장 안 건드린 것

- **`livenessProbe`가 `kafka_consumer_running`을 못 잡는 문제**: `/health`는 상태와 무관하게 항상 `200 OK`를 반환하는 구조라, 저 필드가 `false`로 몇 시간이 지나도 k8s가 자동으로 재시작해주지 않는다. 이번 근본 원인(재시도 로직 부재)은 고쳤지만, "컨슈머가 어떤 이유로든 계속 못 붙는" 다른 미래의 버그 클래스에 대한 방어선은 여전히 없다는 뜻이다. liveness probe가 이 필드를 검사하도록 바꾸면 방어가 한 겹 더 생기지만, 운영 중인 프로덕션 probe의 실패 시맨틱을 바꾸는 거라(재시도 백오프 중에도 오탐 안 나게 `failureThreshold`/`periodSeconds` 재조정 필요) 별도로 검토하는 게 맞다고 보고 지금은 안 건드렸다.
- **배터리 방전 자체를 막거나 조기 경보하는 것**: 이번 원인은 "충전기를 뽑고 나감"이라 애초에 소프트웨어로 막을 수 있는 종류가 아니다(Amphetamine/caffeinate는 절전 방지일 뿐 배터리 소모를 안 막음). 배터리가 임계치 이하로 떨어지면서 아직 방전 전에 ntfy로 조기 경보를 보내는 건 가능은 하지만(`pmset -g batt`를 launchd로 주기 폴링), 이번 요청 범위(재발생한 다운을 복구 + 재발한 버그를 소프트웨어로 고치기) 밖이라 별도 논의 필요 시 진행.

## 결론

정전으로 인한 하드 다운은 multipass/k3s/ArgoCD 자동 기동 체인 덕에 **거의 전부 스스로 복구됐고**, 유일하게 안 됐던 지점(threat-intel-ai-service Kafka consumer)은 원인을 찾아 근본 수정까지 배포했다. 다음에 같은 정전이 나도 이 특정 실패는 재발하지 않는다.
