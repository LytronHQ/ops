# harden

Bring a fresh Ubuntu/Debian host to a sane baseline: ufw denying inbound except
SSH, unattended security updates, fail2ban, and password SSH login disabled.

**Runs on:** the host being hardened.
**Language:** POSIX-ish bash, no dependencies beyond what Ubuntu ships. A fresh
server is the one place you cannot install a runtime first.

## Use it

```sh
./ops-get harden.sh v1.0.0 /tmp/harden.sh
sudo /tmp/harden.sh
```

Keep one extra port open — say a database only your private network reaches:

```sh
sudo HARDEN_ALLOW="10.0.0.0/16:5432" /tmp/harden.sh
```

See [`ops-get`](../README.md#ops-get) for fetching it with a checksum, or just
copy the file: it has no imports.

## Parameters

Environment variables rather than flags, because the usual caller is another
script.

| Variable | Default | Meaning |
|---|---|---|
| `HARDEN_ALLOW` | none | extra inbound rules, as `<source>:<port>[/proto]`. Space or comma separated, so `"10.0.0.0/16:5432 192.168.1.0/24:8090/tcp"` is two rules. Protocol defaults to `tcp`. Anything not listed, other than SSH, is denied |
| `HARDEN_SKIP` | none | steps to leave alone, space separated: any of `firewall`, `updates`, `fail2ban`, `ssh`. Use it when one of them is managed elsewhere |
| `HARDEN_SSH_TAG` | `hardening` | names the file it writes to `/etc/ssh/sshd_config.d/10-<tag>.conf`. Change it if something else on the host already uses that name |

Must run as root. Rerunning is safe: every step is idempotent.

## What it actually changes

| Step | Result |
|---|---|
| firewall | `ufw` enabled, default deny inbound, allow outbound, SSH allowed, plus anything in `HARDEN_ALLOW` |
| updates | `unattended-upgrades` enabled with a daily package-list refresh |
| fail2ban | installed and enabled with its defaults |
| ssh | a drop-in disabling password and keyboard-interactive auth, and root password login |

## It will not lock you out

The part worth reading even if you use nothing else here.

It disables **password** SSH only — key login keeps working. The change is
written as a drop-in file, validated with `sshd -t`, and **removed again if that
validation fails**. The service is then *reloaded*, not restarted, so the session
you are running it from is never dropped.

Hardening scripts that lock you out of the machine you are hardening are a
genre. This one tries not to join it.
