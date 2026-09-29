# ops

Standalone scripts for the boring parts of running a machine: harden a fresh
host, throw up a disposable VM lab, tear it down again. Each one is
self-contained and parameterised — no project of mine is baked into any of them,
which is the whole point.

Extracted from a real deployment rather than written as a library, so everything
here has been run against real hosts and has the scars to show for it.

## Layout

| | Runs on | Language |
|---|---|---|
| `remote/` | the target host | POSIX shell, no exceptions |
| `local/` | your own machine | whatever suits |

The split is about **where** a script runs, not taste. A fresh Ubuntu server has
`sh` and nothing else you can count on, and the first script you run is the one
that cannot afford a dependency. What runs on your laptop is free to be anything.

## Using one

```sh
# pinned version, checksum verified, fails closed
./ops-get harden.sh v1.0.0 /tmp/harden.sh
sudo HARDEN_ALLOW="10.0.0.0/16:8090" /tmp/harden.sh
```

`ops-get` needs `curl` or `wget` and `sha256sum`. It refuses to run a script it
cannot verify: a release with no `SHA256SUMS`, a script missing from it, or a
mismatch all abort without leaving the file behind. A provisioning run that stops
loudly beats one that quietly hardens a host with the wrong bytes.

Or just copy the file. They are single files with no imports for exactly that
reason.

`OPS_BASE_URL` points it somewhere else — a mirror, an air-gapped copy, or a
test that serves a corrupted file to prove the refusal works.

The repo has to be public for this to work: fetching an asset from a private
release needs a token, and putting a GitHub token on every host you are about to
harden trades one problem for a worse one.

## What is here

### `remote/harden.sh`

ufw defaulting to deny inbound with SSH allowed, unattended security updates,
fail2ban, key-only SSH.

```sh
sudo ./harden.sh                                   # SSH only
sudo HARDEN_ALLOW="10.0.0.0/16:8090" ./harden.sh   # plus one private port
sudo HARDEN_SKIP="fail2ban" ./harden.sh
```

The part worth copying even if you use nothing else: the SSH change disables
**password** auth only, is written as a drop-in, is validated with `sshd -t`, and
is **removed again if that validation fails**. The service is then reloaded, not
restarted, so the session running the script is never dropped. Hardening scripts
that lock you out of the machine you are hardening are a genre; this one tries
not to join it.

### `local/vm/create-vm.virsh.sh`

A disposable libvirt/KVM lab — several VMs up, addresses printed, and `down`
leaving nothing behind. **No sudo and no virt-install**: it needs only membership
of the `libvirt` group, an ACL on `/dev/kvm`, and libvirt's default network, so
it works on a locked-down workstation where the usual tooling does not.

```sh
./create-vm.virsh.sh up      # create + boot, print IPs
./create-vm.virsh.sh status
./create-vm.virsh.sh down    # destroy, undefine, delete disks
```

Thin qcow2 overlays on one cached base image, so a four-VM lab costs a few
hundred MB. Two details in there cost a cycle each to discover and are commented
where they bite: the cloud-init seed must be a **virtio-blk disk, not a CD-ROM**
(a CD enumerates too late and cloud-init disables itself entirely), and the
backing image must sit **beside the overlays** rather than under `$HOME`, because
qemu opens it as its own uid and cannot traverse a `0750` home directory.

### `local/vm/*.virt-manager.sh`

The same idea for people who have `virt-install` and sudo: create one
production-shaped VM, destroy it, or power a group on and off.

## Releasing

Push a tag. The workflow checks every script parses, publishes them as flat
release assets, and writes the `SHA256SUMS` that `ops-get` verifies against.
Nothing is consumable from a branch on purpose — a consumer pins a version or
does not run at all.

## Licence

MIT. Take what you like.
