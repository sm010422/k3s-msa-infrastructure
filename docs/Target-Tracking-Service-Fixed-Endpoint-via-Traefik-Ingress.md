# target-tracking-service 접속 IP가 재배포마다 바뀌던 문제 — Traefik Ingress로 해결

## 증상

`target-tracking-service`가 재배포(파드 재스케줄링)될 때마다 접속해야 하는 주소가 바뀌었다. 특정 시점엔 `http://100.106.186.41:8080/`(server1의 Tailscale IP)로 접속됐지만, 파드가 server2나 server3로 옮겨가면 그 주소는 죽고 새로 뜬 노드의 IP로 다시 찾아가야 했다.

사용자는 이걸 nginx로 리버스 프록시를 직접 구성해서 해결해야 하는 문제로 알고 있었다.

## 원인

`apps/target-tracking-service/deployment.yaml`의 컨테이너 포트 설정에 `hostPort: 8080`이 박혀 있었다.

```yaml
ports:
  - containerPort: 8080
    hostPort: 8080   # 문제의 원인
```

`hostPort`는 컨테이너 포트를 **파드가 스케줄된 그 노드의 네트워크 인터페이스에 직접 바인딩**한다. 파드가 다른 노드로 재스케줄되면 바인딩되는 노드도 바뀌므로, 사용자가 접속하던 IP가 "그 순간 우연히 파드가 떠 있던 노드의 IP"였을 뿐 고정 엔드포인트가 아니었다.

한편 `target-tracking-service`라는 `ClusterIP` 타입 Service(`10.43.136.211:8080`)는 이미 존재했고, 이건 파드가 어디로 옮겨가든 최신 파드 IP를 자동으로 추적해준다. 즉 **클러스터 내부에서는 이미 문제가 없었고, 외부에서 접속할 고정 진입점이 없는 것**이 진짜 문제였다.

## nginx 대신 Traefik을 쓴 이유

k3s에는 Traefik이 기본 인그레스 컨트롤러로 이미 떠 있는 상태였다 (`kubectl get ingressclass` → `traefik` 등록 확인, `ingressroutes.traefik.io` 등 Traefik CRD도 이미 설치돼 있음).

결정적으로, Traefik의 Service는 `LoadBalancer` 타입으로 k3s 내장 서비스LB(klipper-lb, `svclb-traefik` 파드)를 통해 노출되는데, 이 `svclb-traefik`은 **DaemonSet으로 클러스터의 모든 노드에 떠서 각 노드의 80/443 포트를 열어준다**:

```
traefik   LoadBalancer   10.43.165.200   100.106.186.41,100.116.194.42,100.92.119.127   80:30592/TCP,443:30637/TCP
```

즉 Traefik 자체가 실제로 어느 노드에서 실행 중이든, **세 노드 IP 어디로 접속해도 80/443이 항상 열려 있고 정상적으로 라우팅된다.** 이 구조가 이미 "노드가 바뀌어도 고정 IP로 접속 가능"이라는 요구사항을 그대로 만족시키므로, nginx로 별도 리버스 프록시를 구성하는 건 이미 있는 기능을 중복 구현하는 것과 같았다.

## 적용한 변경

1. **`apps/target-tracking-service/deployment.yaml`** — `hostPort: 8080` 제거. 컨테이너를 특정 노드에 묶지 않게 함.
2. **`apps/target-tracking-service/ingress.yaml`** (신규) — 기존 ClusterIP Service로 라우팅하는 표준 `Ingress` 추가.

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: target-tracking-service
     namespace: c4i
   spec:
     ingressClassName: traefik
     rules:
       - http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: target-tracking-service
                   port:
                     number: 8080
   ```

3. **`apps/target-tracking-service/kustomization.yaml`** — `resources`에 `ingress.yaml` 등록.

Traefik이 지원하는 `IngressRoute` CRD 대신 표준 `networking.k8s.io/v1 Ingress`를 쓴 이유는, 이 리포의 기존 리소스들이 전부 표준 k8s 리소스(Deployment/Service/ConfigMap)로만 구성돼 있어서 Traefik 전용 CRD를 새로 끌어들이지 않는 쪽이 일관성에 맞기 때문이다.

## 검증

`kubectl kustomize apps/target-tracking-service`로 빌드 결과에 `hostPort`가 사라지고 `Ingress` 리소스가 정상 포함되는 것을 확인했다.

## 결과

이 리포는 ArgoCD `syncPolicy.automated: {prune: true, selfHeal: true}`로 연결돼 있으므로, 커밋을 push하면 별도 `kubectl apply` 없이 자동 반영된다. 이후로는 파드가 어느 노드에 있든 세 노드 IP(`100.106.186.41` / `100.116.194.42` / `100.92.119.127`) 중 아무거나 **80번 포트**로 접속하면 항상 현재 파드로 정상 라우팅된다.
