# 🛡️ C4I 실시간 전술 객체 추적 시스템 - 인프라스트럭처 (K3s MSA)

[![Kubernetes](https://img.shields.io/badge/Kubernetes-K3s-blue?logo=kubernetes)](#) [![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-orange?logo=ubuntu)](#) [![Tailscale](https://img.shields.io/badge/VPN-Tailscale-lightgrey?logo=tailscale)](#)

## 📌 프로젝트 개요
본 리포지토리는 **실시간 전술 객체(드론, 항공기 등) 추적 및 데이터 시각화 MSA 시스템**을 구동하기 위한 **고가용성(HA) 로컬 쿠버네티스 클러스터 인프라** 구성 및 배포 명세(IaC)를 담고 있습니다. 

국방/방산 도메인에서 요구하는 '중단 없는 서비스(고가용성)'와 '안전한 내부 통신망(보안)'을 로컬 환경에 완벽하게 모사하는 것을 목표로 설계되었습니다.

## 🏗️ 아키텍처 및 클러스터 구성

*(이미지 설명: 마스터 노드(Control Plane)가 워커 노드들의 상태를 감시하고, 트래픽과 워크로드를 분산 배치하여 장애를 대비하는 쿠버네티스 클러스터의 핵심 아키텍처 구조입니다.)*

제한된 호스트 자원(RAM 8GB) 내에서 최적의 분산 환경을 구축하기 위해, 무거운 Docker 대신 `containerd` 기반의 경량화 쿠버네티스인 **K3s**를 채택하여 3-Node 클러스터를 구축했습니다.

| Node Name | Role | OS | RAM | Swap Memory | Network (VPN) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`server1`** | `Control-plane` (Master) | Ubuntu | 2GB | 2GB (OOM 방어) | Tailscale IP (`100.x.x.x`) |
| **`server2`** | `Worker` (Agent) | Ubuntu | 1GB | 2GB (OOM 방어) | Tailscale IP (`100.x.x.x`) |
| **`server3`** | `Worker` (Agent) | Ubuntu | 1GB | 2GB (OOM 방어) | Tailscale IP (`100.x.x.x`) |

## ✨ 인프라 핵심 엔지니어링 포인트

### 1. 망 분리 및 보안 통신망 구축 (VPC 모사)
* **Tailscale**을 도입하여 3대의 가상머신을 안전한 가상 사설망(VPN)으로 묶었습니다.
* K3s 클러스터 내부 통신(`--flannel-iface tailscale0`)을 이 가상망으로만 제한하여, 외부의 접근을 차단하는 국방 망 분리 시스템의 기초적인 형태를 모사했습니다.

### 2. 하드웨어 한계 극복 및 안정성(Stability) 확보
* **메모리 최적화:** `kubeadm` 대신 **K3s**를 도입하여 마스터 노드의 기본 메모리 점유율을 50% 이하(약 900MB)로 다이어트했습니다.
* **OOM(Out Of Memory) 방어막:** 물리 램(1~2GB)의 한계로 인해 파드(Pod)가 죽는 현상을 방지하고자, 각 노드 디스크에 **2GB의 Swap 메모리를 영구 할당**(`/etc/fstab` 등록)하여 시스템 다운타임을 원천 차단했습니다.

### 3. 분산 배포 및 로드밸런싱 검증 완료
* 3개의 Nginx 웹 서버 복제본(`replicas=3`)을 배포하여, 마스터 노드가 `server2`와 `server3`에 성공적으로 트래픽과 파드를 분산(로드밸런싱)하는 것을 테스트 및 검증 완료했습니다.
* 외부 노출은 K3s 내장 `Traefik` 및 `NodePort`를 활용하여 구성할 예정입니다.

## 📂 리포지토리 구성 안내
본 인프라 위에서 동작하는 마이크로서비스(MSA) 코드는 역할에 따라 아래 리포지토리로 분리되어 있습니다.
* 🚪 **[Defense API Gateway (defense-api-gateway) 바로가기](https://github.com/sm010422/defense-api-gateway)** - 보안 인증 및 트래픽 라우팅
* 🎯 **[Target Tracking Service (target-tracking-service) 바로가기](https://github.com/sm010422/target-tracking-service)** - 실시간 레이더 데이터 수집 및 분석 처리
