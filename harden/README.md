# harden

Bring a fresh Linux host to a sane baseline: ufw denying inbound except SSH,
unattended security updates, fail2ban, and password SSH login disabled.

**Runs on:** the host being hardened.
**Supports:** the Debian family (Ubuntu, Debian). Anything else is refused
before a single change is made.
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

[`ops-get`](../README.md#ops-get) is how every module is fetched: a pinned
release, checked against its `SHA256SUMS` before it is written.

## Parameters

Environment variables rather than flags, because the usual caller is another
script.

| Variable | Default | Meaning |
|---|---|---|
| `HARDEN_ALLOW` | none | extra inbound rules, as `<source>:<port>[/proto]`. Space or comma separated, so `"10.0.0.0/16:5432 192.168.1.0/24:8090/udp"` is two rules. Protocol is `tcp` or `udp`, default `tcp`. An IPv6 source works: `2001:db8::/32:5432`. Anything not listed, other than SSH, is denied. Every rule is checked before anything changes, and one bad rule stops the run |
| `HARDEN_SKIP` | none | steps to leave alone, space separated: any of `firewall`, `updates`, `fail2ban`, `ssh`. Use it when one of them is managed elsewhere |
| `HARDEN_SSH_TAG` | `hardening` | names the file it writes to `/etc/ssh/sshd_config.d/10-<tag>.conf`. Change it if something else on the host already uses that name |
| `HARDEN_SSH_KEY_CHECK` | `1` | `0` disables password SSH even though the user running the script has no authorised key. Only for when you log in as a different user who does |

Must run as root. Rerunning is safe: every step is idempotent.

Exit status is `0` only when every step that was not skipped actually took
effect. Anything it declined or failed to do is printed with `!!` and makes it
exit `1`, so a provisioning run cannot mistake a half-hardened host for a
hardened one.

## What it actually changes

| Step | Result |
|---|---|
| firewall | `ufw` enabled, default deny inbound, allow outbound, the port(s) sshd listens on allowed, plus anything in `HARDEN_ALLOW` |
| updates | `unattended-upgrades` enabled with a daily package-list refresh |
| fail2ban | installed and enabled with its defaults |
| ssh | a drop-in disabling password and keyboard-interactive auth, and root password login |

## It will not lock you out

The part worth reading even if you use nothing else here. Each of these was a
real lockout, found by running the script on a VM rather than by reading it.

- **SSH on another port.** The firewall allows the port sshd actually listens
  on — from its config and from `ssh.socket` — not "port 22".
- **No key yet.** It disables **password** SSH only, and only when the user
  running it (`$SUDO_USER`, or root) has an authorised key. A server handed over
  as root + password keeps its password login, and the run exits `1` saying why.
- **Something else re-enabling passwords.** sshd keeps the first value it reads,
  so a drop-in that sorts earlier silently wins. After reloading, it asks sshd
  for the effective setting, and if passwords are still on it names the file
  responsible and exits `1`.
- **A broken config.** The change is a drop-in validated with `sshd -t` and
  **removed again if that fails**. The service is *reloaded*, not restarted, so
  the session you are running it from is never dropped.

Hardening scripts that lock you out of the machine you are hardening are a
genre. This one tries not to join it.
