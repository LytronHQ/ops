# vmlab

libvirt/KVM virtual machines on your own machine, with no sudo: a lab of several
up with one command and gone again leaving nothing behind, or a single VM that
stays. For testing against real separate hosts instead of containers on one.

**Runs on:** your own machine.
**Needs:** membership of the `libvirt` group, access to `/dev/kvm`, libvirt's
`default` network, and `qemu-utils genisoimage libvirt-clients curl`. No sudo,
no `virt-install`: it builds the domains with `virsh` directly.

## Get it

Like every module, with [`ops-get`](../README.md#ops-get):

```sh
./ops-get vmlab.sh v2.0.0
```

## Use it

```sh
./vmlab.sh create     # create + boot, print the addresses and the ssh command
./vmlab.sh status     # name, state, RAM, address
./vmlab.sh stop       # shut them down, keep the disks (frees the RAM)
./vmlab.sh start      # boot them again
./vmlab.sh destroy    # delete everything
```

A single VM is a lab of one:

```sh
VMLAB_VMS="web-1:2048:2:40" ./vmlab.sh create    # 2 GB RAM, 2 vCPU, 40 GB disk
VMLAB_VMS="web-1:2048:2:40" ./vmlab.sh destroy
```

A four-VM lab costs a few hundred MB of disk: thin qcow2 overlays on one cached
base image.

| Command | Does |
|---|---|
| `create` | check prerequisites, then create and boot every VM, wait for DHCP, print the addresses and the ssh command. VMs that already exist are left alone |
| `ips` | name and address for each |
| `status` | name, power state, RAM, address, and the RAM in use |
| `start` | boot every VM that is not running, in the order `VMLAB_VMS` lists them |
| `stop` | shut every running VM down gracefully and wait until they are off |
| `destroy` | force off, undefine, delete the disks, forget the SSH host keys |
| `help` | print the usage |

| Variable | Default | Meaning |
|---|---|---|
| `VMLAB_VMS` | `db:2048:2 app1:1536:2 app2:1536:2 app3:1024:1` | the VMs: `name:ram_mb:vcpu[:disk_gb]`, space or comma separated. Disk defaults to 20 GB. Every command needs the same value `create` had, to know which VMs it means |
| `VMLAB_KEY` | first of `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa` with a `.pub` beside it | path to your **private** key. Its `.pub` is authorised inside the VMs, so this is the key you connect with |
| `VMLAB_LAUNCHPAD` | none | a Launchpad id whose published SSH keys are authorised too — for connecting from a machine whose key is not on this one. Fails if the id has no keys |
| `VMLAB_USER` | `dev` | login user created inside each VM, with passwordless sudo |
| `VMLAB_PREFIX` | `vmlab-` | prefix for VM names, so the lab does not collide with your other VMs |
| `VMLAB_IMAGE` | Ubuntu 24.04 cloud image | URL of the base image, qcow2. Downloaded once, then cached in `~/.cache/vmlab`. The Debian 12 `genericcloud` image works too |
| `VMLAB_DIR` | `/var/tmp/vmlab` | where disks live. Must be readable by the qemu user — **not** under a `0750` home directory |

The VMs are key-only. `create` refuses to build one nobody could log into: it
needs at least one key, from `VMLAB_KEY` or `VMLAB_LAUNCHPAD`. Before downloading
anything it also checks the tools, that libvirt is reachable and that its
`default` network is active, and says what to do about whichever is missing.

## Details that cost a cycle each

All are commented in the source where they bite:

- the cloud-init seed must be a **virtio-blk disk, not a CD-ROM**. A CD
  enumerates too late, `ds-identify` misses the `cidata` label at boot, and
  cloud-init disables itself entirely — leaving a VM with no user and no network
- the backing image must sit **beside the overlays**, not under `$HOME`. qemu
  opens it as its own uid and cannot traverse a `0750` home directory, and the
  error it gives names the overlay rather than the backing file
- addresses come from the VM's own interface, not from the network's leases by
  name: leases outlive their VMs, and a new lab reuses the names
- Launchpad keys are fetched on the host and written into the seed, not
  imported inside the guest: Ubuntu *minimal* images lack `ssh-import-id`, and
  the import silently does nothing there
