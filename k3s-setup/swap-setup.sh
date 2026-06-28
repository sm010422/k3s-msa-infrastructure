#!/bin/bash
# 각 노드에서 실행 — K3s 클러스터 초기화 + Swap 메모리 영구 설정
# 실행 전: chmod +x swap-setup.sh

set -euo pipefail

SWAP_SIZE_GB=${1:-2}
SWAP_FILE="/swapfile"
NODE_ROLE=${2:-agent}   # control-plane | agent
K3S_SERVER_URL=${3:-""}  # agent 전용: https://<server1-tailscale-ip>:6443
K3S_TOKEN=${4:-""}       # agent 전용: /var/lib/rancher/k3s/server/node-token

echo "=== [1/4] Swap 메모리 ${SWAP_SIZE_GB}GB 설정 ==="

if swapon --show | grep -q "$SWAP_FILE"; then
    echo "Swap 이미 활성화됨. 건너뜀."
else
    fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    # 재부팅 후에도 유지되도록 fstab 등록
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi
    echo "Swap ${SWAP_SIZE_GB}GB 활성화 완료"
fi

# OOM 방어를 위한 swappiness 조정 (기본 60 → 10)
sysctl -w vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf

echo "=== [2/4] K3s 설치 ==="

if command -v k3s &>/dev/null; then
    echo "K3s 이미 설치됨. 건너뜀."
else
    curl -sfL https://get.k3s.io | sh -
fi

echo "=== [3/4] 노드 역할 설정: $NODE_ROLE ==="

if [ "$NODE_ROLE" = "control-plane" ]; then
    # Control Plane: Tailscale 인터페이스로 내부 통신 제한
    systemctl enable --now k3s
    echo ""
    echo "=== Control Plane 설치 완료 ==="
    echo "Agent 노드 등록에 필요한 토큰:"
    cat /var/lib/rancher/k3s/server/node-token

elif [ "$NODE_ROLE" = "agent" ]; then
    if [ -z "$K3S_SERVER_URL" ] || [ -z "$K3S_TOKEN" ]; then
        echo "ERROR: agent 역할에는 K3S_SERVER_URL 과 K3S_TOKEN 이 필요합니다."
        echo "Usage: $0 <swap_gb> agent <server_url> <token>"
        exit 1
    fi

    K3S_URL="$K3S_SERVER_URL" K3S_TOKEN="$K3S_TOKEN" \
        curl -sfL https://get.k3s.io | sh -s - agent \
        --flannel-iface tailscale0

    systemctl enable --now k3s-agent
    echo "Agent 노드 등록 완료: $K3S_SERVER_URL"
fi

echo "=== [4/4] 설치 확인 ==="
if [ "$NODE_ROLE" = "control-plane" ]; then
    k3s kubectl get nodes
fi

echo "=== 완료 ==="
