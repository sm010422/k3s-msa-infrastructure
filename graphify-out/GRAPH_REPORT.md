# Graph Report - k3s-msa-infrastructure  (2026-10-06)

## Corpus Check
- 99 files · ~60,476 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 4 file(s) not represented in the graph (top: (none) 2, .mmd 2)

## Summary
- 318 nodes · 369 edges · 43 communities (16 shown, 27 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 56 edges (avg confidence: 0.88)
- Token cost: 0 input · 813,389 output

## Community Hubs (Navigation)
- Monitoring Stack (Grafana/Headlamp)
- Target-Tracking-Service K8s Stack
- Notion Sync Automation Script
- Architecture Diagram: GitOps + Cluster
- GitOps and ArgoCD Concepts
- Architecture Diagram: Service Stack
- Defense API Gateway Deployment
- GitNexus Deployment Rationale
- Multipass/Tailscale NodePort Docs
- MetalLB and Ingress Decisions
- Cluster Network Debugging Concepts
- Prometheus Monitoring Alternatives
- Prometheus/Grafana Internals
- MSS Asset Recommendation Engine
- AI Health Check and Alerting
- Tailscale Funnel vs Port Forwarding
- Graphify Output Artifacts
- Mac Sleep Prevention
- ClusterIP and CoreDNS Concepts
- Notion Sync Bugs
- Postgres NodePort Decision
- Notion Sync Workflow
- K8s Deployment/Service Concepts
- Notion Sync ArgoCD Reference
- Postgres/Qdrant NodePort Services
- Qdrant Dashboard Access
- Remote Wake Alternatives
- Swap Setup Script
- GitNexus ArgoCD Application
- ConfigMap vs Secret Concept
- C4I Services Cluster Group
- Cluster Foundation Group
- GitOps Delivery Group
- MSS Recommendation Engine Doc
- Intercept Asset Catalog
- ArgoCD Server NodePort Patch

## God Nodes (most connected - your core abstractions)
1. `Monitoring Stack Kustomization` - 18 edges
2. `Deployment: target-tracking-service` - 11 edges
3. `Deployment: threat-intel-ai-service` - 11 edges
4. `K3s MSA Infrastructure README` - 8 edges
5. `gitnexus Deployment` - 8 edges
6. `Grafana Deployment` - 7 edges
7. `Kustomization: target-tracking-service` - 7 edges
8. `target-tracking-service Dockerize and K3s Deployment` - 7 edges
9. `Target Tracking Domain` - 7 edges
10. `Target Tracking Service (real-time processor)` - 7 edges

## Surprising Connections (you probably didn't know these)
- `ImageUpdater: target-tracking-service-updater` --shares_data_with--> `target-tracking-service ArgoCD Resolved Image Pin`  [INFERRED]
  argocd/image-updater.yaml → apps/target-tracking-service/.argocd-source-target-tracking-service.yaml
- `ImageUpdater: target-tracking-service-updater` --shares_data_with--> `threat-intel-ai-service ArgoCD Resolved Image Pin`  [INFERRED]
  argocd/image-updater.yaml → apps/threat-intel-ai-service/.argocd-source-threat-intel-ai-service.yaml
- `defense-api-gateway (external repo)` --conceptually_related_to--> `defense-api-gateway Deployment`  [INFERRED]
  README.md → apps/defense-api-gateway/deployment.yaml
- `target-tracking-service (external repo)` --conceptually_related_to--> `target-tracking-service (cluster-internal URI)`  [INFERRED]
  README.md → apps/defense-api-gateway/deployment.yaml
- `gateway-secrets (jwt-secret)` --semantically_similar_to--> `GITNEXUS_MCP_AUTH_TOKEN`  [INFERRED] [semantically similar]
  apps/defense-api-gateway/deployment.yaml → apps/gitnexus/deployment.yaml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Gitnexus Network Isolation Defense-in-Depth** — apps_gitnexus_deployment_public_origin_omission, apps_gitnexus_service_nodeport_vs_ingress, apps_gitnexus_deployment_mcp_auth_token [INFERRED 0.85]
- **Gitnexus Master-Node Capacity & Placement Coupling** — apps_gitnexus_deployment_master_node_placement, apps_gitnexus_pvc_local_path_node_affinity_coupling, apps_gitnexus_deployment_memory_limit_increase [INFERRED 0.85]
- **C4I MSA Cross-Repo Service Topology** — readme_defense_api_gateway_repo, readme_target_tracking_service_repo, apps_defense_api_gateway_deployment_defense_api_gateway, apps_defense_api_gateway_deployment_target_tracking_service [INFERRED 0.80]
- **Grafana Provisioning Bundle (deployment + datasource + dashboards + provider + storage)** — apps_monitoring_grafana_deployment_grafana, apps_monitoring_grafana_datasource_configmap_grafana_datasource, apps_monitoring_grafana_dashboard_provider_configmap_grafana_dashboard_provider, apps_monitoring_grafana_dashboards_configmap_grafana_dashboards, apps_monitoring_grafana_pvc_grafana_pvc [EXTRACTED 1.00]
- **Prometheus Scrape Target Topology (monitoring namespace)** — apps_monitoring_prometheus_configmap_scrape_job_node_exporter, apps_monitoring_prometheus_configmap_scrape_job_kube_state_metrics, apps_monitoring_prometheus_configmap_scrape_job_headlamp, apps_monitoring_prometheus_configmap_scrape_job_kubernetes_cadvisor, apps_monitoring_node_exporter_daemonset_node_exporter, apps_monitoring_kube_state_metrics_service_kube_state_metrics, apps_monitoring_headlamp_service_headlamp [EXTRACTED 1.00]
- **Monitoring Stack ServiceAccount+ClusterRole(Binding) Pattern** — apps_monitoring_prometheus_rbac_prometheus_serviceaccount, apps_monitoring_kube_state_metrics_rbac_kube_state_metrics_serviceaccount, apps_monitoring_headlamp_rbac_headlamp_admin_serviceaccount [INFERRED 0.85]
- **target-tracking-service Kustomize Stack (app + kafka + postgres + redis)** — apps_target_tracking_service_kustomization_kustomization, apps_target_tracking_service_deployment_deployment_target_tracking_service, apps_target_tracking_service_kafka_deployment_kafka, apps_target_tracking_service_postgres_deployment_postgres, apps_target_tracking_service_redis_deployment_redis [INFERRED 0.85]
- **threat-intel-ai-service Kustomize Stack (app + qdrant)** — apps_threat_intel_ai_service_kustomization_kustomization, apps_threat_intel_ai_service_deployment_deployment_threat_intel_ai_service, apps_threat_intel_ai_service_qdrant_deployment_threat_intel_qdrant, apps_threat_intel_ai_service_service_service_threat_intel_ai_service, apps_threat_intel_ai_service_ingress_ingress_threat_intel_ai_service [INFERRED 0.85]
- **GitOps Digest-based Image Auto-Update Pipeline** — argocd_image_updater_imageupdater_target_tracking_service_updater, apps_target_tracking_service__argocd_source_target_tracking_service_image_pin, apps_threat_intel_ai_service__argocd_source_threat_intel_ai_service_image_pin, argocd_applications_target_tracking_service_application_target_tracking_service, argocd_applications_threat_intel_ai_service_application_threat_intel_ai_service [INFERRED 0.85]
- **Tailscale mesh / serve / funnel vs port forwarding form the full remote-access layering** — docs_public_access_via_tailscale_funnel_mesh, docs_public_access_via_tailscale_funnel_serve, docs_public_access_via_tailscale_funnel_funnel, docs_tailscale_funnel_vs_port_forwarding_port_forwarding [INFERRED 0.85]
- **postgres/qdrant/argocd-server NodePort exposure under GitOps, same recurring pattern** — docs_postgres_nodeport_and_argocd_ignoredifferences_postgres_service, docs_qdrant_nodeport_and_dashboard_access_service, docs_vmware_to_multipass_cluster_migration_argocd_server_nodeport [INFERRED 0.85]
- **Migration doc, resource-usage analysis, and tradeoffs doc jointly assess the VMware-to-Multipass decision** — docs_vmware_to_multipass_cluster_migration_doc, docs_vmware_vs_multipass_resource_usage_analysis_doc, docs_vmware_vs_multipass_tradeoffs_doc [EXTRACTED 0.90]
- **Cluster Foundation layer (Tailscale, K3s, swap provisioning, Traefik)** — docs_diagram_diagram_tailscale, docs_diagram_diagram_k3s, docs_diagram_diagram_swap, docs_diagram_diagram_traefik [EXTRACTED 1.00]
- **GitOps Delivery pipeline (Argo CD, Image Updater, three Applications)** — docs_diagram_diagram_argocd, docs_diagram_diagram_image_updater, docs_diagram_diagram_gateway_app, docs_diagram_diagram_tracking_app, docs_diagram_diagram_threat_app [EXTRACTED 1.00]
- **C4I Services workloads (Gateway, Tracking bundle/service, Kafka, Postgres, Redis, Threat AI bundle/service, Qdrant)** — docs_diagram_diagram_gateway, docs_diagram_diagram_tracking_bundle, docs_diagram_diagram_tracking, docs_diagram_diagram_kafka, docs_diagram_diagram_postgres, docs_diagram_diagram_redis, docs_diagram_diagram_threat_bundle, docs_diagram_diagram_threat_ai, docs_diagram_diagram_qdrant [EXTRACTED 1.00]
- **Argo CD GitOps reconciliation flow** — docs_diagram_diagram2_argocd, docs_diagram_diagram2_image_updater, docs_diagram_diagram2_gateway_app, docs_diagram_diagram2_tracking_app, docs_diagram_diagram2_threat_bundle [INFERRED 0.85]
- **Target Tracking Service data stack** — docs_diagram_diagram2_tracking_service, docs_diagram_diagram2_kafka, docs_diagram_diagram2_postgres, docs_diagram_diagram2_redis [INFERRED 0.85]
- **Threat Intel AI deployment bundle** — docs_diagram_diagram2_threat_bundle, docs_diagram_diagram2_threat_ai, docs_diagram_diagram2_qdrant [INFERRED 0.85]

## Communities (43 total, 27 thin omitted)

### Community 0 - "Monitoring Stack (Grafana/Headlamp)"
Cohesion: 0.07
Nodes (35): Grafana Dashboard Provider ConfigMap, App Service Metrics Dashboard (app-metrics.json), Grafana Dashboards ConfigMap, C4I Pod Resources Dashboard (pod-resources.json), Prometheus Stats Dashboard (grafana.com ID 3662), Grafana Datasource ConfigMap (Prometheus), Grafana Deployment, Grafana PVC (+27 more)

### Community 1 - "Target-Tracking-Service K8s Stack"
Cohesion: 0.09
Nodes (32): target-tracking-service ArgoCD Resolved Image Pin, ConfigMap: target-tracking-config, Deployment: target-tracking-service, Secret: target-tracking-secrets (referenced), Ingress: target-tracking-service, Deployment: kafka, Service: kafka-service, Kustomization: target-tracking-service (+24 more)

### Community 2 - "Notion Sync Automation Script"
Cohesion: 0.08
Nodes (28): appendBlocks(), changedMarkdownFiles(), clearChildren(), { Client }, commitMapIfChanged(), DEFAULT_PARENTS, diffBase(), { execSync } (+20 more)

### Community 3 - "Architecture Diagram: GitOps + Cluster"
Cohesion: 0.17
Nodes (24): Argo CD (GitOps reconciler), Cluster Foundation, K3s MSA Infrastructure Architecture Diagram, Tailscale Funnel (optional public access), Defense API Gateway (edge service), Gateway Application (Argo CD application), GitOps Control Plane, Argo CD Image Updater (image automation) (+16 more)

### Community 4 - "GitOps and ArgoCD Concepts"
Cohesion: 0.10
Nodes (14): Concept: Kubernetes Core Objects, Namespace (c4i), ArgoCD Application (git-to-cluster mapping), syncPolicy (automated/prune/selfHeal/CreateNamespace), AX-Portfolio-Roadmap.md (cited), Project Maturity Assessment, Test coverage improvement across 3 repos (2026-09-23), Remote Wake and Downtime Alerting (+6 more)

### Community 5 - "Architecture Diagram: Service Stack"
Cohesion: 0.14
Nodes (18): Argo CD GitOps reconciler, Defense API Gateway (API boundary), Gateway Application (Argo CD application), Argo CD Image Updater (image-updater.yaml), HA K3s cluster orchestrator, Kafka (event backbone), PostgreSQL (operational state), Qdrant (vector store) (+10 more)

### Community 6 - "Defense API Gateway Deployment"
Cohesion: 0.16
Nodes (13): defense-api-gateway Deployment, gateway-secrets (jwt-secret), target-tracking-service (cluster-internal URI), defense-api-gateway Service (NodePort 30081), GITNEXUS_MCP_AUTH_TOKEN, containerd runtime, defense-api-gateway (external repo), K3s (lightweight Kubernetes) (+5 more)

### Community 7 - "GitNexus Deployment Rationale"
Cohesion: 0.19
Nodes (7): gitnexus Deployment, docs/concepts/09-swarm-load-generator-design-discussion.md, gitnexus Kustomization, gitnexus-data PersistentVolumeClaim, gitnexus Service (NodePort 30747), Headlamp / Grafana / Prometheus NodePort Pattern, docs/Public-Access-via-Tailscale-Funnel.md

### Community 8 - "Multipass/Tailscale NodePort Docs"
Cohesion: 0.19
Nodes (12): MetalLB Feasibility Investigation on Tailscale Overlay, Multipass Operations Guide, Host-Memory-Reclamation-for-Multipass-VMs.md (cited), VM disk/memory resize requires stopped VM, Postgres NodePort and ArgoCD ignoreDifferences, Public Access via Tailscale Funnel, Qdrant NodePort and Dashboard Access, Tailscale Funnel vs Port Forwarding (+4 more)

### Community 9 - "MetalLB and Ingress Decisions"
Cohesion: 0.18
Nodes (5): MetalLB BGP mode (no peer router), keepalived/VRRP alternative (also blocked), MetalLB L2Advertisement mode, MetalLB, svclb-traefik DaemonSet (klipper-lb, all-node 80/443)

### Community 10 - "Cluster Network Debugging Concepts"
Cohesion: 0.29
Nodes (5): PersistentVolumeClaim (local-path, WaitForFirstConsumer), Concept: GitOps and ArgoCD, k3s-cni-crashloop-troubleshooting.md (cited analogous pattern), Concept: Cluster Network Debugging, K3s-Flannel-VXLAN-Node-Outage-Troubleshooting.md (follow-up incident, cited)

### Community 11 - "Prometheus Monitoring Alternatives"
Cohesion: 0.29
Nodes (3): Lightweight Prometheus+Grafana Monitoring Stack, Host-vs-Cluster-Memory-Two-Separate-Pools.md (cited), ntfy.sh push alert channel

### Community 13 - "MSS Asset Recommendation Engine"
Cohesion: 0.38
Nodes (6): ApprovalPanel.tsx (radio option UI), assess_threat_level (rule-based classification), AssetRecommendationService.recommend (haversine ETA), check_intercept_asset_availability (random simulation, old), Palantir Maven Smart System (MSS), ThreatApprovalService (createIfNeeded/decide)

### Community 14 - "AI Health Check and Alerting"
Cohesion: 0.33
Nodes (5): Gemini API Key Placeholder Incident (2026-09-22), Tailscale connectivity (home server), target-tracking-service /api/v1/threat-analysis/status endpoint, threat-intel-ai-service /ai/health endpoint, AI Health Check Workflow

### Community 15 - "Tailscale Funnel vs Port Forwarding"
Cohesion: 0.33
Nodes (6): tailscale funnel (public internet exposure), Tailscale mesh (tailnet only), tailscale serve (intra-mesh reverse proxy), Tailscale Funnel (outbound relay via Tailscale infra), Port forwarding (inbound NAT, public IP needed), Funnel limited to 3 port slots (443/8443/10000) per node

### Community 16 - "Graphify Output Artifacts"
Cohesion: 0.50
Nodes (4): graphify-out/graph.json, graphify-out/GRAPH_REPORT.md, graphify-out/wiki/index.md, Graphify Project Rules (CLAUDE.md)

## Ambiguous Edges - Review These
- `MetalLB Feasibility Investigation on Tailscale Overlay` → `VM disk/memory resize requires stopped VM`  [AMBIGUOUS]
  docs/MetalLB-Feasibility-Investigation-on-Tailscale-Overlay.md · relation: references

## Knowledge Gaps
- **90 isolated node(s):** `fs`, `path`, `{ execSync }`, `{ Client }`, `{ markdownToBlocks }` (+85 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 137 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **27 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `MetalLB Feasibility Investigation on Tailscale Overlay` and `VM disk/memory resize requires stopped VM`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **Why does `gitnexus Deployment` connect `GitNexus Deployment Rationale` to `Defense API Gateway Deployment`?**
  _High betweenness centrality (0.005) - this node is a cross-community bridge._
- **What connects `fs`, `path`, `{ execSync }` to the rest of the system?**
  _90 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Monitoring Stack (Grafana/Headlamp)` be split into smaller, more focused modules?**
  _Cohesion score 0.0664451827242525 - nodes in this community are weakly interconnected._
- **Should `Target-Tracking-Service K8s Stack` be split into smaller, more focused modules?**
  _Cohesion score 0.09047619047619047 - nodes in this community are weakly interconnected._
- **Should `Notion Sync Automation Script` be split into smaller, more focused modules?**
  _Cohesion score 0.0784313725490196 - nodes in this community are weakly interconnected._
- **Should `GitOps and ArgoCD Concepts` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._