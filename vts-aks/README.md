# OpenText VTS: Azure Kubernetes Service (AKS) & Enterprise Landing Zone (ELZ) Playbook

This reference manual is tailored for performance test leads, application owners, and engineers transitioning OpenText Virtual Table Server (VTS) 26.1 from local containerized environments (OpenShift / CRC) to an **Enterprise Cloud Landing Zone on Microsoft Azure (AKS)**.

---

## 1. Executive Grounding: What Your Proof of Concept Proved

> [!IMPORTANT]
> **OpenShift is Kubernetes. AKS is Kubernetes.**
> Over the course of testing on OpenShift Local (CRC), your POC successfully validated the foundational architecture:
> - **Workload Isolation:** Two independent single-instance VTS workloads (`vts-app1-team` and `vts-app2-team`), each with its own pod, configuration, and dedicated persistent storage.
> - **Stateful Persistence:** `Recreate` deployment strategy with 1 replica and dedicated RWO persistent volume claims (`/var/lib/OT/OT_VTS/db/data`) preventing multi-attach corruption.
> - **In-Container Reverse Proxy & SSRF Protection:** In-container NGINX listening on port `8443`, proxying admin UI (port 4000) and dynamically routing instance API requests (`?portnumber=2000..2050`) while blocking direct external access to raw database sockets.
> - **Non-Root Execution Profile:** Processes designed for non-root execution (`vts_user` UID/GID `54345`).
> - **LoadRunner Client Compatibility:** Verified sub-200ms latency using LoadRunner VuGen `lrvtc_connect_ex` over standard HTTPS port 443.
>
> The core workload engine is **production-viable**. Transitioning to Azure AKS requires addressing **external enterprise governance, landing zone ingress (e.g. Istio), security policies, and image supply chain standards**.

---

## 2. Enterprise Cloud Ecosystem & Terminology Demystified

```mermaid
flowchart TD
    subgraph ELZ["Enterprise Cloud Landing Zone (Azure Subscription)"]
        subgraph Tier1["Tier 1 & Tier 2: Owned by Cloud Platform Team"]
            Net["Hub-and-Spoke VNet / ExpressRoute\n(Connection to On-Premise Load Generators)"]
            ACR["Enterprise Artifactory / Private ACR\n(enterprise-docker-release-local)"]
            AKV["Enterprise Key Vault / Secret Store\n(Certificates & Passwords)"]
            DNS["Private Corporate DNS\n(Internal Enterprise FQDNs)"]
            Istio["Istio Ingress Gateway (Port 443 / TLS)\n(Managed by Platform Team)"]
        end

        subgraph Tier3["Tier 3: Workload Layer (VTS Application Scope)"]
            direction TB
            subgraph AKS["Azure Kubernetes Service (AKS)"]
                NS["Namespace: lre-vts"]
                GW["Istio Gateway & VirtualService"]
                Pods["VTS Pods (app1-team, app2-team)"]
                PVC["Persistent Storage (Azure Managed Disk 'managed-csi')"]
                GW --> Pods
                Pods --- PVC
            end
        end
    end

    LG["Enterprise Load Generators / VuGen Workstations\n(Corporate LAN / DMZ)"] -->|ExpressRoute / Port 443| Istio
    Istio -->|VirtualService Routing| GW
    Net --- AKS
    ACR -.->|Immutable Digest Pull| Pods
```

### Key Enterprise Concepts:

| Term | What It Means | Impact on VTS |
| :--- | :--- | :--- |
| **Cloud Intake Portal** | The internal enterprise intake portal where teams initiate cloud hosting requests, budget reviews, and architecture reviews. | Initiates the onboarding assessment to determine hosting model and cloud costs. |
| **ELZ (Enterprise Landing Zone)** | A pre-architected, security-hardened Azure subscription foundation enforcing corporate guardrails, network routing, firewalls, and compliance policies. | VTS will deploy inside this landing zone; direct public internet ingress is blocked; all traffic routes via corporate ExpressRoute. |
| **Cloud Platform Team** | The central platform engineering group managing cloud operations, landing zones, and foundational infrastructure. | They review your Cloud Intake request and determine whether you receive a shared namespace or a dedicated cluster. |
| **Tier 1 / Tier 2 vs. Tier 3** | **Tier 1 & 2:** Core infrastructure (networking, subscriptions, IAM, platform policies). Owned by Cloud Platform Team.<br>**Tier 3:** Application workloads (Pods, Namespaces, Storage claims). Owned by application/DevOps teams. | You own the VTS application layer (Tier 3). You never have to build enterprise networks or configure ExpressRoute firewalls. |
| **Istio Ingress Gateway** | Enterprise service mesh ingress controller managing inbound HTTPS traffic, TLS termination, and L7 virtual routing. | Replaces the OpenShift `Route`. Ingress traffic is managed via Istio `Gateway` and `VirtualService` CRDs. |
| **Entra ID (Azure AD)** | Microsoft’s identity management platform. | Controls RBAC access for developers, pipeline service principals, and admin console access. |
| **Enterprise Artifactory / ACR** | Corporate private container registry (`enterprise-docker-release-local`). | The VTS Ubuntu image will be scanned (Xray/Defender) and pinned by immutable sha256 digest. |

