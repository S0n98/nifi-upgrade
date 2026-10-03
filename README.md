# nifi-upgrade

Automation and runbook for upgrading an Apache NiFi cluster from **2.0.0-M4** to **2.12.0** with no data loss, and for
moving versioned flows from **NiFi Registry** to the **GitLab Flow Registry Client** with their full version history.

The full operating procedure (timeline, go/no-go criteria, rollback, known issues, test evidence) is in
**[RUNBOOK.md](RUNBOOK.md)**. This README covers what the project is and how to get started.

## What it does

`nifi-upgrade.sh` runs from an admin host and drives every node over SSH:

| Step | Downtime | What happens |
|---|---|---|
| `preflight` | no | Read-only checks on every node: Java 21, disk space, sensitive key set, data stored outside the install directory, backup space, custom NARs, Python processors, and network needs (where the release zip comes from, and whether Python processors need pip). Cluster checks: all nodes connected, no ghost components. |
| `stage` | no | Downloads 2.12.0, checks its SHA-512, unpacks it next to the old version and carries the configuration over. Writes a report of anything that needs a human decision. |
| `upgrade` | **yes** | Records what is running, drains the queues, stops all nodes and backs each one up (optional ZooKeeper backup hook). Patches the flow for 2.12, switches the symlink and starts all nodes with nothing running. Then verifies that queued data, components, services, users, parameters and version control all survived. |
| `verify` | – | Re-runs the post-start verification. |
| `resume` | – | Restarts exactly the components that were running before the upgrade. |
| `finalize` | – | Restores normal auto-resume behaviour on every node. |
| `rollback` | **yes** | Restores every node from its backup, switches back to the old version and restarts what was running. |
| `status` | – | Shows the symlink target, service state and auto-resume setting on each node. |
| `all` | **yes** | `preflight` → `stage` → `upgrade` → `resume` → `finalize`. |

`migrate-registry-to-gitlab.py` runs after the upgrade, with no downtime. For each versioned flow, every NiFi Registry
version becomes one git commit, keeping its original comment, author and date. The live process group then switches
to the GitLab client.

## Layout

```
nifi-upgrade.sh                 orchestrator (run on the admin host)
lib/nifi-node.sh                node agent, copied to each node over SSH
lib/nifi_api.py                 NiFi REST helper: record, quiesce, wait-up, verify, resume
migrate-registry-to-gitlab.py   NiFi Registry -> GitLab Flow Registry Client, with history
nifi-upgrade.conf.example       configuration template for a 3-node cluster
local-test.conf                 configuration used to test on a single host (NODES=local)
RUNBOOK.md                      operating procedure and test evidence
```

## Does it need internet access?

**No — not with the preparation below.** Nothing in the upgrade or the registry migration needs the public internet by
design; only the items below reach out, and each has an offline alternative.

| What reaches out | When | Offline / air-gapped alternative |
|---|---|---|
| NiFi 2.12.0 release zip (`DIST_URL`, e.g. downloads.apache.org) | `stage`, once per node | Set `DIST_ZIP` (zip on the admin host, copied to each node) and leave `DIST_URL` empty, or put `nifi-2.12.0-bin.zip` in `STAGE_DIR` on each node beforehand. `DIST_SHA512` is a config value — nothing is fetched to check it |
| Release signature check (`.asc` + Apache `KEYS`) | before the change | Do it on any connected machine, then carry the zip and its SHA-512 across |
| `pip install` of **Python processor dependencies** | first start of 2.12.0 | Only for Python processors that declare dependencies (`requirements.txt` or `ProcessorDetails.dependencies`). NiFi caches them in `nifi.python.working.directory` (default `./work/python`, i.e. inside the install dir, so a new version re-installs). Either externalize that directory before the upgrade, or point pip at an internal mirror (`/etc/pip.conf`; `UV_INDEX_URL` if `uv` is installed — NiFi prefers it). `preflight` warns when this applies |
| OS packages (Java 21, python3, unzip) | before the change | Internal package mirror |
| OIDC identity provider | NiFi start + every login | Internal IdP (e.g. self-hosted GitLab) — NiFi must reach its discovery/JWKS URLs at startup |
| Registry → GitLab migration | after the upgrade | Internal only: admin host → NiFi API; NiFi → NiFi Registry and GitLab; the tool → GitLab API (only to create bucket directories). Needs outbound HTTPS only if your GitLab is gitlab.com |

