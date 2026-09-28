# 헤드리스 전환 — Amphetamine → caffeinate LaunchDaemon (2026-09-28)

`Host-Dedicated-Server-Resource-Cleanup.md`에서 식별한 가장 큰 단일 회수 기회(GUI 로그인 세션 683MB)를 실행에 옮긴 기록. **로그아웃해도 절전 방지가 유지되는지 단계별로 겹쳐서 검증한 뒤에만 다음 단계로 넘어갔다** — 이 서버는 Tailscale로만 접근 가능한 유일한 원격 인프라라, 절전 방지가 실패하면 물리적으로 가지 않는 한 복구 수단이 없다(`Remote-Wake-and-Downtime-Alerting.md`에서 이미 결론 낸 제약).

## 왜 Amphetamine을 그냥 못 쓰나

Amphetamine은 **GUI 세션이 살아있어야** 절전 방지 기능이 동작한다. 로그아웃하면 이 가정 자체가 깨진다. `caffeinate -disu`를 LaunchDaemon으로 등록하면 GUI 세션과 무관하게 root 권한으로 절전 방지가 가능해서, 이 전환의 핵심 전제였다.

## 핵심 리스크 — 클램쉘(뚜껑 닫힘) 오버라이드가 caffeinate에서도 되는가

이 호스트는 뚜껑을 닫은 클램쉘 상태로 돌아간다(`AppleClamshellState = Yes`). `caffeinate` 커맨드라인 도구는 일반적으로 클램쉘 절전을 못 막는다는 보고가 많아서(외부 디스플레이/키보드가 붙어있어야 하는 Apple 공식 클램쉘 모드 요건과 별개의 문제), 이걸 확인 안 하고 그냥 바꾸면 Amphetamine 없앤 순간 오히려 사고가 재현될 수 있었다.

검증 결과: `AppleClamshellCausesSleep`은 Amphetamine이 잡고 있을 때도, caffeinate로 교체한 뒤에도 동일하게 `No`로 유지됐다 — 즉 이 필드는 앱 종류와 무관하게 **활성 `PreventSystemSleep` assertion이 있으면 동적으로 오버라이드되는 구조**였다. 이게 확인된 뒤에야 다음 단계로 진행했다.

## 실행 순서 — 안전하게 겹쳐서 전환

### 1. pmset 설정 백업

```bash
pmset -g > /tmp/pmset-before-caffeinate-migration.txt
pmset -g assertions > /tmp/pmset-assertions-before.txt
```

### 2. caffeinate LaunchDaemon 설치 (Amphetamine은 그대로 둔 채)

`/Library/LaunchDaemons/com.parksangmin.caffeinate.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.parksangmin.caffeinate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-disu</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/caffeinate-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/caffeinate-daemon.log</string>
</dict>
</plist>
```