---

## 3. The 3 Potential AKS Hosting Models

During the Cloud Intake / Architecture assessment, the platform team evaluates VTS against three models:

```mermaid
flowchart LR
    subgraph Model1["Model 1: Shared AKS (Namespace Only) - STRONGLY RECOMMENDED"]
        M1_Cluster["Shared AKS Cluster\n(Owned & Maintained by Cloud Platform Team)"]
        M1_NS["Assigned Namespace:\nlre-vts"]
        M1_VTS["VTS Pods & PVCs\n(Your Team Deploys Here)"]
        M1_Cluster --> M1_NS --> M1_VTS
    end

    subgraph Model2["Model 2: Dedicated AKS (Self-Managed)"]
        M2_TFE["Terraform Enterprise (TFE)\n(Platform-Approved Modules)"]
        M2_Cluster["Dedicated AKS Cluster\n(Your Team Provisions)"]
        M2_VTS["VTS Workloads\n(Your Team Manages)"]
        M2_TFE --> M2_Cluster --> M2_VTS
    end

    subgraph Model3["Model 3: Dedicated AKS (Platform-Managed / CRE)"]
        M3_Cloud Platform Team["Cloud Managed Service Team\n(Provisions & Patches Cluster)"]
        M3_Cluster["Dedicated Cluster"]
        M3_VTS["VTS Workload Access Only"]
        M3_Cloud Platform Team --> M3_Cluster --> M3_VTS
    end
```

### Detailed Comparison:

| Dimension | Model 1: Shared AKS (Namespace) | Model 2: Dedicated AKS (Self-Managed) | Model 3: Dedicated AKS (Platform-Managed) |
| :--- | :--- | :--- | :--- |
| **Recommendation for VTS** | **Highest (Strongly Recommended)** | Low (Avoid unless forced) | Medium (Only if isolation mandates it) |
| **What You Receive** | A pre-configured namespace (`lre-vts`) with RBAC access. | An empty Azure resource group + approved Terraform modules. | A ready dedicated cluster operated by a cloud managed service. |
| **What You Manage** | Only Kubernetes YAMLs (`kubectl apply`) + VTS application. | Terraform code to build cluster + node pool maintenance + VTS YAMLs. | Only Kubernetes YAMLs + VTS application. |
| **Cloud Skill Required** | **Low** (Exact same as your OpenShift experience). | **Moderate-High** (Requires Terraform + Azure CLI). | **Low-Moderate**. |
| **Cluster Upgrades** | Handled 100% by central platform team. | Your team must plan and execute node upgrades. | Handled by platform managed service. |
| **FinOps Cost** | Lowest compute cost (fraction of shared node pool). | High cost (dedicated control plane, minimum 3 VM nodes). | High cost (dedicated VMs + managed operations fee). |

---

## 4. 1-to-1 Translation: OpenShift (CRC) to Azure AKS

