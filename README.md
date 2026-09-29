# ops

Scripts for the boring parts of running a machine. Each one is a single
self-contained file with no imports and nothing about my projects baked in.

## Harden a fresh server

Copy-paste, on the server, from nothing:

```sh
curl -fsSL https://github.com/LytronHQ/ops/releases/download/v1.0.0/ops-get -o ops-get
chmod +x ops-get

./ops-get harden.sh v1.0.0 /tmp/harden.sh
sudo /tmp/harden.sh
```

You now have: ufw denying inbound except SSH, unattended security updates,
fail2ban, and password SSH login disabled.

To keep one extra port open — say a database only your private network should
reach:

```sh
sudo HARDEN_ALLOW="10.0.0.0/16:5432" /tmp/harden.sh
```

## Spin up throwaway VMs

These run on **your own machine**, so clone the repo rather than fetching files:

```sh
git clone https://github.com/LytronHQ/ops
cd ops/local/vm

./create-vm.virsh.sh up       # create + boot 4 VMs, print their IPs
./create-vm.virsh.sh status
./create-vm.virsh.sh down     # destroy everything, leave nothing behind
```

Needs libvirt group membership, access to `/dev/kvm`, and libvirt's default
network. **No sudo and no virt-install** — it builds the domains with `virsh`
directly, so it works on a workstation where you cannot install either.

A four-VM lab costs a few hundred MB: thin overlays on one cached base image.

---

## Which way to get a script

| Script lives in | Runs on | Get it by |
|---|---|---|
| `remote/` | the server you are configuring | `ops-get` (pinned + checksummed) |
| `local/` | your own machine | `git clone` |

`ops-get` exists for the first case: a fresh server has `curl` and little else,
and the script you run there should be pinned to a version and verified before
it executes. On your laptop a clone is simpler and you get all of them at once.

## Reference

Every script takes its settings one of two ways: **environment variables** (the
ones extracted from a deployment, where the caller is another script) or
**flags** (the ones you type by hand). Which is which is noted below.

### ops-get

```sh
ops-get <script> <version> [destination]
ops-get harden.sh v1.0.0 /tmp/harden.sh
```

| Argument | Required | Meaning |
|---|---|---|
| `<script>` | yes | the asset filename, e.g. `harden.sh`. No path — release assets are flat |
| `<version>` | yes | a release tag, e.g. `v1.0.0`. There is no "latest" on purpose |
| `[destination]` | no | where to write it. Default: `./<script>` |

| Variable | Default | Meaning |
|---|---|---|
| `OPS_REPO` | `LytronHQ/ops` | which repository's releases to fetch from — point it at your fork |
| `OPS_BASE_URL` | GitHub releases | the whole base URL, for a mirror or an air-gapped copy |

Needs `curl` or `wget`, plus `sha256sum` or `shasum`.

### remote/harden.sh

Run as root on the host being hardened. Settings are environment variables,
because the usual caller is a provisioning script.

