# Redis Forensic-Readiness Lab on Azure

Infrastructure-as-Code (Bicep) for a small Azure lab that produces a forensic-readiness setup.

## What this builds

Three Ubuntu 22.04 VMs (`Standard_B2ts_v2`) in `westeurope`, across **two peered VNets** so
the collector is network-isolated from the Redis source:

| VM             | Role                                                                | VNet | Public IP |
| -------------- | ------------------------------------------------------------------- | ---- | --------- |
| `redis-vm`     | Redis installed **in the VM**, configured as a forensic source      | A `10.0.0.0/16` | No |
| `client-vm`    | Issues CRUD requests to Redis using ACL role users                  | A `10.0.0.0/16` | Yes (SSH) |
| `forensics-vm` | Collector — **pulls** forensic files from `redis-vm`, stores immutably | B `10.1.0.0/16` | Yes (SSH) |

VNet-A and VNet-B are connected by **VNet peering**, so `forensics-vm` reaches `redis-vm` over
private IPs on the Azure backbone. In production, swap the peering for a Private Link Service
and nothing else changes.

## Forensic features

- **Verbose server logging** — `loglevel verbose`, persisted logfile.
- **Continuous MONITOR capture** — systemd service tailing `redis-cli MONITOR`, sealed and
  rotated into complete, immutable segments.
- **AOF + RDB preserved** — `appendonly yes` and `save` snapshots, collected as versioned
  immutable copies on the collector.
- **Periodic CONFIG GET snapshots** — systemd timer writing timestamped `CONFIG GET *` dumps.
- **ACL roles** — `reader` / `writer` / `admin`, enabling **ACL LOG** attribution of denied actions.
- **Simple seed data** — a handful of plain `key:value` pairs.

### Evidence flow: pull model + immutable store

Evidence is collected with a **pull model** for chain-of-custody. `redis-vm` consolidates all
artifacts under a single evidence root (`/var/forensics`) exposed by a restricted, read-only
`evidence` user (SSH key locked to an `rrsync -ro` forced command). `forensics-vm` initiates
every transfer on a systemd timer and holds the only key. **`redis-vm` holds no credentials to,
and has no network path into, the collector** — so a full compromise of the Redis side cannot
reach or alter already-collected evidence.

On the collector the store is **write-once / immutable**:

- `monitor` / `config` / `acl`: unique filenames, copied once, then `chattr +i`.
- `data` / `log`: per-pull **timestamped snapshot dirs**, `chattr +i`, deduped by `sha256`
  so unchanged RDB/AOF/log are not re-stored.
- `manifest`: a `sha256` manifest per pull cycle (immutable) for integrity verification.

Because evidence is immutable, freeing space is a deliberate, privileged action — nothing is
ever silently overwritten or auto-deleted. See **Retention** below.

## Repository layout

```
├── main.bicep                      # orchestration
├── main.bicepparam                 # parameter values
├── modules/
│   ├── network.bicep               # two peered VNets, subnets, NSGs, public IPs, NICs
│   └── vm.bicep                    # reusable Linux VM
├── cloud-init/                     # per-VM first-boot configuration
│   ├── redis.yaml
│   ├── client.yaml
│   └── forensics.yaml
├── redis/
│   ├── redis.conf.tmpl             # verbose, AOF, RDB, bind
│   └── users.acl                   # reader / writer / admin
├── scripts/
│   ├── gen-pull-key.sh             # generate the forensics->redis read-only pull keypair
│   ├── forensic-monitor.sh         # continuous MONITOR capture (seal-and-rotate)
│   ├── forensic-config-snap.sh     # CONFIG GET * snapshot
│   ├── forensic-export-local.sh    # redis-vm: ACL LOG + BGSAVE + mirror rdb/aof/log
│   ├── forensic-pull.sh            # forensics-vm: pull + immutable versioned store
│   └── seed-data.sh                # simple key:value seed
└── deploy.sh                       # az deployment wrapper
```

## Prerequisites

- Azure CLI (`az`) with Bicep, logged in (`az login`)
- An existing SSH public key at `~/.ssh/id_ed25519.pub`

## Quick start

```bash
# 1. Generate the pull keypair (forensics-vm -> redis-vm read-only transfer)
./scripts/gen-pull-key.sh

# 2. Deploy (stages keys, detects your IP, generates ACL passwords, deploys)
./deploy.sh
```

`deploy.sh` prints the client/forensics public IPs and ready-to-use SSH commands,
and writes the generated Redis ACL passwords to `secrets/passwords.env` (git-ignored).

### Environment overrides for `deploy.sh`

| Variable                   | Default                    | Purpose                                     |
| -------------------------- | -------------------------- | ------------------------------------------- |
| `RG_NAME`                  | `rg-redis-forensics`       | Resource group name                         |
| `LOCATION`                 | `westeurope`               | Azure region                                |
| `ADMIN_PUBKEY_PATH`        | `~/.ssh/id_ed25519.pub`    | Admin SSH public key                        |
| `ADMIN_SOURCE_ADDRESS`     | auto-detected, widened     | Source IP/CIDR allowed to SSH               |
| `ADMIN_SOURCE_PREFIX_BITS` | `23`                       | Widening of the auto-detected IP            |
| `REDIS_*_PASS`             | generated (hex)            | reader / writer / admin ACL passwords       |

