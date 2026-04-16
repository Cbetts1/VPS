# Recursive Virtualization Chain — Architecture Diagrams

## Full System Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  PHONE (Base Machine)                                                    │
│  ARM / ARM64  ·  QEMU user-mode or KVM                                  │
│                                                                          │
│  layer0-phone/detect-host.sh  ──►  layer0-phone/build-vm1.sh            │
│                                          │                               │
│                                          ▼                               │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  VM₁  (Minimal Alpine Linux, QEMU)                               │   │
│  │  Purpose: BUILD VM₂ — nothing else                               │   │
│  │                                                                   │   │
│  │  ├── vm-builder.sh        (creates QEMU disk + launches VM₂)     │   │
│  │  ├── spec-evaluator.sh    (reads /etc/vm1-specs.conf)            │   │
│  │  ├── self-update.sh       (git pull + re-exec)                   │   │
│  │  └── build-vm2.sh         (orchestrates VM₂ creation)           │   │
│  │                                 │                                │   │
│  │                                 ▼                                │   │
│  │  ┌────────────────────────────────────────────────────────────┐  │   │
│  │  │  VM₂  (Recursive Builder, QEMU inside VM₁)               │  │   │
│  │  │  Purpose: VALIDATE → REBUILD → DOUBLE SPECS → BUILD VPS  │  │   │
│  │  │                                                            │  │   │
│  │  │  ├── validate-env.sh   (CPU / RAM / disk checks)          │  │   │
│  │  │  ├── rebuild-self.sh   (recreates itself from scratch)    │  │   │
│  │  │  ├── doubling-spec.sh  (×2 vCPU, vRAM, vDisk each run)   │  │   │
│  │  │  ├── version-counter.sh (persists /etc/vm2-version)       │  │   │
│  │  │  └── build-vps.sh      (produces the VPS artifact)        │  │   │
│  │  │                               │                            │  │   │
│  │  │                               ▼                            │  │   │
│  │  │  ┌─────────────────────────────────────────────────────┐  │  │   │
│  │  │  │  VPS  (Software-Defined, self-contained)           │  │  │   │
│  │  │  │                                                     │  │  │   │
│  │  │  │  ├── vHost   (rootfs + boot scripts)               │  │  │   │
│  │  │  │  ├── vCPU    (QEMU instruction engine)             │  │  │   │
│  │  │  │  ├── vOS     (services, routing, pkg manager)      │  │  │   │
│  │  │  │  ├── vServer (app layer)                           │  │  │   │
│  │  │  │  └── vCloud  (virtual networking + nodes)          │  │  │   │
│  │  │  │                                                     │  │  │   │
│  │  │  │  Exposes: SSH · REST API · Web Console             │  │  │   │
│  │  │  │                │                                    │  │  │   │
│  │  │  │                ▼                                    │  │  │   │
│  │  │  │  ┌──────────────────────────────────────────────┐  │  │  │   │
│  │  │  │  │  vCloud Layer                               │  │  │  │   │
│  │  │  │  │                                             │  │  │  │   │
│  │  │  │  │  ├── Virtual Nodes                         │  │  │  │   │
│  │  │  │  │  ├── Virtual Routers (WireGuard/VXLAN)     │  │  │  │   │
│  │  │  │  │  ├── Virtual Storage (qcow2 pools)         │  │  │  │   │
│  │  │  │  │  ├── Virtual Compute Pools                 │  │  │  │   │
│  │  │  │  │  └── VPS Spawner                           │  │  │  │   │
│  │  │  │  │                │                            │  │  │  │   │
│  │  │  │  │                ▼                            │  │  │  │   │
│  │  │  │  │  ┌───────────────────────────────────────┐ │  │  │  │   │
│  │  │  │  │  │  vOS  (runs inside vCloud)           │ │  │  │  │   │
│  │  │  │  │  │                                      │ │  │  │  │   │
│  │  │  │  │  │  ├── Kernel layout                  │ │  │  │  │   │
│  │  │  │  │  │  ├── Service manager (OpenRC)        │ │  │  │  │   │
│  │  │  │  │  │  ├── Virtual filesystem              │ │  │  │  │   │
│  │  │  │  │  │  ├── Virtual networking              │ │  │  │  │   │
│  │  │  │  │  │  ├── Package manager (apk/vpkg)      │ │  │  │  │   │
│  │  │  │  │  │  ├── Boot sequence                   │ │  │  │  │   │
│  │  │  │  │  │  └── API Gateway (nginx + lua)       │ │  │  │  │   │
│  │  │  │  │  └───────────────────────────────────────┘ │  │  │  │   │
│  │  │  │  └──────────────────────────────────────────────┘  │  │  │   │
│  │  │  └─────────────────────────────────────────────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

## VM₂ Recursive Doubling State Machine

```
         ┌──────────────┐
         │  VM₂ start   │
         └──────┬───────┘
                │
                ▼
        ┌───────────────┐
        │ read version  │◄─────────────────────────────┐
        │ /etc/vm2-ver  │                              │
        └──────┬────────┘                              │
               │                                       │
               ▼                                       │
        ┌───────────────┐   yes   ┌──────────────────┐│
        │ version ≥ MAX?├────────►│ proceed to BUILD ││
        └──────┬────────┘         │ VPS (no more     ││
               │ no               │ doubling)        ││
               ▼                  └──────────────────┘│
        ┌───────────────┐                             │
        │ validate env  │                             │
        └──────┬────────┘                             │
               │                                      │
               ▼                                      │
        ┌───────────────┐                             │
        │ double specs: │                             │
        │ vCPU ×2       │                             │
        │ vRAM ×2       │                             │
        │ vDisk ×2      │                             │
        └──────┬────────┘                             │
               │                                      │
               ▼                                      │
        ┌───────────────┐                             │
        │ rebuild self  │                             │
        │ (new QEMU vm) │                             │
        └──────┬────────┘                             │
               │                                      │
               ▼                                      │
        ┌───────────────┐                             │
        │ version += 1  ├─────────────────────────────┘
        └───────────────┘

  Starting specs:  vCPU=1  vRAM=512M  vDisk=4G
  Doubling cap:    vCPU=16 vRAM=16G   vDisk=256G  (version ≥ 4)
```

## VPS Internal Layer Stack

```
  ╔══════════════════════════════════════╗
  ║            VPS (port 22/80/8080)     ║
  ╠══════════════════════════════════════╣
  ║  vServer   │  app processes          ║
  ╠══════════════════════════════════════╣
  ║  vOS       │  services · pkg mgr     ║
  ╠══════════════════════════════════════╣
  ║  vCPU      │  QEMU instruction eng   ║
  ╠══════════════════════════════════════╣
  ║  vHost     │  rootfs · boot scripts  ║
  ╚══════════════════════════════════════╝
           ↕  vCloud overlay
  ╔══════════════════════════════════════╗
  ║  vCloud  │  nodes · routers · store  ║
  ╠══════════════════════════════════════╣
  ║  vOS     │  kernel · api-gateway     ║
  ╚══════════════════════════════════════╝
```

## Network Topology

```
  Phone ──(NAT/USB tethering)──► VM₁ (192.168.100.2)
                                   │
                              QEMU bridge br-vm
                                   │
                                 VM₂ (192.168.101.2)
                                   │
                              QEMU bridge br-vps
                                   │
                                 VPS  (192.168.102.2)
                                 │ SSH :22
                                 │ API :8080
                                 │ WEB :80
                                   │
                              VXLAN overlay vxlan0
                                   │
                               vCloud nodes
                                   │
                              vOS API gateway :9000
```