| Architecture Layer | OpenShift Local (What You Already Built) | Azure Kubernetes Service (AKS Equivalent) | Changes Needed in Manifests |
| :--- | :--- | :--- | :--- |
| **CLI Tool** | `oc` | `kubectl` (after running `az aks get-credentials`) | Commands are 100% identical (`kubectl get pods`, `kubectl apply`). |
| **Routing / Ingress** | OpenShift `Route` (`reencrypt` on port 443) | **Istio Ingress Gateway** (`Gateway` + `VirtualService`) or AGIC | Replace `vts-route.yaml` with Istio `Gateway` and `VirtualService` manifests. |
| **StorageClass** | `crc-csi-hostpath-provisioner` (RWO) | `managed-csi` (Azure Premium SSD Disk) | Change `storageClassName` in `vts-pvc.yaml` from local hostpath to `managed-csi`. |
| **Workload Specification** | `vts-deployment.yaml` (`Deployment`) | `vts-deployment.yaml` (`Deployment`) | Sizing, digest pinning, and hardened security context. |
| **Configuration & NGINX** | `vts-configmap.yaml` (`ConfigMap`) | `ConfigMap` (Config) + `Secret` (Credentials) | Separate passwords into a Kubernetes Secret. |
| **Non-Root Execution** | `securityContext: fsGroup: 54345` | `securityContext: runAsNonRoot: true`, `runAsUser: 54345`, `runAsGroup: 54345`, `allowPrivilegeEscalation: false` | Enforce explicit container security context to comply with Azure Policy Restricted Profile. |
| **Image Source** | `performancetesting/opentext_vts_linux_ubuntu:26.1` | `<corp-artifactory>/vts/opentext_vts_linux_ubuntu@sha256:<digest>` | Pin image to enterprise repository with immutable sha256 digest. |
| **Certificates** | Self-signed generated via inline openssl script | Corporate PKI certificate mounted via Kubernetes TLS Secret | Mount enterprise certificate read-only or terminate at Istio Ingress Gateway. |

---

## 5. Production-Grade AKS Manifest Templates (Component-Wise)

All Kubernetes resources are split into clean, component-wise YAML files in this directory.

### Apply Order & Component Inventory

| Order | File | Resource | Key AKS / Enterprise Notes |
| :---: | :--- | :--- | :--- |
| **1** | `vts-namespace-aks.yaml` | `Namespace` | Creates `lre-vts` (omit if Cloud Platform Team pre-provisions namespace). |
| **2** | `vts-pvc-aks.yaml` | `PersistentVolumeClaim` | Uses `managed-csi` (switch to approved ZRS StorageClass once Multi-AZ ZRS is available). |
| **3** | `vts-secret-aks.yaml` | `Secret` | Stores VTS credentials outside ConfigMaps (or sync from Key Vault CSI). |
| **4** | `vts-configmap-aks.yaml` | `ConfigMap` | `configure.json` + CVE-remediated `vts-nginx.conf` (`listen 8443 ssl;`). |
| **5** | `vts-deployment-aks.yaml` | `Deployment` | Hardened `securityContext` (`UID/GID 54345`, `runAsNonRoot: true`, `drop: [ALL]`) + `tcpSocket` probes. |
| **6** | `vts-service-aks.yaml` | `Service` | `ClusterIP` mapping port `443` → container port `8443`. |
| **7** | `vts-istio-ingress.yaml` | `Gateway` + `VirtualService` | Istio Ingress routing on port `443` with corporate TLS secret. |

> [!NOTE]
> **Live AKS (`v1.36.5`) Validation Findings:**
> - **Hardened `securityContext`:** Verified working with `runAsNonRoot: true`, `runAsUser: 54345`, `runAsGroup: 54345`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`, and `seccompProfile: RuntimeDefault`.
> - **Health Probes (`401` Discovery):** VTS Basic Auth returns `HTTP 401` on `/`, causing Kubernetes `httpGet` probes to fail. **`tcpSocket` on port `8443`** was validated and passes cleanly.
> - **Storage:** `managed-csi` binds cleanly under `Recreate` deployment strategy. Multi-AZ ZRS (`managed-csi-zrs`) requires a fresh PVC when enabled by the Cloud Platform Team.

### 5.1 AKS Persistent Volume Claim (`vts-pvc-aks.yaml`)
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vts-app1-data-pvc
  namespace: lre-vts
  labels:
    app: vts-app1-team
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi # Azure Premium SSD CSI driver for high-IOPS Valkey dumps
  resources:
    requests:
      storage: 30Gi
```

### 5.2 Kubernetes Secret for VTS Credentials (`vts-secret-aks.yaml`)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vts-app1-credentials
  namespace: lre-vts
type: Opaque
stringData:
  admin_user: "vtsadmin"
  admin_password: "*****"
  api_user: "vtsadmin"
  api_password: "*****"
```

### 5.3 Istio Ingress Gateway Routing (`vts-istio-ingress.yaml`)

When the cloud platform team provides an **Istio Ingress Gateway**, traffic routing is controlled using standard Istio CRDs:

```yaml
# 1. Istio Gateway: Binds to the platform Istio Ingress Controller on Port 443
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: vts-app1-gateway
  namespace: lre-vts
