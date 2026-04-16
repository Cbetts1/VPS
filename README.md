# VPS — Recursive Virtualization Chain

A fully automated, recursive virtualization system that bootstraps from a phone all the way to a self-managing virtual cloud OS.

```
Phone → VM₁ → VM₂ (×4 doublings) → VPS → vCloud → vOS
```

---

## Architecture

See [`architecture/diagrams.md`](architecture/diagrams.md) for full ASCII diagrams.

```
Phone
 └─ VM₁  (Alpine/QEMU — only purpose: build VM₂)
     └─ VM₂  (validates → rebuilds itself 4× doubling specs → builds VPS)
         └─ VPS  (vHost + vCPU + vOS + vServer + vCloud layer)
             └─ vCloud  (nodes, routers, storage, compute, VPS spawner)
                 └─ vOS  (kernel, services, vFS, vNet, vpkg, API gateway)
```

---

## Quick Start

### 1 — On your phone (or any ARM/ARM64/x86_64 Linux host)

```sh
# Detect host capabilities and install QEMU if needed
sh layer0-phone/detect-host.sh

# Build and launch VM₁
sh layer0-phone/build-vm1.sh
```

### 2 — Inside VM₁ (SSH to localhost:10022)

```sh
ssh -p 10022 root@localhost
sh /mnt/host-scripts/build-vm2.sh
```

### 3 — Inside VM₂ (automatically runs rebuild loop)

VM₂ runs `rebuild-self.sh` automatically via cloud-init.  
It doubles its specs 4 times then calls `build-vps.sh`.

### 4 — VPS is running (SSH :10080 / API :10081 / Web :10082)

```sh
ssh -p 10080 root@localhost
curl http://localhost:10081/api/status
open http://localhost:10082
```

### 5 — vCloud operations (inside VPS)

```sh
sh layer4-vcloud/virtual-nodes.sh create node1 2 512 8
sh layer4-vcloud/spawn-vps.sh vps2 2 1024 8
```

### 6 — vOS boot (inside vCloud node or VPS)

```sh
sh layer5-vos/boot/sequence.sh
curl http://localhost:9000/vos/status
```

---

## Validate Everything

```sh
sh validate/validate-all.sh
```

Expected output: `8/8 passed — ALL CHECKS PASSED`

---

## Directory Structure

```
.
├── architecture/
│   └── diagrams.md            ← ASCII architecture diagrams
│
├── layer0-phone/
│   ├── detect-host.sh         ← Detect ARM/KVM/QEMU capabilities
│   └── build-vm1.sh           ← Launch VM₁ from phone
│
├── layer1-vm1/
│   ├── cloud-init/
│   │   ├── user-data          ← VM₁ auto-config
│   │   └── meta-data
│   ├── spec-evaluator.sh      ← Read VM₁ specs → derive VM₂ starting specs
│   ├── self-update.sh         ← git pull + re-exec
│   ├── vm-builder.sh          ← Low-level QEMU VM creator
│   └── build-vm2.sh           ← VM₁ mission: create VM₂
│
├── layer2-vm2/
│   ├── validate-env.sh        ← Pre-flight checks
│   ├── version-counter.sh     ← Persistent rebuild counter
│   ├── doubling-spec.sh       ← Compute doubled specs for each version
│   ├── rebuild-self.sh        ← Self-rebuild loop (stops at cap v4)
│   └── build-vps.sh           ← VM₂ mission: create VPS
│
├── layer3-vps/
│   ├── vhost/
│   │   ├── setup-filesystem.sh
│   │   └── boot-scripts/boot.sh
│   ├── vcpu/
│   │   └── instruction-engine.sh
│   ├── vos-kernel/
│   │   ├── services.sh
│   │   └── package-manager.sh
│   ├── vserver/
│   │   └── apps.sh            ← Python REST API + web console
│   ├── vcloud-layer/
│   │   └── networking.sh      ← Bridge + WireGuard overlay
│   └── expose/
│       ├── ssh-setup.sh
│       ├── api-endpoint.sh    ← :8080
│       └── web-console.sh     ← :80
│
├── layer4-vcloud/
│   ├── virtual-nodes.sh       ← CRUD for vCloud nodes
│   ├── virtual-routers.sh     ← Network namespace routers
│   ├── virtual-storage.sh     ← qcow2 storage pools
│   ├── virtual-compute.sh     ← Compute pool manager
│   └── spawn-vps.sh           ← Spawn new VPS instances
│
├── layer5-vos/
│   ├── kernel/layout.sh       ← /vos directory tree + proc mounts
│   ├── service-manager/services.sh
│   ├── filesystem/vfs.sh      ← qcow2-backed virtual mounts
│   ├── networking/vnet.sh     ← Virtual bridges + NAT
│   ├── package-manager/vpkg.sh
│   ├── boot/sequence.sh       ← Full vOS boot sequence
│   └── api-gateway/gateway.sh ← Python HTTP gateway :9000
│
└── validate/
    ├── validate-layer.sh      ← Validate one layer
    └── validate-all.sh        ← Validate all layers + spec/version tests
```

---

## VM₂ Doubling Spec Table

| Version | vCPU | vRAM   | vDisk  | At Cap |
|---------|------|--------|--------|--------|
| 0       | 1    | 512 MB | 4 GB   | no     |
| 1       | 2    | 1 GB   | 8 GB   | no     |
| 2       | 4    | 2 GB   | 16 GB  | no     |
| 3       | 8    | 4 GB   | 32 GB  | no     |
| 4+      | 16   | 16 GB  | 256 GB | yes    |

---

## Design Principles

- **All open-source**: Alpine Linux, QEMU/KVM, WireGuard, nginx, Python
- **All idempotent**: every script is safe to run multiple times
- **All automated**: no manual steps — cloud-init drives every VM
- **Recursive**: each layer creates the next without human intervention
- **Portable**: runs on ARM, ARM64, or x86_64 with QEMU TCG or KVM
