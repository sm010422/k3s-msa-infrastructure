# Graphify 지식 그래프 구축 기록 (2026-10-06)

이 레포 전체(99개 파일 — 코드 4, 문서 93, 이미지/SVG 2)를 `graphify`로 돌려서 `graphify-out/`에 지식 그래프를 만든 과정과, 중간에 터진 레이트리밋 이슈를 어떻게 처리했는지 기록.

## 왜 했나

레포에 `docs/`가 90개 넘게 쌓여 있고 k8s 매니페스트도 여러 서비스에 흩어져 있어서, "이 서비스가 뭘 참조하는지" 같은 질문에 매번 grep으로 뒤지는 대신 쿼리 가능한 그래프를 만들어두는 게 낫겠다 싶었음. `.claude/CLAUDE.md`에 graphify 사용 규칙이 이미 박혀있던 것도 계기.

## 파이프라인 개요

1. **Detect** — 99개 파일 분류 (code 4 / document 93 / image 2, ~60,476 words). 500파일·200만 단어 임계값에 한참 못 미쳐서 narrowing 없이 바로 진행.
2. **구조적 추출 (AST)** — 코드 4개 파일 → 33 노드, 45 엣지. API 키 없이 무료로 끝남.
3. **시맨틱 추출 (LLM)** — `GEMINI_API_KEY`/`GOOGLE_API_KEY` 둘 다 없어서, Gemini 대신 호스트 에이전트(Claude Code) 자신이 서브에이전트 7개를 병렬로 띄워서 처리. 95개 파일(문서 93 + SVG 다이어그램 2)을 디렉터리 단위로 묶어 7개 청크로 분할:
   - 청크 1: 워크플로/README/gitnexus 매니페스트 (10파일)
   - 청크 2: 모니터링 스택 (19파일)
   - 청크 3: target-tracking/threat-intel 서비스 + argocd (21파일)
   - 청크 4: docs/ 상당수 (22파일) — **아래 참고, 끝까지 못 끝남**
   - 청크 5: docs/ 나머지 + concepts/ (21파일)
   - 청크 6, 7: 아키텍처 다이어그램 SVG 2개 (각 1파일, vision 처리 때문에 단독 청크)

## 청크 4에서 터진 레이트리밋

청크 4(가장 큰 배치, 22개 docs)를 처리하던 서브에이전트가 `rate_limit` 429 에러로 중간에 죽음 (세션 한도, 오후 3시 KST 리셋 예정). 재시도했지만 16분을 넘게 돌고도 끝나지 않아서, 사용자 판단으로 **재시도를 중단하고 청크 4는 그대로 비워둔 채 나머지 6개 청크로 파이프라인을 계속 진행**하기로 함.

graphify의 매니페스트 로직(`_stamped_manifest_files`)이 정확히 이런 상황을 위해 설계돼 있음: 시맨틱 추출 결과가 없는 파일은 `manifest.json`에 "완료"로 찍히지 않고 그대로 남아서, 나중에 `graphify . --update`를 돌리면 **그 22개 파일만 자동으로 다시 추출 대상에 잡힘**. 별도 조치 없이 그냥 재실행하면 됨.

## 최종 결과

- **그래프**: 318 노드, 369 엣지, 43개 커뮤니티 (6개 청크 분량 — 282 시맨틱 노드 + 33 AST 노드)
- **헬스체크**: undirected 그래프 기준으로 8개 엣지가 병합(collapse)됨 — 치명적이진 않지만 기록. 댕글링/누락 엣지는 0개.
- **God Nodes 상위**: `Monitoring Stack Kustomization`(18 edges), `Deployment: target-tracking-service`(11), `Deployment: threat-intel-ai-service`(11), `K3s MSA Infrastructure README`(8), `gitnexus Deployment`(8)
- **Surprising Connections**: Image Updater가 target-tracking-service와 threat-intel-ai-service 양쪽 ArgoCD 이미지 핀을 동시에 가지고 있는 것, `gateway-secrets(jwt-secret)`와 `GITNEXUS_MCP_AUTH_TOKEN`이 "route-scoped bearer-secret 인증" 패턴으로 시맨틱 유사도가 잡힌 것 등.
- **토큰 사용**: 이번 런에서 출력 토큰만 813,389 (입력은 서브에이전트 호출 방식이라 0으로 집계 — Agent tool의 usage에서 input/output 분리값을 못 받아서 output에 합쳐 기록).
- **벤치마크**: 15,900 단어 코퍼스 기준 쿼리당 평균 ~19.9배 토큰 절감.

## 커밋한 것 / 안 한 것

`graphify-out/`에서 실제 그래프 산출물만 커밋:
- `graph.json`, `graph.html`, `GRAPH_REPORT.md`, `manifest.json`, `cost.json`, `.graphify_labels.json`

머신 전용 파일은 `.gitignore`에 추가하고 제외:
- `.graphify_python`, `.graphify_root` — 로컬 절대경로가 박혀있어서 다른 머신/CI에서 의미 없음
- `cache/` — 재실행 가속용 로컬 캐시, 커밋 안 해도 재생성됨

## 다음에 할 일

- `graphify . --update` 한 번 더 돌려서 청크 4의 22개 docs 파일 마무리 (`manifest.json`에 unstamped로 남아있어서 자동으로 재큐잉됨)
- 레이트리밋이 다시 걸릴 걸 감안하면, 오후 피크 시간대를 피해서 돌리는 게 안전
