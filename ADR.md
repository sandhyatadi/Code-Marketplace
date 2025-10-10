# ADR: Code Marketplace Deployment Strategy

## Deployment Approaches Overview

There are **two fundamental approaches** for deploying code-marketplace:

1. **Binary Download Method**: Download binary at runtime via initContainer
2. **Docker Image Method**: Use pre-built Docker image

For Docker Image method, there are **two deployment tools**:
- **kubectl**: Manual YAML management
- **Helm**: Managed deployment with lifecycle features

```mermaid
graph TB
    A[Code Marketplace Deployment]

    A --> B[1. Binary Download Method]
    A --> C[2. Docker Image Method]

    B --> B1[initContainer downloads binary]
    B1 --> B2[Security: ❌ Poor]

    C --> C1{Deployment Tool}

    C1 --> D[kubectl - Manual YAML]
    C1 --> E[Helm - Managed Lifecycle]

    D --> F[Same Docker Image]
    E --> F

    F --> G[Same Kubernetes Pods]

    C --> C2[Image Source]
    C2 --> H[Public Registry: ghcr.io]
    C2 --> I[Private Registry: ECR/Artifactory]

    style B2 fill:#ffcccc
    style I fill:#ccffcc
    style G fill:#e6f3ff
```

---

## Option 1: Runtime Binary Download (initContainer)

Download the code-marketplace binary from GitHub at pod startup.

```mermaid
graph LR
    A[Pod Starts] --> B[initContainer: wget binary from GitHub]
    B --> C[Main Container: Run binary]
    C --> D[Serve Extensions]

    style B fill:#ff9999
```

**Implementation**:
```yaml
initContainers:
- name: download-binary
  image: alpine:latest
  command:
    - wget https://github.com/coder/code-marketplace/releases/download/v2.4.0/code-marketplace-linux-amd64
    - chmod +x /tmp/code-marketplace

containers:
- name: code-marketplace
  image: alpine:latest
  command: [/tmp/code-marketplace, server, --extensions-dir=/extensions]
```

**Pros**:
- Simple implementation
- No Docker image registry needed
- Minimal setup

**Cons**:
- Runtime download from public internet
- No image scanning/vulnerability assessment
- Binary not verified or approved
- Network dependency at pod startup
- Re-downloads on every pod restart
- Fails if GitHub is unreachable

**Security Considerations**:
- ❌ No supply chain verification
- ❌ No security scanning
- ❌ Runtime internet access required
- ❌ No approval workflow
- ❌ Binary could be compromised during download
- ❌ No version pinning guarantees

**Compliance**: ❌ **FAILS** - Violates most enterprise security policies

---

## Option 2: Docker Image Method

Use the official Docker image that contains the pre-compiled binary.

**Image**: `ghcr.io/coder/code-marketplace:v2.4.0`

### Option 2A: Deploy with kubectl (Manual YAML)

Manually write Kubernetes YAML files and deploy with kubectl.

```mermaid
graph LR
    A[Write YAML Files] --> B[kubectl apply]
    B --> C[Pull Image from Registry]
    C --> D[Deploy Pod]
    D --> E[Serve Extensions]

    style C fill:#ffcc99
```

**Implementation**:
```yaml
# code-marketplace-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: code-marketplace
  namespace: coder
spec:
  template:
    spec:
      containers:
      - name: code-marketplace
        image: ghcr.io/coder/code-marketplace:v2.4.0
        args: [server, --extensions-dir=/extensions, --address=0.0.0.0:8080]
        volumeMounts:
        - name: extensions
          mountPath: /extensions
      volumes:
      - name: extensions
        persistentVolumeClaim:
          claimName: marketplace-extensions
---
apiVersion: v1
kind: Service
metadata:
  name: code-marketplace
  namespace: coder
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
```

**Deploy**:
```bash
kubectl apply -f code-marketplace-deployment.yaml
```

**Pros**:
- Simple and direct
- Full control over YAML
- No additional tools needed
- Easy to understand

**Cons**:
- Manual version management
- No built-in rollback mechanism
- Configuration changes require YAML edits
- No deployment history tracking

### Option 2B: Deploy with Helm (Managed Lifecycle)

Use official Helm chart for managed deployment.

```mermaid
graph LR
    A[Helm Chart] --> B[helm install/upgrade]
    B --> C[Pull Image from Registry]
    C --> D[Deploy Pod]
    D --> E[Serve Extensions]

    style B fill:#99ccff
```

