# GitNexus(gitnexus@1.6.12)는 공식 Dockerfile.cli가 web UI 번들을 뺀 API 전용
# 이미지라 그대로 못 쓴다 -- npm 패키지 자체(package/web/, 115개 파일)에는
# 웹 UI가 포함돼 있어서, 전역 설치 방식이면 `gitnexus serve`가 UI까지 그대로 서빙한다.
FROM node:22-bookworm-slim

# tree-sitter 계열 네이티브 애드온(node-gyp) 빌드 도구 + git/ssh(자동 동기화가
# SSH remote를 클론할 때 git이 내부적으로 ssh를 호출함) + curl(헬스체크용) +
# procps -- `gitnexus auto-sync start`가 백그라운드 watch 프로세스를 띄운 뒤
# 자기 자신의 시작 시각을 ps로 검증한다(공식 Dockerfile.cli의 "procps for
# watch process identity" 주석과 동일한 이유). 처음엔 빠뜨렸다가
# "[auto-sync] Unable to verify the watch process start time" 에러로 발견했다.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git openssh-client ca-certificates curl procps \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g gitnexus@1.6.12

# node:22-bookworm-slim에는 이미 UID 1000 'node' 유저가 있다 -- 그대로 재사용.
RUN mkdir -p /data/.gitnexus && chown -R node:node /data
USER node
ENV HOME=/home/node
ENV GITNEXUS_HOME=/data/.gitnexus
ENV GITNEXUS_NO_UPDATE_NOTIFIER=1

EXPOSE 4747

# 레포마다 전용 읽기 전용 배포키를 쓰는데(GitHub는 같은 deploy key를 여러 레포에
# 재등록하는 걸 거부함 -- "key is already in use"), 전부 github.com 하나를 가리키는
# URL이라 SSH host별 IdentityFile로는 구분이 안 된다(게다가 auto-sync의 URL 검증이
# "github.com 리터럴"만 허용해서 호스트 별칭을 못 씀). 그래서 ssh-agent를 띄우고
# /etc/gitnexus-ssh/ 아래 마운트된 키를 전부 등록해두면, ssh가 깃허브와 핸드셰이크할
# 때 레포별로 맞는 키를 알아서 골라 쓴다 -- git URL은 그대로 git@github.com:...
#
# `ssh-agent -s`(랜덤 소켓)로 처음 했더니 `kubectl exec`로 auto-sync를 따로 실행할 때
# "Permission denied (publickey)"가 났다 -- eval로 SSH_AUTH_SOCK을 내보내는 건 그
# CMD 셸 프로세스(와 거기서 exec한 gitnexus serve)에만 적용되고, 별도 exec 세션은
# 그 값을 모르니 에이전트에 아예 못 붙어서 키를 하나도 못 쓴다. 그래서 소켓 경로를
# 고정(-a)해서 쓰고, 같은 경로를 deployment.yaml의 SSH_AUTH_SOCK 파드 환경변수로도
# 선언해뒀다 -- 그러면 어느 kubectl exec 세션이든 같은 소켓을 찾아간다.
CMD ["sh", "-c", "ssh-agent -a $SSH_AUTH_SOCK && for k in /etc/gitnexus-ssh/*; do [ -f \"$k\" ] && ssh-add \"$k\"; done; exec gitnexus serve --host 0.0.0.0 --port 4747"]