By default the auto-detected public IP is widened to its containing `/23` so SSH keeps
working if your egress IP drifts within a NAT pool during a test. Set
`ADMIN_SOURCE_PREFIX_BITS=32` for an exact pin, or pass `ADMIN_SOURCE_ADDRESS` directly.

## Validation walkthrough

After the VMs finish cloud-init (give them ~3–5 minutes):

```bash
# SSH into the client VM (redis-vm is private-only; reach it via the VNet)
ssh azureuser@<client-public-ip>
```

No Redis passwords are stored on the client VM — each user authenticates with
their own credential at runtime (the deployer distributes them from
`secrets/passwords.env`). "Log in" as a role for the current shell session, then
run commands (Redis ACL enforces the role and logs any denial):

```bash
# --- log in as writer for this shell session (password is NOT echoed) ---
read -rs REDIS_PASS && export REDIS_PASS      # paste the writer password

# Normal, authorized activity (recorded across MONITOR / AOF)
redis-query.sh writer SET key9 hello
redis-query.sh writer GET key9

# --- switch to reader: re-enter with the reader password ---
read -rs REDIS_PASS && export REDIS_PASS      # paste the reader password
redis-query.sh reader GET key9
redis-query.sh reader SMEMBERS set1

# Unauthorized activity, denied and captured in ACL LOG with user attribution
redis-query.sh reader FLUSHALL      # NOPERM (reader lacks FLUSHALL)

unset REDIS_PASS                     # "log out" of the session
```

Alternatively, open an authenticated interactive Redis session (prompts once, no
stored secret) and type commands at the `10.0.1.4:6379>` prompt:

```bash
redis-cli -h 10.0.1.4 --user reader --askpass
```

If you skip the session login, `redis-query.sh` prompts for the password on each
call. Passwords are never written to disk on the client VM.

Then confirm the forensic artifacts landed on the collector:

```bash
ssh azureuser@<forensics-public-ip>
sudo ls -R /var/forensics-store/redis-vm
#   monitor/            -> sealed, immutable MONITOR segments (monitor-<ts>.log)
#   config/             -> periodic CONFIG GET snapshots
#   acl/                -> exported ACL LOG (denied FLUSHALL attempts)
#   data/<pull-ts>/     -> versioned dump.rdb + appendonlydir snapshots
#   log/<pull-ts>/      -> versioned redis-server.log (verbose)
#   manifest/           -> sha256 manifest per pull cycle (integrity)

# Evidence is immutable: try to tamper and it is refused.
sudo sh -c 'echo x >> /var/forensics-store/redis-vm/config/'*.txt   # -> Operation not permitted
lsattr /var/forensics-store/redis-vm/config/*.txt                   # -> ----i--------- (immutable)
```

The `forensics-vm` **pulls** these on a systemd timer (`forensic-pull.timer`); `redis-vm`
refreshes the evidence root via `redis-forensic-export.timer`, and MONITOR capture runs
continuously (`redis-forensic-monitor.service`) with sealed segments rolled by
`redis-forensic-monitor-rotate.timer`.

## Threat model & why the pull model

The design assumes `redis-vm` (or an app talking to it) may be fully compromised. To keep the
evidence trustworthy:

- **Pull, not push.** `forensics-vm` initiates all transfers and holds the only key.
  `redis-vm` has no credential to the collector, and the collector's NSG allows no inbound from
  `redis-vm`. A rooted `redis-vm` therefore has no path to the evidence store.
- **Least privilege at the source.** The pull key is locked to `rrsync -ro /var/forensics`
  (read-only, rooted at the evidence tree, no shell).
- **Immutable, versioned sink.** `chattr +i` plus per-pull snapshots mean evidence captured
  *before* a compromise is frozen; the attacker can stop producing new truthful evidence but
  cannot rewrite history. The point-in-time RDB/AOF can rebuild the clean state.
- **Network isolation.** Collector lives in a separate, peered VNet — production would use a
  Private Link Service to expose only the single pull endpoint.

## Retention

Evidence is never auto-deleted. When you need to reclaim space, prune deliberately (this clears
the immutable flag first, so it is an explicit, auditable act):

```bash
ssh azureuser@<forensics-public-ip>
# Example: drop immutable evidence older than 30 days.
sudo find /var/forensics-store/redis-vm -type f -mtime +30 -exec chattr -i {} + \
  -exec rm -f {} +
```

## Teardown

```bash
az group delete --name rg-redis-forensics --yes
```

### Update the Admin IP
```bash
MYIP="$(curl -s https://api.ipify.org)/32"

# Both the NIC-level and subnet-level NSGs gate SSH, so the admin rule must be
# updated on both for each publicly reachable VM:
#   client   : redisfx-client-nsg    (NIC) + redisfx-vnet-lab-nsg-westeurope (lab subnet)
#   forensics: redisfx-forensics-nsg (NIC) + redisfx-fx-vnet-fx-nsg-westeurope (fx subnet)
for nsg in \
  redisfx-client-nsg redisfx-vnet-lab-nsg-westeurope \
  redisfx-forensics-nsg redisfx-fx-vnet-fx-nsg-westeurope; do
  az network nsg rule create -g rg-redis-forensics --nsg-name "$nsg" \
    --name allow-ssh-from-admin --priority 100 \
    --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$MYIP" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 22
done
```
