# GitHub → Notion 문서 동기화 자동화

`k3s-msa-infrastructure`, `target-tracking-service`, `threat-intel-ai-service` 세 리포의 `docs/**.md`를 Notion으로 옮기고, 이후로는 문서가 바뀔 때마다 자동으로 Notion도 갱신되게 만든 기록.

## 1. 배경 — 왜 필요했나

세 리포에 쌓인 `docs/` 문서 48개를 Claude Code(Notion 커넥터)로 한 번에 Notion에 옮겼다. 문제는 그다음이었다 — "앞으로 문서를 추가할 때마다 Notion도 같이 최신 상태로 유지되게 하고 싶다"는 요구였는데, Claude Code 세션 안에서 "문서 추가해줘"라고 부탁할 때만 Notion을 같이 갱신하는 방식은 **커밋이 다른 경로로 일어나면(예: 직접 `git push`, 나중에 팀원이 추가) 무력화된다.** 그래서 "누가 어떤 방식으로 커밋하든" 항상 동작하는, git push 자체를 트리거로 삼는 자동화(GitHub Actions)로 만들기로 했다.

## 2. 전체 흐름

```
docs/**.md 변경 → git push (main)
        │
        ▼
GitHub Actions: Notion Doc Sync
        │
        ├─ 이전 커밋과 diff해서 바뀐 .md 파일 목록 추출
        ├─ 매핑 파일(.notion-sync-map.json)에 있으면 → 그 Notion 페이지 내용 통째 교체
        ├─ 매핑에 없는 새 파일이면 → 적절한 부모 페이지 아래 새 페이지 생성 후 매핑에 추가
        └─ 매핑 파일이 바뀌었으면 → 그 변경분을 [skip ci]로 다시 커밋 + push
```

## 3. Notion 쪽 준비 — Internal Integration