`KeepAlive=true`라서 caffeinate 프로세스가 어떤 이유로든 죽으면 launchd가 즉시 재기동시킨다 — Amphetamine(죽으면 그냥 안 뜸)보다 오히려 더 견고한 지점.

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.parksangmin.caffeinate.plist
```

### 3. 겹친 상태에서 1차 검증

```bash
pmset -g assertions | grep -iE 'caffeinate|amphetamine'
# caffeinate(root, LaunchDaemon)와 Amphetamine 둘 다 독립적으로 assertion을 잡고 있음을 확인
pmset -g | grep sleep
# "sleep prevented by caffeinate, caffeinate, Amphetamine, powerd"
```

### 4. Amphetamine 종료 후 caffeinate 단독 검증 (가장 중요한 단계)

```bash
osascript -e 'quit app "Amphetamine"'
pmset -g | grep sleep
# "sleep prevented by caffeinate, caffeinate, nsurlsessiond, powerd" -- Amphetamine 없이도 유지
ioreg -r -k AppleClamshellState -d 4 | grep -i clamshell
# AppleClamshellCausesSleep = No 그대로 -- 클램쉘 오버라이드도 caffeinate 단독으로 유지됨
```

이 단계가 실패했다면(클램쉘 오버라이드가 풀렸다면) 바로 `open -a Amphetamine`으로 되돌리고 로그아웃 자체를 하지 않았을 것이다.

### 5. SSH가 GUI 세션과 독립적인지 확인

```bash
who
# sangmin console  Sep 25 06:06        <- 물리 콘솔(Aqua) 세션
# sangmin ttys001  Sep 28 14:16 (...)  <- 지금 이 SSH 세션, 완전히 별개
```

macOS의 Remote Login(sshd)은 콘솔 GUI 세션과 무관한 시스템 데몬이라, 콘솔 세션을 로그아웃해도 SSH는 살아있어야 한다는 걸 실제 로그아웃 전에 확인했다.

### 6. 실제 로그아웃

```bash
sudo launchctl bootout gui/501
```

### 7. 로그아웃 후 검증

```bash
ssh sangmin@<host>   # 새 세션으로 재접속 -- 성공
who                  # console 세션은 사라지고 ttys001(SSH)만 남음
pmset -g | grep sleep
# "sleep prevented by caffeinate, caffeinate, powerd" -- 유지됨
curl https://k3s-master.taildcdcee.ts.net/api/v1/threat-analysis/status  # 외부 헬스체크 정상
curl https://k3s-master.taildcdcee.ts.net/ai/health                      # 외부 헬스체크 정상
multipass list       # 3노드 전부 Running, 영향 없음
```

## 백업 / 롤백 준비

**요청받은 대로, "다시 절전 모드로 들어갔을 때 복구 가능한 백업"을 준비했다:**

<table fit-page-width="true" header-row="true">
<tr><td>백업 항목</td><td>위치</td><td>용도</td></tr>
<tr><td>전환 전 `pmset -g` 스냅샷</td><td>호스트 `~/pre-headless-pmset-backup-2026-09-28.txt`</td><td>원래 설정값 참고</td></tr>
<tr><td>전환 전 assertion 스냅샷</td><td>호스트 `~/pre-headless-assertions-backup-2026-09-28.txt`</td><td>Amphetamine이 정확히 뭘 잡고 있었는지 참고</td></tr>
<tr><td>롤백 스크립트</td><td>호스트 `~/rollback-to-amphetamine.sh`</td><td>caffeinate LaunchDaemon 언로드 + Amphetamine 재실행을 한 번에</td></tr>
<tr><td>Amphetamine.app 자체</td><td>그대로 설치 유지 (삭제 안 함)</td><td>언제든 재실행 가능</td></tr>
</table>

```bash
#!/bin/bash
# ~/rollback-to-amphetamine.sh
set -e
sudo launchctl bootout system/com.parksangmin.caffeinate 2>&1 || true
sudo rm -f /Library/LaunchDaemons/com.parksangmin.caffeinate.plist
open -a Amphetamine
```

### 솔직히 실패한 부분 — Screen Sharing으로 원격 GUI 복구는 지금 안 됨

롤백 스크립트를 실행하려면 GUI 세션이 있어야 하는데(`open -a Amphetamine`), 지금 로그아웃한 상태에서 원격으로 GUI에 다시 들어갈 방법이 있는지 확인하려고 Screen Sharing(VNC)을 활성화 시도했다.

```bash
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -restart -agent -privs -all
```

결과: "Activated Remote Management"라고는 나왔지만 포트 5900이 실제로 리스닝하지 않았다. 원인은 macOS의 TCC(개인정보 보호) — Screen Recording 권한을 **GUI에서 사람이 직접 승인**해야 하는데, 이미 로그아웃한 상태라 이 승인 자체를 할 수 없다(닭이 먼저냐 달걀이 먼저냐 문제). 커맨드라인만으로는 이 권한을 우회할 방법이 없다.

**즉 지금 시점에서 진짜 백업은 다음 두 가지뿐이다:**
1. 위 스냅샷/스크립트 — 물리적으로 접근했을 때 빠르게 원상복구하기 위한 것
2. 기존 `ai-health-check.yml`의 시간당 ntfy 알림 — 절전 재발 시 최대 1시간 내 감지

**다음에 물리적으로 이 컴퓨터에 접근할 기회가 있으면**, System Settings > Privacy & Security > Screen Recording에서 ARD/Screen Sharing 권한을 한 번 승인해두는 걸 권장한다 — 그러면 그 다음부턴 Screen Sharing이 완전히 원격으로 동작해서, 로그아웃 상태에서도 GUI 복구가 가능해진다. `Remote-Wake-and-Downtime-Alerting.md`에서 다룬 "원격 wake-up 자체는 여전히 불가능"이라는 결론은 안 바뀌지만, 적어도 "시스템은 켜져 있는데 GUI만 필요한 상황"은 이걸로 해결된다.

## 결과 — 메모리 절감

<table fit-page-width="true" header-row="true">
<tr><td>구성 요소</td><td>로그아웃 전</td><td>로그아웃 후</td></tr>
<tr><td>WindowServer</td><td>313M (풀 Aqua 세션)</td><td>152M (로그인 화면 수준 최소 데몬)</td></tr>
<tr><td>Finder</td><td>58M</td><td>0 (종료)</td></tr>
<tr><td>Dock</td><td>45M</td><td>0 (종료)</td></tr>
<tr><td>NotificationCenter</td><td>45M</td><td>0 (종료)</td></tr>
<tr><td>ControlCenter</td><td>40M</td><td>0 (종료)</td></tr>
<tr><td>loginwindow</td><td>41M</td><td>0 (SecurityAgent 51M로 대체 — 로그인 프롬프트 핸들러)</td></tr>
<tr><td>합계(근사)</td><td>~542M</td><td>~203M</td></tr>
</table>

**약 340~460MB 추가 회수** — 이날 앞서 진행한 `Host-Dedicated-Server-Resource-Cleanup.md`의 개인용 앱 정리(~150~185MB)까지 합치면, 하루 동안 이 호스트에서 **약 500~650MB**를 서버 용도가 아닌 곳에서 회수해서 k3s VM 쪽으로 돌릴 수 있는 여유로 확보했다.

## 결론

목표("최대한 서버 컴퓨터로만 작동")에 맞게 GUI 세션 전체를 내렸고, 그 전에 caffeinate가 Amphetamine의 핵심 기능(클램쉘 오버라이드 포함)을 완전히 대체하는지 매 단계 겹쳐서 검증한 뒤에만 다음 단계로 진행했다. SSH·k3s·ArgoCD·외부 헬스체크 전부 영향 없음을 확인했다. 유일한 미해결 지점은 "원격 GUI 복구 수단(Screen Sharing)이 TCC 권한 때문에 지금은 막혀 있다"는 것 — 다음 물리 접근 시 권한 승인 한 번이면 해결된다.