spec:
  selector:
    # Matches the platform-managed Istio Ingress Gateway pod label
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: vts-app1-enterprise-tls-cert # Secret containing corporate CA cert
    hosts:
    - "vts-app1.internal.cloud.corp"
---
# 2. Istio VirtualService: Routes traffic to the backend VTS Service
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: vts-app1-virtualservice
  namespace: lre-vts
spec:
  hosts:
  - "vts-app1.internal.cloud.corp"
  gateways:
  - vts-app1-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: vts-app1-team-service.lre-vts.svc.cluster.local
        port:
          number: 443 # Routes to in-container NGINX reverse-proxy
```

### 5.4 Hardened AKS Deployment (`vts-deployment-aks.yaml`)

This deployment strictly complies with **Azure Policy Restricted Profile** and the enterprise security standard:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vts-app1-team
  namespace: lre-vts
  labels:
    app: vts-app1-team
spec:
  replicas: 1
  strategy:
    type: Recreate # Ensures RWO persistent volume detaches cleanly before reattaching
  selector:
    matchLabels:
      app: vts-app1-team
  template:
    metadata:
      labels:
        app: vts-app1-team
    spec:
      # Pod-level security context
      securityContext:
        runAsNonRoot: true
        runAsUser: 54345
        runAsGroup: 54345
        fsGroup: 54345
        seccompProfile:
          type: RuntimeDefault

      containers:
      - name: vts-server
        # Fully qualified enterprise registry with immutable sha256 digest
        image: artifactory.internal.cloud.corp/enterprise-docker-release-local/vts/opentext_vts_linux_ubuntu@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        imagePullPolicy: IfNotPresent
        workingDir: /opt/OT/OT_VTS/web
        
        # Container-level security context (Passes Gatekeeper / Azure Policy checks)
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 54345
          runAsGroup: 54345
          capabilities:
            drop:
            - ALL

        env:
        - name: GIN_MODE
          value: "release"
        - name: VTS_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: vts-app1-credentials
              key: admin_password

        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"

        ports:
        - name: https-web
          containerPort: 8443

        # Use tcpSocket: 8443 because VTS Basic Auth returns HTTP 401 on /
        startupProbe:
          tcpSocket:
            port: 8443
          periodSeconds: 5
          failureThreshold: 24
        readinessProbe:
          tcpSocket:
            port: 8443
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        livenessProbe:
          tcpSocket:
            port: 8443
          periodSeconds: 20
          timeoutSeconds: 3
          failureThreshold: 3

        volumeMounts:
        - name: config-mount
          mountPath: /opt/OT/OT_VTS/web/configure.json
          subPath: configure.json
        - name: nginx-mount
          mountPath: /etc/nginx/nginx.conf
          subPath: vts-nginx.conf
        - name: vts-db-storage
          mountPath: /var/lib/OT/OT_VTS/db/data

      volumes:
      - name: config-mount
        configMap:
          name: vts-app1-config
          items:
          - key: configure.json
            path: configure.json
      - name: nginx-mount
        configMap:
          name: vts-app1-config
          items:
          - key: vts-nginx.conf
            path: vts-nginx.conf
      - name: vts-db-storage
        persistentVolumeClaim:
          claimName: vts-app1-data-pvc
```

---

## 6. Actionable 11-Step Production Gap Remediation Roadmap

Based on the architectural assessment, here is your exact checklist to transition VTS from POC to production AKS:

```mermaid
flowchart TD
    G1["1. Collect Project Controls\n(Intake Ticket, App ID, Security Risk Assessment, Budget)"] --> G2["2. Lock Operating Model\n(Advocate Shared AKS Namespace)"]
    G2 --> G3["3. Formalize Workload Architecture\n(1 replica, Recreate, RWO PVC)"]
    G3 --> G4["4. Enterprise Landing Zone Onboarding\n(Entra Groups, Bitbucket/Jenkins, TFE)"]
    G4 --> G5["5. Vendor Image Supply Chain\n(Mirror to Enterprise Artifactory with sha256)"]
    G5 --> G6["6. Security Policy Hardening\n(runAsNonRoot: true, runAsUser: 54345, drop ALL)"]
    G6 --> G7["7. Externalize Secrets\n(Move passwords from ConfigMap to Secret/Vault)"]
    G7 --> G8["8. Enterprise PKI Certificates\n(Replace self-signed openssl with corporate cert)"]
    G8 --> G9["9. Ingress Integration\n(Deploy Istio Gateway & VirtualService)"]
    G9 --> G10["10. Firewall & ExpressRoute Rules\n(Allow port 443 from Load Generators)"]
    G10 --> G11["11. Automated Smoke & Persistence Tests\n(Validate lrvtc_connect_ex & data recovery)"]
```