**Implementation**:
```bash
# Clone Helm chart repository
git clone --depth 1 https://github.com/coder/code-marketplace

# Deploy with Helm
helm upgrade --install code-marketplace ./code-marketplace/helm \
  --namespace coder \
  --set image.repository=ghcr.io/coder/code-marketplace \
  --set image.tag=v2.4.0 \
  --set persistence.size=50Gi
```

**Pros**:
- Official chart from vendor (maintained by Coder)
- Easy configuration via values.yaml or --set
- Built-in version management
- Simple rollback: `helm rollback code-marketplace`
- Deployment history tracking
- GitOps compatible

**Cons**:
- Requires cloning GitHub repo for Helm chart
- Additional complexity (Helm knowledge needed)
- Default port is 80 (not 8080)

**Note**: Helm chart uses **port 80** by default, not 8080. Update workspace templates accordingly.

---

## Recommended Production Approach

### Private Registry Mirror (kubectl or Helm)

Mirror the official image to your private registry for security and compliance.

```mermaid
graph TB
    subgraph "One-Time Setup"
        A[Pull from ghcr.io] --> B[Security Scan<br/>Trivy/Anchore]
        B --> C[Security Approval]
        C --> D[Push to ECR/Artifactory]
    end

    subgraph "Runtime Deployment"
        E[Deploy via kubectl or Helm] --> F[Pull from Private Registry]
        F --> G[Deploy Pod]
        G --> H[Serve Extensions]
    end

    D -.->|Image Available| F

    style B fill:#99ff99
    style C fill:#99ff99
    style F fill:#99ff99
```

**One-time setup**:
```bash
# Pull official image
docker pull ghcr.io/coder/code-marketplace:v2.4.0

# Scan with internal tools
trivy image ghcr.io/coder/code-marketplace:v2.4.0

# Tag for private registry
docker tag ghcr.io/coder/code-marketplace:v2.4.0 \
  123456789.dkr.ecr.us-east-1.amazonaws.com/code-marketplace:v2.4.0

# Push to private registry
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/code-marketplace:v2.4.0
```

**Deploy with kubectl**:
```yaml
containers:
- name: code-marketplace
  image: 123456789.dkr.ecr.us-east-1.amazonaws.com/code-marketplace:v2.4.0
```

**Deploy with Helm**:
```bash
helm upgrade --install code-marketplace ./code-marketplace/helm \
  --namespace coder \
  --set image.repository=123456789.dkr.ecr.us-east-1.amazonaws.com/code-marketplace \
  --set image.tag=v2.4.0
```

---

## How Code Marketplace Works

### Architecture Overview

```mermaid
graph TB
    subgraph "EKS Cluster - Namespace: coder"
        subgraph "Coder Platform"
            CoderPod[Coder Server Pod]
            RDS[(RDS PostgreSQL)]
        end

        subgraph "Code Marketplace"
            MarketPod[code-marketplace Pod<br/>Port: 80 or 8080]
            MarketPVC[PVC: Extensions Storage<br/>50Gi]
            MarketSvc[Service: code-marketplace<br/>ClusterIP]
        end

        subgraph "User Workspace"
            WorkPod[Workspace Pod]
            CodeServer[code-server<br/>VS Code in Browser]
        end
    end

    CoderPod --> RDS
    CoderPod -.->|Provisions| WorkPod

    WorkPod --> MarketSvc
    MarketSvc --> MarketPod
    MarketPod --> MarketPVC

    CodeServer -->|EXTENSIONS_GALLERY env var| MarketSvc
```

### Extension Installation Flow

