# vmlab

Throwaway libvirt/KVM virtual machines: several up with one command, addresses
printed, and gone again leaving nothing behind. For testing something against
real separate hosts instead of containers on one.

**Runs on:** your own machine.

## Get it

Like every module, with [`ops-get`](../README.md#ops-get). Each script is a
single file with no imports, so fetch only the ones you use:

```sh
./ops-get create-vm.virsh.sh v1.0.0
```

Two ways in, depending on what your workstation lets you do:

| | `create-vm.virsh.sh` | `create-vm.virt-manager.sh` |
|---|---|---|
| Makes | a whole lab, several VMs | one VM |
| Needs sudo | **no** | yes |
| Needs `virt-install` | **no** | yes |
| SSH keys from | a local key file | a Launchpad id |
| Disks in | `/var/tmp/vmlab` | `/var/lib/libvirt/images` |

The first exists because the second could not run on a locked-down workstation:
no `virt-install`, and `sudo` that prompts. It builds the domains with `virsh`
directly instead.

Both need membership of the `libvirt` group, access to `/dev/kvm`, and a libvirt
network.

## create-vm.virsh.sh — the whole lab, no sudo

```sh
./create-vm.virsh.sh up       # create + boot, print IPs
./create-vm.virsh.sh status
./create-vm.virsh.sh down     # destroy, undefine, delete disks
```

A four-VM lab costs a few hundred MB: thin qcow2 overlays on one cached base
image.

| Command | Does |
|---|---|
| `up` | check prerequisites, then create and boot every VM, wait for DHCP, print the addresses and the ssh command |
| `ips` | name and address for each |
| `status` | name, power state, address |
| `down` | destroy, undefine, delete the disks, forget the SSH host keys |
| `help` | print the usage |

| Variable | Default | Meaning |
|---|---|---|
| `VMLAB_KEY` | first of `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa` with a `.pub` beside it | path to your **private** key. It authorises the matching `.pub` inside the VMs, so this is the key you will connect with |
| `VMLAB_USER` | `dev` | login user created inside each VM |
| `VMLAB_PREFIX` | `vmlab-` | prefix for VM names, so a lab does not collide with your other VMs |
| `VMLAB_IMAGE` | Ubuntu 24.04 cloud image | URL of the base image, qcow2. Downloaded once, then cached. The Debian 12 `genericcloud` image works too |
| `VMLAB_VMS` | `db:2048:2 app1:1536:2 app2:1536:2 app3:1024:1` | the lab: `name:ram_mb:vcpu`, space or comma separated. `down` needs the same value `up` had |
| `VMLAB_DIR` | `/var/tmp/vmlab` | where disks live. Must be readable by the qemu user — **not** under a `0750` home directory |

Before downloading anything, `up` checks the tools, your key, that libvirt is
reachable and that its `default` network is active, and says what to do about
whichever is missing.

## create-vm.virt-manager.sh — one VM, the conventional way

```sh
./create-vm.virt-manager.sh --name web-1 --user dev \
  --image https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
```

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--name` | yes | — | VM name, also its hostname |
| `--user` | yes | — | login user to create |
| `--image` | yes | — | a local path, or an https URL to an Ubuntu **cloud** image. URLs are cached after the first download |
| `--launchpad` | no | same as `--user` | Launchpad id to import SSH keys from — the main difference from the script above |
| `--cpu` | no | `2` | vCPUs |
| `--ram` | no | `2048` | memory in MB |
| `--disk` | no | `20` | disk in GB |
| `--os-variant` | no | `ubuntu24.04` | libvirt osinfo id; see `osinfo-query os` |

| Variable | Default | Meaning |
|---|---|---|
| `IMAGES_DIR` | `/var/lib/libvirt/images` | where the disk and seed are written. Root-owned, which is why this one needs sudo |
| `LIBVIRT_NETWORK` | `default` | libvirt network to attach to |

## destroy-vm.virt-manager.sh

```sh
./destroy-vm.virt-manager.sh web-1
./destroy-vm.virt-manager.sh --name web-1 --yes
```

| Argument | Meaning |
|---|---|
| `<name>` or `--name <name>` | force it off, undefine it, delete its disk and cloud-init seed |
| `--yes` | skip the confirmation prompt |

## vms.virt-manager.sh

Power a group on or off together, so a lab does not sit using memory.

```sh
./vms.virt-manager.sh up
./vms.virt-manager.sh down web-
```

| Argument | Default | Meaning |
|---|---|---|
| `up` \| `down` \| `status` | `status` | start them, shut them down gracefully, or list name, state and memory |
| `[prefix]` | `vmlab-` | only act on VMs whose name starts with this, leaving others alone. The default matches a lab made by `create-vm.virsh.sh` |

| Variable | Default | Meaning |
|---|---|---|
| `VM_PREFIX` | `vmlab-` | same as the positional prefix, for when the caller is a script |

On `up` it starts anything matching `*db*` first, since the rest usually depend
on it.

## Two details that cost a cycle each

Both are commented in the source where they bite:

- the cloud-init seed must be a **virtio-blk disk, not a CD-ROM**. A CD
  enumerates too late, `ds-identify` misses the `cidata` label at boot, and
  cloud-init disables itself entirely — leaving a VM with no user and no network
- the backing image must sit **beside the overlays**, not under `$HOME`. qemu
  opens it as its own uid and cannot traverse a `0750` home directory, and the
  error it gives names the overlay rather than the backing file