| Step # | Action Item | Technical Execution |
| :--- | :--- | :--- |
| **Step 1** | **Project Controls** | Secure the Cloud Intake ticket number, and ensure the business case is submitted for Enterprise FinOps review. |
| **Step 2** | **Operating Model** | Request a shared namespace (`lre-vts`) to eliminate the burden of managing dedicated cluster infrastructure. |
| **Step 3** | **Workload Model** | Submit the architecture input: Single-instance stateful design, 1 replica, `Recreate` deployment strategy, RWO persistent storage. |
| **Step 4** | **ELZ Onboarding** | Complete Day 1 onboarding for `<app-id> / VTS / <env>` (Entra ID security groups, CI/CD pipeline service principals). |
| **Step 5** | **Vendor Image Mirroring** | Push the official OpenText image into `enterprise-docker-release-local` and reference it by immutable digest (`@sha256:...`). |
| **Step 6** | **Security Hardening** | Add `runAsNonRoot: true`, `runAsUser: 54345`, `runAsGroup: 54345`, `allowPrivilegeEscalation: false`, and `capabilities: drop: [ALL]`. |
| **Step 7** | **Secret Management** | Remove hardcoded passwords from `configure.json` / `ConfigMap`; inject via Kubernetes Secret or Azure Key Vault CSI provider. |
| **Step 8** | **Corporate PKI** | Replace container-generated self-signed certificates with enterprise-issued TLS certificates bound to corporate private DNS. |
| **Step 9** | **Istio Ingress Gateway** | Apply Istio `Gateway` and `VirtualService` CRDs matching the platform Istio ingress gateway labels. |
| **Step 10** | **Network & Firewall** | Submit firewall requests allowing TCP port 443 from enterprise Load Generators / VuGen workstations over ExpressRoute to the Ingress IP. |
| **Step 11** | **Validation & Recovery** | Execute automated smoke tests with VuGen `lrvtc_connect_ex` and test pod deletion to verify Valkey data persists across restarts. |

---

## 7. Accelerated Learning Roadmap (Skip the Noise)

Do **NOT** spend 50 hours watching generic cloud courses. Your OpenShift experience already covers container fundamentals, YAML authoring, and pod debugging.

```mermaid
flowchart LR
    Step1["Step 1 (2h)\nAzure CLI & 'az aks get-credentials'"] --> Step2["Step 2 (2h)\nIstio Gateway & VirtualService"]
    Step2 --> Step3["Step 3 (1.5h)\nEnterprise Artifactory / ACR Pulls"]
    Step3 --> Step4["Step 4 (2h)\nAzure Managed Disks (managed-csi)"]
    Step4 -.->|Only if Dedicated Cluster Mandated| Step5["Step 5 (3h)\nTerraform Enterprise Modules"]
```

### Priority Study Checklist:

#### Topic 1: Azure CLI & Accessing AKS (2 hours)
- **Key Commands:**
  ```bash
  az login
  az account set --subscription "<Subscription-ID>"
  az aks get-credentials --resource-group "<RG-Name>" --name "<Cluster-Name>"
  kubectl get nodes
  kubectl get pods -n lre-vts
  ```
- **Takeaway:** Once `az aks get-credentials` is executed, all your daily work is 100% standard `kubectl`!

#### Topic 2: Istio Ingress Gateway & VirtualService (2 hours)
- How the Istio Ingress Gateway terminates TLS on port 443 and forwards traffic to internal Kubernetes Services.
- How `VirtualService` routes hostnames (`vts-app1.internal.cloud.corp`) and path prefixes.

#### Topic 3: Enterprise Image Management & Digest Pinning (1.5 hours)
- Understanding why enterprise security mandates image digests (`@sha256:...`) instead of floating tags (`:latest`, `:26.1`) to ensure immutability.