Notion API로 페이지를 읽고 쓰려면 [notion.so/my-integrations](https://www.notion.so/my-integrations)에서 **Internal Integration**을 만들고 토큰(secret)을 발급받아야 한다. 발급받은 것만으로는 아무 페이지에도 접근이 안 되고, **연결하려는 페이지 쪽에서 그 integration을 명시적으로 "Connections"에 추가**해야 한다.

이번엔 `k3s-doc-sync`라는 이름으로 만들고, 최상위 페이지("Defense C4I 인프라 문서") 하나에만 연결했다 — Notion의 페이지 공유/연결은 하위 페이지로 상속되므로, 그 아래 리포별 페이지·`concepts` 하위 페이지까지 전부 별도 연결 없이 같은 integration으로 접근 가능하다.

## 4. 리포별 파일 ↔ Notion 페이지 매핑

각 리포 루트에 `.notion-sync-map.json`을 커밋해서 "이 로컬 파일 경로가 이 Notion 페이지 ID에 대응한다"를 기록한다.

```json
{
  "docs/architecture.md": "3e250b17-ecd1-810d-8cfe-f275b601a630",
  "docs/concepts/13-reranker.md": "3e250b17-ecd1-81fa-b5fd-ce15f1b48170"
}
```

최초 49개 페이지(48개 문서 + 마이그레이션 문서 하나가 분량 때문에 2페이지로 쪼개진 것 1개 추가)의 ID는 Claude Code의 Notion 커넥터로 각 부모 페이지를 순회 조회(`fetch`)해서 자식 페이지 목록을 뽑아 수작업으로 매핑했다. 이후로는 스크립트가 새 페이지를 만들 때마다 이 파일에 자동으로 추가한다.

**분량 때문에 페이지를 둘로 쪼갰던 문서**(`VMware-to-Multipass-Cluster-Migration.md` → 1/2, 2/2)는 매핑에 1/2 페이지만 등록해뒀다 — 원본 파일이 하나뿐이라 앞으로 그 파일이 바뀌면 1/2 페이지만 갱신되고 2/2 페이지는 그대로 남는다(고아 페이지). Claude Code로 옮길 때는 대화 단위 분량 제한 때문에 나눈 것이었지 Notion API 자체의 제약은 아니라서, 자동화 스크립트는 애초에 파일 하나당 페이지 하나로만 다룬다.

## 5. 동기화 스크립트 설계

Node.js + Notion 공식 SDK(`@notionhq/client`) + 마크다운→Notion 블록 변환 라이브러리(`@tryfabric/martian`, GFM 표·코드블록·목록을 Notion 블록으로 변환)로 짰다. 저장 위치는 프로젝트 루트가 아니라 `.github/scripts/notion-sync/`에 별도 `package.json`을 뒀다 — 이 세 리포는 각각 YAML/Java/Python 프로젝트라, Node 의존성을 리포 루트에 섞으면 기존 빌드 도구(Gradle, pip 등)와 무관한 잡동사니가 생긴다. Node 모듈 해석은 스크립트 파일 위치부터 상위로 찾아 올라가므로, `.github/scripts/notion-sync/` 안에서만 `npm install`해도 그 스크립트를 실행할 땐 정상적으로 잡힌다.

### 5.1 "페이지 내용 교체"가 없어서 지우고 다시 쓴다

Notion API에는 "이 페이지 내용을 통째로 이걸로 바꿔라" 같은 단일 엔드포인트가 없다. 그래서 기존 페이지를 갱신할 땐 `blocks.children.list`로 현재 자식 블록을 전부 가져와 `blocks.children.delete`로 지운 뒤, 새로 변환한 블록을 `blocks.children.append`로 다시 채우는 2단계로 구현했다. `append`는 한 번에 최대 100개 블록만 받아서, 문서가 길면 90개씩 나눠서 여러 번 호출한다.

### 5.2 어떤 파일이 바뀌었는지 판별

```js
const base = process.env.GITHUB_EVENT_BEFORE; // 이 push 직전 커밋 SHA
execSync(`git diff --name-status ${base} HEAD -- "docs/**/*.md"`);
```

GitHub Actions의 `push` 이벤트가 주는 `github.event.before`를 기준으로 diff를 떠서, 그 push에 실제로 포함된 `docs/**.md` 변경분만 골라낸다. 이 값이 없거나(수동 트리거 등) 커밋이 로컬에 없는 상황(얕은 클론)이면 `HEAD~1`로 폴백한다.

### 5.3 새 파일 → 새 페이지, 부모는 경로로 결정

```js
NOTION_DEFAULT_PARENTS = {
  "docs/concepts/": "<concepts 하위 페이지 ID>",
  "docs/": "<리포 루트 페이지 ID>"
}
```

매핑에 없는 파일이면 이 표에서 **가장 긴 접두사가 일치하는** 부모 페이지 아래 새로 만든다 — `docs/concepts/`가 `docs/`보다 더 구체적인 경로라 먼저 매치되도록 길이 기준으로 정렬해서 찾는다. 이렇게 하면 `docs/foo.md`는 리포 루트 페이지에, `docs/concepts/14-bar.md`는 concepts 하위 페이지에 자동으로 들어간다.

### 5.4 삭제된 파일은 건드리지 않는다

`git diff --name-status`가 `D`(삭제)로 표시한 파일은 스크립트가 그냥 건너뛴다 — Notion 페이지를 자동으로 지우는 건 되돌리기 어려운 조치라, 지금은 "매핑에는 남겨두고 Notion 페이지도 그대로 둔다"를 기본 정책으로 잡았다. 나중에 그 경로의 파일이 다시 생기면 같은 페이지가 갱신 대상으로 재사용된다. 문서를 완전히 지우고 싶으면 당분간은 Notion에서 수동으로 지워야 한다.

### 5.5 매핑 파일 자체의 변경을 다시 커밋

새 페이지가 생겨서 `.notion-sync-map.json`이 바뀌면, 워크플로우 안에서 그 변경분을 `notion-doc-sync` 봇 이름으로 커밋하고 `git push`까지 한다. 커밋 메시지에 `[skip ci]`를 붙여서 이 커밋 자체가 다시 워크플로우를 트리거하는 무한 루프를 막았다. 이 커밋이 다시 push를 만들기 때문에 `concurrency: group: notion-doc-sync, cancel-in-progress: false`로 같은 그룹의 실행이 겹치지 않고 순서대로 처리되게 했다.

## 6. GitHub Secret 등록

```bash
gh secret set NOTION_TOKEN --repo sm010422/k3s-msa-infrastructure
gh secret set NOTION_TOKEN --repo sm010422/target-tracking-service
gh secret set NOTION_TOKEN --repo sm010422/threat-intel-ai-service
```

`gh secret set`을 인자 없이 실행하면 터미널이 값을 프롬프트로 입력받아 GitHub API로 바로 암호화 전송한다 — 토큰 값이 대화나 커맨드 히스토리에 남지 않는 경로를 의도적으로 골랐다 (ArgoCD Image Updater 문서에서 Docker Hub 토큰을 등록할 때 썼던 것과 같은 패턴).

등록 과정에서 실제로 겪은 문제: `--repo`를 두 번째·세 번째 리포에 입력할 때 `—repo`(하이픈 두 개가 아니라 긴 대시 한 글자)로 잘못 들어가서 `accepts at most 1 arg(s)` 에러가 났다. macOS 터미널 앱의 "스마트 대시" 자동 변환이 원인 — 하이픈을 다시 명시적으로 입력해서 해결했다.

## 7. 마이그레이션 중 발견한 별개의 버그 — 페이지 제목 인코딩 깨짐

48개 문서를 옮기는 과정에서 일부 페이지 제목에 원래 글자 대신 유니코드 코드포인트 숫자가 그대로 박히는 현상이 있었다 (`아키텍처` → `아키텍cc98`, `쿠버네티스` → `쉼버네티스`, `옆에` → `옷에`). `처`(U+CC98)처럼 유니코드 이스케이프와 리터럴 문자가 섞인 텍스트를 다루는 과정에서 일부만 잘못 디코딩된 것으로 추정 — 재발 방지를 위한 근본 원인 분석까지는 하지 않았고, 발견된 4곳은 `update_properties`로 직접 제목을 고쳐서 해결했다. 앞으로 Claude Code로 대량 텍스트를 옮길 일이 있으면, 옮긴 직후 제목 목록을 한 번씩 훑어보는 습관이 필요하다는 걸 확인한 사례.

## 7.1 실전 테스트에서 바로 잡힌 버그 — `docs/**/*.md`가 최상위 파일을 못 잡음

이 문서 자체를 커밋해서 첫 실전 테스트를 돌렸는데, GitHub Actions 실행은 성공(`success`)했지만 로그에 `no docs/**.md changes in this push`만 찍히고 실제로는 아무 페이지도 안 만들어졌다.

**원인**: 워크플로우 YAML의 `paths: docs/**/*.md`(GitHub Actions 자체 glob 엔진, picomatch 기반)는 `**`를 "0개 이상의 디렉토리"로 해석해서 `docs/Notion-Docs-Sync-Automation.md`처럼 하위 폴더 없이 `docs/` 바로 밑에 있는 파일도 잡는다 — 그래서 워크플로우 트리거 자체는 정상적으로 실행됐다. 반면 스크립트 내부에서 쓴 `git diff -- "docs/**/*.md"`는 **git의 기본 pathspec 매칭**(`:(glob)` 매직 없이)인데, 이건 패턴의 리터럴 문자(`/`)를 그대로 요구한다. 패턴 `docs/**/*.md`에는 `/`가 두 개 있어서 "docs/" 바로 다음 슬래시 하나, 그리고 파일명 앞 슬래시 하나 — 최소 두 단계 깊이(`docs/어떤폴더/파일.md`)를 강제한다. `docs/파일.md`처럼 슬래시가 하나뿐인 경로는 애초에 이 패턴에 안 걸린다. 즉 **GitHub Actions 트리거와 git diff pathspec이 같은 `**` 문법을 서로 다르게 해석**한 게 원인.

**해결**: git diff는 `docs/**/*.md` 대신 그냥 `docs` 디렉토리 전체를 대상으로 하고, `.md` 확장자 필터링은 스크립트(JS)에서 직접 처리하도록 바꿨다.

```js
// 수정 전 — docs/ 바로 밑 파일을 놓침
execSync(`git diff --name-status ${base} HEAD -- "docs/**/*.md"`);

// 수정 후 — docs/ 전체를 diff하고 .md만 필터링
execSync(`git diff --name-status ${base} HEAD -- docs`)
  .toString().split("\n").filter(Boolean)
  .map((line) => { const [status, file] = line.split("\t"); return { status, file }; })
  .filter(({ file }) => file.endsWith(".md"));
```

**교훈**: "워크플로우가 성공(success)했다"는 "의도한 동작을 했다"를 보장하지 않는다. 트리거 조건과 스크립트 내부 로직이 겉보기엔 같은 glob 문법(`**`)을 쓰지만 서로 다른 엔진(picomatch vs git pathspec)이 해석한다는 걸 실측 전에는 몰랐다 — 실제로 새 문서 하나를 커밋해서 로그를 열어본 뒤에야 드러난 문제.

## 8. 한계 / 다음에 정리할 것

- 마크다운의 일부 확장 문법(각주, 커스텀 색상 등)은 `martian` 변환 과정에서 그대로 안 옮겨질 수 있다 — 지금까지는 표·코드블록·목록·헤딩 정도만 실사용.
- Notion API rate limit(초당 약 3요청)을 별도로 스로틀링하지 않았다 — 한 push에 문서가 아주 많이 바뀌면 동기화가 느려지거나 429를 만날 수 있다. 지금 규모(리포 3개, 문서 수십 개)에서는 아직 문제된 적 없음.
- 문서 삭제 시 Notion 페이지 자동 삭제 정책이 없다(5.4절) — 필요해지면 `git diff`의 `D` 상태를 스크립트에서 실제로 처리하도록 확장.
- `docs/**.md` 바깥(리포 루트의 `README.md` 등)은 동기화 대상이 아니다 — 필요하면 워크플로우의 `paths`와 스크립트의 glob을 넓혀야 한다.

## 9. 검증

이 문서 자체를 첫 실전 테스트로 썼다. 1차 push에서는 워크플로우가 `success`로 끝났지만 실제로는 아무 페이지도 안 만들어지는 걸 발견했고(7.1절), 그 버그를 고친 뒤 이 문단을 추가해서 다시 push한 게 2차 테스트다 — 이번엔 "새 페이지 생성 → `.notion-sync-map.json`에 추가 → 그 변경분 커밋백"까지 전부 도는지 확인했다.

## 관련 문서

- `docs/ArgoCD-Image-Updater-target-tracking-service.md` — 비슷한 성격의 "git push를 GitHub Secret 기반 외부 API 호출로 잇는" 자동화 선례
