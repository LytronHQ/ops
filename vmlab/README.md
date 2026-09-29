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
./ops-get vmlab.sh v3.0.0
```

## Use it

```sh
./vmlab.sh create                                                    # the default lab
./vmlab.sh create --name web-1 --memory 2048 --vcpu 2 --disk 40gb    # one VM
./vmlab.sh status                          # every vmlab VM: state, RAM, address
./vmlab.sh stop                            # shut them down, keep the disks
./vmlab.sh start --name web-1              # boot one again
./vmlab.sh destroy --name web-1            # delete one
./vmlab.sh destroy --all                   # delete every vmlab VM
```

`create` with no `--name` makes the default lab: `db` (2 GB), `app1`, `app2`
(1.5 GB) and `app3` (1 GB). A four-VM lab costs a few hundred MB of disk: thin
qcow2 overlays on one cached base image.

| Command | Does |
|---|---|
| `create` | check prerequisites, then create and boot the VMs, wait for DHCP, print the addresses and the ssh command. A VM that already exists is left alone |
| `status` | name, power state, RAM and address, and the RAM in use |
| `ips` | name and address |
| `start` | boot the VMs that are not running, in the order named |
| `stop` | shut the running ones down gracefully, and wait until they are off |
| `destroy` | force off, undefine, delete the disks, forget the SSH host keys. Needs `--name` or `--all` |
| `help` | print the options |

## Options

Every input is a flag; `--help` lists them. Nothing is read from the
environment except `HOME` and `XDG_CACHE_HOME`, which say where your keys and
the image cache are. Unknown flags and bad values stop the run before anything
is created. `--flag value` and `--flag=value` both work.

| Flag | Default | Meaning |
|---|---|---|
| `--name <name>` | every vmlab VM; for `create`, the default lab | the VM to act on. Repeatable. It is called `<prefix><name>`, so vmlab never touches a VM it did not make |
| `--all` | | `destroy`: every vmlab VM |
| `--memory <size>` | `2048` | `create`: RAM. MB, or with `mb`/`gb`: `2048`, `2gb` |
| `--vcpu <n>` | `2` | `create`: vCPUs |
| `--disk <size>` | `20gb` | `create`: disk. GB, or with `gb`/`mb`: `40`, `40gb`. The root partition grows to it on first boot |
| `--key <path>` | first of `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa` with a `.pub` | `create`: your **private** key. Its `.pub` is authorised, so this is the key you connect with |
| `--launchpad <id>` | none | `create`: also authorise this Launchpad id's published keys — for connecting from a machine whose key is not on this one. Repeatable. Fails if the id has no keys |
| `--user <name>` | `dev` | `create`: login user, with passwordless sudo |
| `--image <url>` | Ubuntu 24.04 cloud image | `create`: base image, qcow2. Downloaded once, cached in `~/.cache/vmlab`. The Debian 12 `genericcloud` image works too |
| `--prefix <p>` | `vmlab-` | VM name prefix. Everything with it is "a vmlab VM" |
| `--dir <path>` | `/var/tmp/vmlab` | where disks live. Must be readable by the qemu user — **not** under a `0750` home directory. Every command needs the same value `create` had |

The VMs are key-only, so `create` refuses to build one nobody could log into: it
needs at least one key, from `--key` or `--launchpad`. Before downloading
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
- the shared base image is deleted only with the **last** VM: every disk is an
  overlay reading from it, so deleting it with one VM breaks the rest
- addresses come from the VM's own interface, not from the network's leases by
  name: leases outlive their VMs, and a new lab reuses the names
- Launchpad keys are fetched on the host and written into the seed, not
  imported inside the guest: Ubuntu *minimal* images lack `ssh-import-id`, and
  the import silently does nothing there
