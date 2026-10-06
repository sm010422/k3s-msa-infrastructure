# GitNexus 웹 UI 사용법 (2026-10-06)

`docs/GitNexus-Code-Intelligence-Server.md`에서 배포한 서버의 웹 UI를 실제로 눌러보면서 뭘 할 수 있는지 정리한 기록. MCP 도구 레퍼런스는 `docs/GitNexus-MCP-Tools-Reference.md` 참고 — 이 문서는 **사람이 브라우저로 직접 쓰는 법**.

## 접속

```
http://k3s-master.taildcdcee.ts.net:30747
```

**처음 한 번은 브라우저 콘솔에서 이걸 실행**해야 한다(이유는 아래 "왜 이게 필요한가" 참고):
```js
localStorage.setItem('gitnexus-backend-url', 'http://k3s-master.taildcdcee.ts.net:30747');
```
또는 이 URL로 한 번 들어가면 자동으로 저장된다:
```
http://k3s-master.taildcdcee.ts.net:30747/?server=http://k3s-master.taildcdcee.ts.net:30747
```
**한 번만 하면 된다** — 그 브라우저에 영구 저장되니 다음부턴 그냥 기본 주소로 들어가면 된다(브라우저/프로필이 다르면 다시 해야 함).

### 왜 이게 필요한가

GitNexus 번들 UI는 페이지를 로드하면 **접속한 주소와 무관하게 항상 자기 자신의 `localhost:4747`**을 찾으려고 한다(원래는 `npx gitnexus serve`로 로컬에서 띄워서 같은 컴퓨터 브라우저로 보는 걸 전제로 설계된 UI라서 그렇다). 우리처럼 서버에 올려두고 다른 기기에서 접속하면 "Waiting for server to start"에서 멈춘다. `localStorage`에 실제 서버 주소를 넣어주면 이 자동 감지를 건너뛰고 바로 연결된다.

## 화면 구성

### 1. 레포 선택 화면
처음 들어가면 인덱싱된 레포 목록이 뜬다 — 지금은 4개(`k3s-msa-infrastructure`, `target-tracking-service`, `threat-intel-ai-service`, `c4i-dashboard-frontend`). 각 카드에 파일 수/심볼 수/flow 수와 마지막 인덱싱 시각이 보인다. 클릭하면 그 레포의 그래프 화면으로 들어간다.

### 2. 좌측 — Explorer / Filters
- **Explorer**: 파일 트리. 클릭하면 우측(또는 하단) Code Inspector에 실제 소스 코드가 뜬다.
  - ⚠️ 깊게 중첩된 파일(5단계 이상)은 가끔 안 열릴 수 있다 — 업스트림 버그, `docs/GitNexus-Code-Intelligence-Server.md` 15번 항목 참고. 안 열리면 새로고침 후 재시도.
- **Filters**: 그래프에 보일 노드 타입(Folder/File/Class/Function/Method/Variable 등)과 엣지 타입(Contains 등)을 체크박스로 켜고 끌 수 있다. 노드가 너무 많아서 복잡할 때 특정 종류만 남기고 싶을 때 유용.

### 3. 중앙 — 그래프
세 가지 레이아웃을 전환할 수 있다:
- **Force Graph** (기본) — 물리 시뮬레이션 기반 자유 배치, 전체 구조를 한눈에 보기 좋음
- **Sequential Layout** — 순서가 있는 흐름을 선형으로
- **Radial Layout** — 중심에서 방사형으로

우측 상단 "Search nodes..."(⌘K)로 특정 심볼을 검색해서 그래프에서 바로 찾을 수 있다. 우측 하단에 확대/축소/전체화면 버튼.

### 4. 좌측 하단 — Query (Cypher 콘솔)
그래프 쿼리 언어(Cypher)로 직접 질의하는 패널. "Examples" 드롭다운에 템플릿이 있어서 문법을 몰라도 참고해서 쓸 수 있다. MCP의 `cypher` 도구와 같은 기능을 브라우저에서 직접 쓰는 것 — Claude Code 없이 혼자 그래프를 파헤쳐볼 때 유용하다.

### 5. 우측 상단 — "Nexus AI" 패널
클릭하면 우측에 패널이 열리고, 탭이 두 개다:

**Nexus AI 탭** — 코드베이스에 자연어로 질문하는 채팅 인터페이스("Explain the project architecture", "Find all API handlers" 같은 추천 질문 제공). **쓰려면 본인 LLM API 키를 직접 설정해야 한다**(톱니바퀴 아이콘 → AI Settings → OpenAI/Google Gemini/Anthropic/Azure OpenAI/Ollama(로컬)/OpenRouter/MiniMax/GLM/DeepSeek 중 선택 → API 키 입력). **키는 브라우저 세션 스토리지에만 저장되고 탭을 닫으면 사라진다** — 우리 서버에 전달되거나 저장되지 않는다. target-tracking-service에서 이미 Gemini를 쓰고 있으니 그 키를 재사용해도 됨.

**Processes 탭** — 인덱싱 시 자동 감지된 실행 흐름("process") 목록. `target-tracking-service`는 46개가 잡혔고, 그중 **"Swarm → GetTargetId"처럼 이번 세션에서 만든 DMZ 스웜 기능도 자동으로 하나의 흐름으로 인식**돼 있었다 — 코드를 직접 짠 사람이 아니어도 "이 기능이 어떤 단계를 거치는지"를 그래프로 바로 볼 수 있다. "Full Process Map"을 누르면 46개를 합친 전체 지도도 볼 수 있다.

### 6. 톱니바퀴 아이콘 — AI Settings
Nexus AI 채팅에 쓸 LLM을 설정하는 곳(위 참고). "Access Token" 필드는 **우리 배포랑 무관** — GitNexus 공식 Render 호스팅 배포(인증 프록시가 앞에 있는 구조)에서만 필요한 값이라 비워두면 된다.

## 할 수 없는 것 — 쓰기 작업

브라우저에서 바로는 **안 되는** 것들(`docs/GitNexus-Code-Intelligence-Server.md` 10번 항목 참고):
- 새 레포 인덱싱("OR ANALYZE NEW" 섹션의 "Analyze Repository" 버튼)
- 레포 삭제

이유: 서버가 와일드카드 바인드(`--host 0.0.0.0`)라 쓰기 라우트는 loopback(본인 컴퓨터) 접속만 허용한다. 이 작업이 필요하면:
```bash
kubectl port-forward -n tools deploy/gitnexus 4747:4747
```
띄워두고 `http://localhost:4747`로 접속하면 된다. (다만 지금은 auto-sync가 4개 레포를 30분마다 알아서 관리하고 있어서, 새 레포를 추가로 묶고 싶을 때가 아니면 이 작업을 할 일 자체가 거의 없다.)

## 관련 문서

- `docs/GitNexus-Code-Intelligence-Server.md` — 서버 배포/운영 전체 기록
- `docs/GitNexus-MCP-Tools-Reference.md` — Claude Code에서 MCP로 쓰는 법(이 문서의 웹 UI 기능 상당수가 MCP 도구로도 똑같이 가능 — `cypher`↔Cypher 콘솔, `query`/`context`↔Processes 탭)