```sh
sudo ./harden.sh
sudo HARDEN_ALLOW="10.0.0.0/16:5432" ./harden.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `HARDEN_ALLOW` | none | extra inbound rules to allow, as `<source>:<port>[/proto]`. Space or comma separated, so `"10.0.0.0/16:5432 192.168.1.0/24:8090/tcp"` is two rules. Protocol defaults to `tcp`. Everything not listed here, other than SSH, is denied |
| `HARDEN_SKIP` | none | steps to leave alone, space separated. Any of `firewall`, `updates`, `fail2ban`, `ssh`. Use it when one of them is managed elsewhere |
| `HARDEN_SSH_TAG` | `hardening` | names the file it writes to `/etc/ssh/sshd_config.d/10-<tag>.conf`. Change it if something else on the host already uses that name |

Rerunning it is safe: every step is idempotent.

### local/vm/create-vm.virsh.sh

A whole disposable lab, no sudo. Takes a command, and environment variables for
the rest.

```sh
./create-vm.virsh.sh up
VMLAB_PREFIX=test- VMLAB_USER=me ./create-vm.virsh.sh up
```

| Command | Does |
|---|---|
| `up` | create and boot every VM, wait for DHCP, print the addresses |
| `ips` | print name and address for each |
| `status` | name, power state, address |
| `down` | destroy, undefine, delete the disks, forget the SSH host keys |

| Variable | Default | Meaning |
|---|---|---|
| `VMLAB_KEY` | `~/.ssh/id_rsa` | path to your **private** key. It authorises the matching `.pub` inside the VMs, so this is the key you will connect with |
| `VMLAB_USER` | `dev` | login user created inside each VM |
| `VMLAB_PREFIX` | `mon-lab-` | prefix for VM names, so a lab does not collide with your other VMs |
| `VMLAB_IMAGE` | Ubuntu 24.04 cloud image | URL of the base image. Downloaded once and cached |
| `VMLAB_DIR` | `/var/tmp/vmlab` | where the disks live. Must be somewhere the qemu user can read — not under a `0750` home directory |

How many VMs and how big is the `VMS` array at the top of the file:
`name:ram_mb:vcpu`, one per line. The default is four small ones.

### local/vm/create-vm.virt-manager.sh

One production-shaped VM. **Needs `virt-install` and sudo**, unlike the script
above. Takes flags, because you run it by hand.

```sh
./create-vm.virt-manager.sh --name web-1 --user dev \
  --image https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
```

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--name` | yes | — | VM name, also its hostname |
| `--user` | yes | — | login user to create |
| `--image` | yes | — | a local path, or an https URL to an Ubuntu **cloud** image. URLs are cached after the first download |
| `--launchpad` | no | same as `--user` | **Launchpad id to import SSH keys from.** This is the main difference from the script above, which uses a local key file instead |
| `--cpu` | no | `2` | vCPUs |
| `--ram` | no | `2048` | memory in MB |
| `--disk` | no | `20` | disk in GB |
| `--os-variant` | no | `ubuntu24.04` | libvirt osinfo id; see `osinfo-query os` |

| Variable | Default | Meaning |
|---|---|---|
| `IMAGES_DIR` | `/var/lib/libvirt/images` | where the disk and seed are written. Root-owned, which is why this one needs sudo |
| `LIBVIRT_NETWORK` | `default` | libvirt network to attach to |

### local/vm/destroy-vm.virt-manager.sh

```sh
./destroy-vm.virt-manager.sh web-1
./destroy-vm.virt-manager.sh --name web-1 --yes
```

| Argument | Meaning |
|---|---|
| `<name>` or `--name <name>` | which VM to remove: force it off, undefine it, delete its disk and seed |
| `--yes` | skip the confirmation prompt |

### local/vm/vms.virt-manager.sh

Power a group of VMs on or off together, so a lab does not sit using memory.

```sh
./vms.virt-manager.sh up
./vms.virt-manager.sh down web-
```

| Argument | Default | Meaning |
|---|---|---|
| `up` \| `down` \| `status` | `status` | start them, shut them down gracefully, or list name, state and memory |
| `[prefix]` | `mon-` | only act on VMs whose name starts with this, leaving others alone |

| Variable | Default | Meaning |
|---|---|---|
| `VM_PREFIX` | `mon-` | same as the positional prefix, for when the caller is a script |

On `up` it starts anything matching `*db*` first, since the rest usually depend
on it.

## Notes for anyone reading the source

Two details in the VM script cost a cycle each to find and are commented where
they bite:

- the cloud-init seed must be a **virtio-blk disk, not a CD-ROM** — a CD
  enumerates too late, `ds-identify` misses it, and cloud-init disables itself
  entirely, leaving a VM with no user and no network
- the backing image must sit **beside the overlays**, not under `$HOME` — qemu
  opens it as its own uid and cannot traverse a `0750` home directory

These came out of a real deployment rather than a library, which is why the
comments read like incident notes.

## Releasing

Push a tag. The workflow checks every script parses, publishes them as flat
release assets, and writes the `SHA256SUMS` that `ops-get` verifies against.
Nothing is consumable from a branch on purpose: a consumer pins a version or
does not run at all.

Script filenames must be unique across the whole repo, since assets are flat.

## Licence

MIT.
