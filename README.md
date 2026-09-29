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

### harden.sh

```sh
sudo ./harden.sh
```

| Variable | Does |
|---|---|
| `HARDEN_ALLOW` | extra inbound rules: `"<source>:<port>[/proto]"`, space or comma separated |
| `HARDEN_SKIP` | steps to skip: any of `firewall updates fail2ban ssh` |
| `HARDEN_SSH_TAG` | name for the sshd drop-in file (default `hardening`) |

It disables **password** SSH only — key login keeps working. The change is
written as a drop-in, checked with `sshd -t`, and **removed again if that check
fails**, then reloaded rather than restarted. So a mistake cannot lock you out of
the machine you are hardening, and the session you are running it from is never
dropped.

### create-vm.virsh.sh

```sh
./create-vm.virsh.sh up|ips|status|down
```

| Variable | Does |
|---|---|
| `VMLAB_KEY` | ssh key to authorise (default `~/.ssh/id_rsa`) |
| `VMLAB_USER` | login user to create (default `dev`) |
| `VMLAB_PREFIX` | VM name prefix (default `mon-lab-`) |
| `VMLAB_IMAGE` | cloud image URL |
| `VMLAB_DIR` | where disks live (default `/var/tmp/vmlab`) |

Edit the `VMS` array at the top to change how many VMs and their sizes.

### create-vm.virt-manager.sh and friends

The same idea for people who do have `virt-install` and sudo: create one
production-shaped VM, destroy it, or power a group on and off together.

### ops-get

```sh
ops-get <script> <version> [destination]
```

Needs `curl` or `wget` plus `sha256sum`. It downloads the script and the
release's `SHA256SUMS`, compares them, and only then writes the file.

It refuses, leaving nothing behind, when: the release has no `SHA256SUMS`, the
script is not listed in it, or the hash does not match. A provisioning run that
stops loudly beats one that quietly configures a host with the wrong bytes.

`OPS_BASE_URL` points it at a mirror or an air-gapped copy instead of GitHub.

The repo has to be public for this to work. Fetching from a private release
needs a token, and putting a GitHub token on every host you are about to harden
trades one problem for a worse one.

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