#### Topic 4: Azure Storage Architecture (2 hours)
- **Azure Managed Disk (`managed-csi`):** Best for single-pod stateful workloads like VTS where high IOPS and low-latency disk writes for Valkey RDB snapshots (`save 60 1`) are critical. Fast and reliable.
- **Azure Files (`azurefile-csi`):** Supports `ReadWriteMany` (RWX) if multiple pods ever need shared access.

#### Topic 5: Terraform on Azure (Only if Model 2 is chosen)
- If your team is handed an empty subscription and asked to provision AKS:
  - Focus on consuming the **pre-approved corporate Terraform modules** from the platform team.
  - You do not write Terraform from scratch; you pass input variables (VNet ID, Subnet ID, Cluster Name) to their private module.

---

## 8. Strategic Questions to Ask Your Cloud & Architecture Team

When you meet with your enterprise architect, cloud lead, or Cloud Platform Team representative, asking these precise questions will establish technical authority and clarify your exact scope immediately:

### Question 1: Hosting Model & Cluster Ownership
> *"In the Cloud Intake assessment for VTS, are we being onboarded to an existing shared AKS cluster (Namespace-as-a-Service for VTS), or is architecture mandating a dedicated AKS cluster for VTS due to stateful disk and network isolation requirements?"*

### Question 2: Istio Ingress Gateway Integration
> *"Since the platform team utilizes Istio Ingress Gateway, will our namespace receive an approved Istio `Gateway` resource, or should we define a namespace-scoped `VirtualService` binding to the central `istio-system/ingressgateway`?"*

### Question 3: StorageClass & IOPS
> *"Which CSI StorageClass is approved for stateful workloads in our Landing Zone (`managed-csi` Premium SSD or `azurefile-csi`)? VTS requires persistent local volume attachments for real-time Valkey snapshots."*

### Question 4: Container Registry & Image Vulnerability Scanning
> *"What is the approved procedure to mirror the vendor VTS base image into our enterprise Artifactory repository (`enterprise-docker-release-local`), and what vulnerability scanning gate (Xray, Prisma, Defender) must it clear before deployment?"*

### Question 5: DNS & ExpressRoute Connectivity
> *"Will the VTS Ingress Gateway IP be mapped to a Private Corporate DNS entry (e.g., `vts-app1.internal.cloud.corp`) reachable over our corporate ExpressRoute connection from on-premises Load Generators and tester workstations?"*

---

## 9. Multi-AZ High Availability (ZRS) vs. Regional Disaster Recovery (DR)

Because VTS is a stateful, single-replica (`replicas: 1`, `strategy: Recreate`) workload using a `ReadWriteOnce` PVC, **High Availability (Multi-AZ)** and **Disaster Recovery (Multi-Region)** operate at two distinct layers:

```mermaid
flowchart TD
    subgraph Region1["Primary Azure Region"]
        direction LR
        subgraph Z1["Availability Zone 1 (Fails)"]
            N1["AKS Node 1 (NotReady)"]
            P1["Old VTS Pod (Evicted)"]
        end
        subgraph Z2["Availability Zone 2 (Healthy)"]
            N2["AKS Node 2 (Ready)"]
            P2["New VTS Pod (Scheduled)"]
        end
        ZRS["Single ZRS Managed Disk\n(Synchronously replicated across Zones 1, 2, 3)"]
        ZRS -.->|Detached from Zone 1| P1
        ZRS ==>|Reattached in Zone 2 (RPO = 0)| P2
    end

    subgraph Region2["Secondary / DR Region"]
        BackupVault["Geo-Redundant Backup Vault (GRS)\n(Scheduled Snapshots via Azure Backup / Velero)"]
        DR_AKS["DR AKS Cluster + Restored PVC"]
        BackupVault -->|DR Restore| DR_AKS
    end

    ZRS -.->|Scheduled Async Snapshot| BackupVault
```

### Key Architectural Rules:
1. **Node Distribution (1 Node Per Zone):**
   - For a Dedicated AKS cluster to survive a zone failure, you need **at least 1 node per Availability Zone** (typically **3 nodes across Zones 1, 2, and 3**).
   - On a Shared AKS platform, the Cloud Platform Team already maintains multi-zone node pools across Zones 1, 2, and 3.
2. **StorageClass (`LRS` vs. `ZRS`):**
   - Standard `managed-csi` (**LRS**) pins the disk to a single Availability Zone. If that zone fails, the pod cannot attach the disk in another zone.
   - Multi-AZ failover requires a **ZRS StorageClass** (e.g., `managed-csi-zrs`), which synchronously replicates writes across 3 zones (`RPO = 0`).
   - *Note:* Kubernetes does not allow changing `storageClassName` on an existing bound PVC in-place; migrating from `LRS` to `ZRS` requires creating fresh ZRS PVCs.
