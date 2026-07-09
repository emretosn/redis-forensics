# Redis Forensic-Readiness Lab on Azure

Infrastructure-as-Code (Bicep) for a small Azure lab that produces a forensic-readiness setup.

## What this builds

Three Ubuntu 22.04 VMs (`Standard_B1s`) in a single VNet in `westeurope`:

| VM             | Role                                                           | Public IP |
| -------------- | -------------------------------------------------------------- | --------- |
| `redis-vm`     | Redis installed **in the VM**, configured as a forensic source | No        |
| `client-vm`    | Issues CRUD requests to Redis using ACL role users             | Yes (SSH) |
| `forensics-vm` | Collector — receives forensic files pushed from `redis-vm`     | Yes (SSH) |

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
- An existing SSH public key at `~/.ssh/id_ed25519.pub`

## Quick start

```bash
# 1. Generate the collector keypair (VM -> collector transfer)
./scripts/gen-collector-key.sh

# 2. Deploy (stages keys, detects your IP, generates ACL passwords, deploys)
./deploy.sh
```

`deploy.sh` prints the client/forensics public IPs and ready-to-use SSH commands,
and writes the generated Redis ACL passwords to `secrets/passwords.env` (git-ignored).

### Environment overrides for `deploy.sh`

| Variable               | Default                 | Purpose                                  |
| ---------------------- | ----------------------- | ---------------------------------------- |
| `RG_NAME`              | `rg-redis-forensics`    | Resource group name                      |
| `LOCATION`             | `westeurope`            | Azure region                             |
| `ADMIN_PUBKEY_PATH`    | `~/.ssh/id_ed25519.pub` | Admin SSH public key                     |
| `ADMIN_SOURCE_ADDRESS` | auto-detected `/32`     | Source IP/CIDR allowed to SSH            |
| `REDIS_*_PASS`         | generated (hex)         | reader / writer / admin ACL passwords    |

## Validation walkthrough

After the VMs finish cloud-init (give them ~3–5 minutes):

```bash
# SSH into the client VM (redis-vm is private-only; reach it via the VNet)
ssh azureuser@<client-public-ip>

# Normal, authorized activity (recorded across MONITOR / SLOWLOG / AOF)
redis-query.sh writer SET key9 hello
redis-query.sh reader GET key9
redis-query.sh reader SMEMBERS set1

# Unauthorized activity, denied and captured in ACL LOG with user attribution
redis-query.sh reader FLUSHALL      # NOPERM
redis-query.sh writer FLUSHALL      # NOPERM
```

Then confirm the forensic artifacts landed on the collector:

```bash
ssh azureuser@<forensics-public-ip>
sudo ls -R /var/forensics-store/redis-vm
#   forensics/monitor/    -> continuous MONITOR capture
#   forensics/config/     -> periodic CONFIG GET snapshots
#   forensics/acl/        -> exported ACL LOG (denied FLUSHALL attempts)
#   forensics/slowlog/    -> exported SLOWLOG
#   data/                 -> dump.rdb + appendonly.aof
#   log/                  -> redis-server.log (verbose)
```

The `redis-vm` pushes these every 5 minutes via a systemd timer
(`redis-forensic-sync.timer`); MONITOR capture runs continuously
(`redis-forensic-monitor.service`).

## Teardown

```bash
az group delete --name redis-forensics-rg --yes
```