```mermaid
sequenceDiagram
    participant Admin
    participant Marketplace
    participant Storage
    participant User
    participant Workspace
    participant CodeServer

    Note over Admin,Storage: Phase 1: Admin Populates Extensions
    Admin->>Marketplace: kubectl exec - add extension
    Marketplace->>Marketplace: Download .vsix from Open VSX
    Marketplace->>Storage: Unpack extension to /extensions
    Marketplace->>Storage: Update index

    Note over User,CodeServer: Phase 2: User Installs Extension
    User->>Workspace: Create workspace from template
    Workspace->>Workspace: Set EXTENSIONS_GALLERY env var
    Workspace->>CodeServer: Start code-server
    CodeServer->>CodeServer: Read EXTENSIONS_GALLERY

    User->>CodeServer: Search for extension
    CodeServer->>Marketplace: POST /api/extensionquery
    Marketplace->>Storage: Query extension index
    Storage-->>Marketplace: Extension metadata
    Marketplace-->>CodeServer: Extension list (JSON)
    CodeServer-->>User: Display extensions

    User->>CodeServer: Click Install
    CodeServer->>Marketplace: GET /files/{publisher}/{name}/{version}
    Marketplace->>Storage: Read .vsix file
    Storage-->>Marketplace: .vsix binary
    Marketplace-->>CodeServer: .vsix file
    CodeServer->>CodeServer: Install extension
    CodeServer-->>User: Extension installed ✅
```

### Step-by-Step Process

#### 1. Deploy Code Marketplace

**Via kubectl**:
```bash
kubectl apply -f code-marketplace-deployment.yaml
```

**Via Helm**:
```bash
helm upgrade --install code-marketplace ./code-marketplace/helm --namespace coder
```

This creates:
- Pod running code-marketplace binary
- Service (ClusterIP) for internal access
- PVC for extension storage

#### 2. Populate Extensions

Admin adds extensions to the marketplace:

```bash
# Get marketplace pod name
MARKETPLACE_POD=$(kubectl get pods -n coder -l app.kubernetes.io/name=code-marketplace -o jsonpath='{.items[0].metadata.name}')

# Add extension from Open VSX
kubectl exec -n coder $MARKETPLACE_POD -- \
  /opt/code-marketplace add \
  "https://open-vsx.org/api/vscodevim/vim/1.27.2/file/vscodevim.vim-1.27.2.vsix" \
  --extensions-dir /extensions
```

**What happens**:
1. Downloads `.vsix` file from Open VSX (open-source extension registry)
2. Unpacks extension to `/extensions/{publisher}/{name}/{version}/`
3. Updates marketplace index for API queries

**Extension storage structure**:
```
/extensions/
├── vscodevim/
│   └── vim/
│       └── 1.27.2/
│           ├── extension/
│           │   ├── package.json
│           │   ├── README.md
│           │   └── ... (extension files)
│           └── vscodevim.vim-1.27.2.vsix
```

#### 3. Configure Coder Templates

Update workspace templates to use private marketplace by adding `EXTENSIONS_GALLERY` environment variable:

```hcl
resource "coder_agent" "main" {
  env = {
    # Important: Port must match marketplace service port
    # Helm chart uses port 80
    EXTENSIONS_GALLERY = jsonencode({
      serviceUrl          = "http://code-marketplace.coder.svc.cluster.local:80/api"
      itemUrl            = "http://code-marketplace.coder.svc.cluster.local:80/item"
      resourceUrlTemplate = "http://code-marketplace.coder.svc.cluster.local:80/files/{publisher}/{name}/{version}/{path}"
    })
  }
}
```

**Port Configuration**:
- **Helm chart default**: Port 80
- **Manual kubectl YAML**: Often uses port 8080 (customizable)
- **Critical**: Template must match the actual service port

**DNS Resolution**:
- Format: `{service-name}.{namespace}.svc.cluster.local`
- Example: `code-marketplace.coder.svc.cluster.local`
- Kubernetes CoreDNS resolves this automatically (no external DNS needed)

#### 4. Deploy Templates

```bash
cd template-promoter
terraform apply
```

This updates Coder templates to include the `EXTENSIONS_GALLERY` configuration.

#### 5. User Creates Workspace

1. User creates workspace from template via Coder UI
2. Workspace pod starts with `EXTENSIONS_GALLERY` environment variable
3. code-server reads the env var and redirects extension requests to private marketplace

#### 6. User Installs Extensions

**In code-server**:
1. User opens Extensions panel
2. Searches for extension (e.g., "vim")
3. code-server queries marketplace via `POST /api/extensionquery`
4. Marketplace returns list of available extensions
5. User clicks Install
6. code-server downloads `.vsix` from marketplace via `GET /files/{publisher}/{name}/{version}`
7. Extension installs in workspace

**Network flow**:
```
Workspace Pod → DNS Resolution → Service (code-marketplace) → Marketplace Pod → PVC Storage
```

All communication is **internal** (ClusterIP) - no external traffic.

---