3. **Regional DR:**
   - ZRS does **not** replicate across Azure regions. Regional disaster recovery or table corruption recovery relies on scheduled **Azure Backup for AKS / Velero** snapshots stored in a **Geo-Redundant (GRS)** vault in the paired DR region.

| Failure Scenario | Protection Mechanism | Data Loss (RPO) | Recovery |
| :--- | :--- | :--- | :--- |
| **Pod crash / node reboot** | `Recreate` + `managed-csi` PVC | **0** (data on disk) | Automatic (~30–60s) |
| **1 Availability Zone outage** | **Multi-AZ ZRS StorageClass** (`managed-csi-zrs`) + 1 node/zone | **0** (synchronous 3-zone copy) | Automatic (~2–5 mins) |
| **Full Azure Region outage / DB corruption** | **Scheduled PVC Backups** (Azure Backup / Velero → GRS) | Snapshot interval (e.g., 1h / 24h) | Restore PVC from snapshot |

---

## 10. Sandbox Repro & Live Validation Record

All core workload mechanics were validated live on **Azure AKS (`v1.36.5`, `Standard_D2s_v3`, `managed-csi`)**:
- **Pod Security:** `runAsNonRoot: true`, `runAsUser: 54345`, `runAsGroup: 54345`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`, and `seccompProfile: RuntimeDefault` passed cleanly.
- **Health Probes:** Discovered VTS Basic Auth returns `HTTP 401` on `/` (failing `httpGet` probes); validated `tcpSocket` on port `8443` for `startupProbe`, `readinessProbe`, and `livenessProbe`.
- **Persistence:** Deleted and recreated the running VTS pod; verified `managed-csi` Azure Disk reattached and preserved both VTS table data and the `2000` port instance in `instances.json`.
- **Repro Script:** Complete standalone commands for spinning up and validating in a fresh AKS sandbox are saved in [`kodekloud_aks_repro_commands.txt`](kodekloud_aks_repro_commands.txt).

---

## 11. TLS Certificates & AES Encryption Standard

| Environment | Certificate Source | How It Is Provided |
| :--- | :--- | :--- |
| **Sandbox (`kodekloud_aks_repro_commands.txt`)** | Self-signed (`openssl`) | Container startup script generates `/opt/OT/OT_VTS/web/vts.crt` and `vts.key` on boot (`/CN=vts-app1.aks.test`). |
| **Enterprise AKS (Production)** | **Enterprise PKI / Corporate CA** | **Remove** `openssl` self-signed generation. Issue CA-signed certificate for the corporate FQDN and sync via Azure Key Vault / `cert-manager` into Kubernetes TLS Secrets. |

### Recommended Certificate & Encryption Profile
- **Certificate Format & Type:** `kubernetes.io/tls` Secret (`X.509` PEM `tls.crt` and `tls.key`, **RSA-2048/4096** or **ECDSA P-256**).
- **TLS Protocols:** **TLS 1.2** and **TLS 1.3** only (TLS 1.0/1.1 disabled).
- **AES Encryption Ciphers:** **AES-256-GCM** and **AES-128-GCM** (`ECDHE-ECDSA-AES256-GCM-SHA384`, `ECDHE-RSA-AES256-GCM-SHA384`, `ECDHE-ECDSA-AES128-GCM-SHA256`, `ECDHE-RSA-AES128-GCM-SHA256`).
- **Two Placement Points:**
  1. **Istio Ingress Gateway (`vts-istio-ingress.yaml`):** `credentialName: vts-app1-enterprise-tls-cert` (external TLS facing Load Generators & browsers).
  2. **Backend VTS NGINX (`vts-deployment-aks.yaml` & `vts-configmap-aks.yaml`):** Mounted read-only from `vts-app1-tls-cert` at `/opt/OT/OT_VTS/web/certs/tls.crt` & `tls.key` (when TLS re-encryption to port `8443` is enabled).

```bash
# Example: Create Kubernetes TLS Secret from Enterprise CA-signed cert & key
kubectl create secret tls vts-app1-tls-cert -n lre-vts \
  --cert=vts-app1.crt \
  --key=vts-app1.key
```