The admin-host scripts use the Python standard library only — no `pip`.

## Requirements

- **Admin host:** bash, python3 (standard library only), and SSH to every node as a user with passwordless sudo.
- **Nodes:** Java 21, python3 and unzip. NiFi runs as a systemd service from `/opt/nifi/current` →
  `/opt/nifi/nifi-<version>`. Every repository, state, flow and auth file lives **outside** the install directory
  (`preflight` enforces this).
- **API credentials:** an admin client certificate (`NIFI_CLIENT_CERT` / `NIFI_CLIENT_KEY`), or a command that
  prints a bearer token (`NIFI_TOKEN_CMD`).

## Quick start

```bash
cp nifi-upgrade.conf.example nifi-upgrade.conf     # set NODES, NIFI_API_URL, DIST_SHA512, auth, backup dir
./nifi-upgrade.sh -c nifi-upgrade.conf preflight
./nifi-upgrade.sh -c nifi-upgrade.conf stage       # then review /opt/nifi/upgrade-report-*.txt on every node

# maintenance window
./nifi-upgrade.sh -c nifi-upgrade.conf upgrade     # stops at VERIFY PASSED, with everything still stopped
./nifi-upgrade.sh -c nifi-upgrade.conf resume
./nifi-upgrade.sh -c nifi-upgrade.conf finalize

# if needed
./nifi-upgrade.sh -c nifi-upgrade.conf rollback
```

Registry migration (after the upgrade):

```bash
./migrate-registry-to-gitlab.py --source-client <nifi-registry-client> --target-client <gitlab-client> \
    --gitlab-url https://gitlab.example.com --gitlab-project nifi/nifi-flows \
    --gitlab-token-file token.env --dry-run          # then without --dry-run
```

Run logs and the recorded baseline are written to `runs/<date>-<old>-to-<new>/`, which git ignores.

## 2.0.0-M4 → 2.12.0 issues this handles

- Python processors are renamed from `python.<Name>` to `<Name>`. Without a fix to the saved flow they load as ghost
  components.
- The 2.12 `nifi.properties` ships `nifi.python.command` commented out. The setting is carried over so Python
  processors keep working.
- Starting with auto-resume off also leaves controller services disabled. Verification re-enables them first.
- Keys that 2.12 removed from `nifi.properties` and `bootstrap.conf` are reported for review rather than copied.

Upgrade issues the scripts **don't** fix are listed in [RUNBOOK.md](RUNBOOK.md#7-problems-found-while-testing):
- 2.12 renames many processor property keys, so API scripts that set them need updating.
- `/nifi-api/access/config` now returns 401, so health checks that use it need changing.

## Tested

Tested on a single node (`NODES=local`):
- NiFi 2.0.0-M4 secured with GitLab CE OIDC, 50 test flows and 130 FlowFiles held in queues.
- NiFi Registry 2.0.0-M4 with 63 flow versions.
- Upgrade, rollback, re-upgrade and the GitLab migration all verified with no data loss.

**Not yet tested:** a real multi-node cluster, external ZooKeeper (including the backup hook), client-certificate
authentication, and large repositories. Rehearse on staging before production — see
[RUNBOOK.md §8](RUNBOOK.md#8-test-evidence-single-node-2026-10-02).

## Safety notes

- The scripts never `kill -9` NiFi. Each backup is verified with a checksum before a rollback uses it.
- Rollback moves the data the new version touched to `*.failed-<version>-<timestamp>` instead of deleting it.
- Keep secrets out of this repository. `.gitignore` excludes `nifi-upgrade.conf`, `*.env` and token files.
