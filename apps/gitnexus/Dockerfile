# GitNexus(gitnexus@1.6.12)는 공식 Dockerfile.cli가 web UI 번들을 뺀 API 전용
# 이미지라 그대로 못 쓴다 -- npm 패키지 자체(package/web/, 115개 파일)에는
# 웹 UI가 포함돼 있어서, 전역 설치 방식이면 `gitnexus serve`가 UI까지 그대로 서빙한다.
FROM node:22-bookworm-slim

# tree-sitter 계열 네이티브 애드온(node-gyp) 빌드 도구 + git/ssh(자동 동기화가
# SSH remote를 클론할 때 git이 내부적으로 ssh를 호출함) + curl(헬스체크용).
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git openssh-client ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g gitnexus@1.6.12

# node:22-bookworm-slim에는 이미 UID 1000 'node' 유저가 있다 -- 그대로 재사용.
RUN mkdir -p /data/.gitnexus && chown -R node:node /data
USER node
ENV HOME=/home/node
ENV GITNEXUS_HOME=/data/.gitnexus
ENV GITNEXUS_NO_UPDATE_NOTIFIER=1

EXPOSE 4747

CMD ["gitnexus", "serve", "--host", "0.0.0.0", "--port", "4747"]
