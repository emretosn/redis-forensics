# Redis Forensic-Readiness Lab on Azure

Infrastructure-as-Code (Bicep) for a small Azure lab that reproduces the
forensic-readiness setup described in **"Database Forensics Readiness: An
Examination of Redis"** (Zia & Adedayo, *ISDFS 2026*), focusing on the
**Section VI — Discussion of Findings** recommendations.

## What this builds

Three Ubuntu 22.04 VMs (`Standard_B1s`) in a single VNet in `westeurope`:

| VM             | Role                                                            | Public IP |
| -------------- | -------------------------------------------------------------- | --------- |
| `redis-vm`     | Redis installed **in the VM**, configured as a forensic source | No        |
| `client-vm`    | Issues CRUD requests to Redis using ACL role users             | Yes (SSH) |
| `forensics-vm` | Collector — receives forensic files pushed from `redis-vm`     | Yes (SSH) |

```
   client-vm ──6379──▶ redis-vm ──rsync/ssh timer──▶ forensics-vm
   (public IP)         (private only)                (public IP)
```

## Forensic features (from the paper, Section VI)

- **Verbose server logging** — `loglevel verbose`, persisted logfile.
- **Continuous MONITOR capture** — systemd service tailing `redis-cli MONITOR` to a file.
- **AOF + RDB preserved** — `appendonly yes` and `save` snapshots, synced to the collector.
- **Periodic CONFIG GET snapshots** — systemd timer writing timestamped `CONFIG GET *` dumps.
- **ACL roles** — `reader` / `writer` / `admin`, enabling **ACL LOG** attribution of denied actions.
- **SLOWLOG** — `slowlog-log-slower-than 0` captures all commands.
- **Simple seed data** — a handful of plain `key:value` pairs.

Forensic files are pushed from `redis-vm` to `forensics-vm` via `rsync` over SSH on a
systemd timer (push model → keeps evidence on a separate host for chain-of-custody).

## Repository layout

```
├── main.bicep                  # orchestration
├── main.bicepparam             # parameter values
├── modules/
│   ├── network.bicep           # VNet, subnet, NSGs, public IPs, NICs
│   └── vm.bicep                # reusable Linux VM
├── cloud-init/                 # per-VM first-boot configuration
│   ├── redis.yaml
│   ├── client.yaml
│   └── forensics.yaml
├── redis/
│   ├── redis.conf.tmpl         # verbose, AOF, RDB, slowlog=0, bind
│   └── users.acl               # reader / writer / admin
├── scripts/
│   ├── gen-collector-key.sh    # generate collector SSH keypair
│   ├── forensic-monitor.sh     # continuous MONITOR capture
│   ├── forensic-config-snap.sh # CONFIG GET * snapshot
│   ├── forensic-sync.sh        # rsync to forensics-vm
│   └── seed-data.sh            # simple key:value seed
└── deploy.sh                   # az deployment wrapper
```

## Prerequisites

- Azure CLI (`az`) with Bicep, logged in (`az login`)
- An existing SSH public key at `~/.ssh/id_rsa.pub`

## Quick start

```bash
# 1. Generate the collector keypair (VM -> collector transfer)
./scripts/gen-collector-key.sh

# 2. Deploy
./deploy.sh
```

> Deployment steps and a validation walkthrough are documented at the bottom of this
> file once the templates are complete.

## License / attribution

Lab derived from the methodology and recommendations of Zia & Adedayo (ISDFS 2026).
For research and educational use.
