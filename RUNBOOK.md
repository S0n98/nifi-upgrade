# Runbook — NiFi cluster upgrade 2.0.0-M4 → 2.12.0 (+ NiFi Registry → GitLab)

Target: 3-node NiFi cluster, external ZooKeeper, systemd, layout `/opt/nifi/nifi-<version>` + symlink `/opt/nifi/current`,
all data outside the install directory. Automation: `nifi-upgrade.sh` (run from an admin host over SSH).

> **Why a full-stop upgrade:** NiFi nodes of different versions cannot form one cluster, and 2.0.0-M4 → 2.12.0 is a
> milestone → GA jump. All nodes are stopped together, upgraded, and started together. Plan a downtime window.
> Measured on the test system: **~2 min of downtime** (quiesce 35 s, stop/backup/switch 10 s, start + verify 80 s) —
> budget 30–60 min on a real cluster (bigger repositories to back up, flow election, slower verification).

## 1. Files

| File | Purpose |
|---|---|
| `nifi-upgrade.sh` | Orchestrator: `preflight`, `stage`, `upgrade`, `verify`, `resume`, `finalize`, `rollback`, `status`, `all` |
| `lib/nifi-node.sh` | Node agent, copied to each node by the orchestrator (preflight, stage+configure, stop, backup, patch-flow, switch, start, finalize, rollback) |
| `lib/nifi_api.py` | Cluster-level REST work: record run state, quiesce, wait for nodes, verify, resume |
| `migrate-registry-to-gitlab.py` | Moves versioned process groups from a NiFi Registry client to the GitLab Flow Registry Client **with full version history** |
| `nifi-upgrade.conf.example` | Config template — copy to `nifi-upgrade.conf` and edit |

## 2. What the automation does

```
preflight  read-only: Java 21, python3/unzip, disk, sensitive key set, every data path outside the install dir,
           backup space, custom NARs, Python processors, network needs (release zip source, Python pip
           dependencies); cluster: all nodes CONNECTED, no ghost components
stage      no downtime: get the zip (DIST_URL download, or DIST_ZIP pushed from the admin host / already in
           STAGE_DIR), SHA-512 check, unzip next to the old version, carry configuration:
             nifi.properties   OLD values for every key present in both versions (incl. keys the new file ships
                               commented-out, e.g. nifi.python.command); removed keys -> REVIEW list
             bootstrap.conf    heap/java.arg values carried; removed keys -> REVIEW list
             authorizers.xml, login-identity-providers.xml, state-management.xml, zookeeper.properties: copied
             keystores/truststores/users.xml/... (anything in conf/ the distribution does not ship): copied
             logback.xml       not copied, flagged if customised
           report: /opt/nifi/upgrade-report-2.0.0-M4-to-2.12.0.txt on every node
upgrade    DOWNTIME
  record     which processors/ports/reporting tasks run, which services are enabled, queue totals, versioning
  quiesce    stop source processors (no input allowed), wait until queues drain or stop changing, stop root group
  stop       systemctl stop on all nodes in parallel, waits for the JVM to exit (never kill -9)
  ZK backup  optional ZK_BACKUP_CMD (cluster-scope state lives in ZooKeeper)
  backup     tar of flow dir, all repositories, state dir, python extensions, users/authorizations files,
             old conf/, systemd unit -> BACKUP_DIR (sha256 alongside)
  patch-flow 2.0.0-M4 stored Python processors as "python.<Name>", 2.12 registers "<Name>" -> rename in flow.json.gz
  switch     /opt/nifi/current -> nifi-2.12.0, nifi.flowcontroller.autoResumeState=false for the first start
  start      all nodes together (flow election), wait until all are CONNECTED
  verify     enable the services that were enabled before, then compare with the recorded baseline:
             queued FlowFiles + bytes identical, processor count, no ghost / newly invalid components,
             registry clients, parameter contexts, users, version-control state of every versioned PG
resume     restart exactly the components that were running before the upgrade (services first, sources last)
finalize   restore autoResumeState on every node (no restart needed)
rollback   restore every node from its backup, point the symlink back, start the old version, resume baseline
```

## 3. Prerequisites (do these well before the window)

1. **Rehearse on staging** with a copy of production flow + config (see §8 for what was and was not tested).
2. **Data outside the install directory.** `preflight` fails on any repository/state/flow path under `/opt/nifi/nifi-2.0.0-M4`.
   Fix on the old version first (stop, move the directory, update `nifi.properties`, start).
3. **Admin host**: bash, python3, ssh to every node as a user with passwordless sudo.
4. **Nodes**: Java 21 for the `nifi` user, python3, unzip, `MIN_FREE_GB` free under `/opt/nifi`, space for the backup.
5. **API credentials for automation**: an admin client certificate (`NIFI_CLIENT_CERT/KEY`) with the same policies
   as the NiFi admin (OIDC browser logins cannot be scripted reliably). Alternatively `NIFI_TOKEN_CMD`.
6. **Back up separately**: `nifi.sensitive.props.key` (in `nifi.properties`), keystores and their passwords, ZooKeeper.
7. **Custom NARs**: rebuild them against 2.12.0. Custom Python processors: test them on 2.12.0
   (the type-name change is handled by `patch-flow`; API changes are not).
8. **Automation that talks to the NiFi API** (CI jobs, scripts): 2.12 renames many legacy property keys
   (e.g. `generate-ff-custom-text` → `Custom Text`). Update scripts that set properties by key.
9. **Monitoring/health checks**: `GET /nifi-api/access/config` answers 401 on 2.12 (was 200). Use
   `/nifi-api/flow/about` with credentials, or a TCP check.
10. Fill in `nifi-upgrade.conf` (copy the example). Get `DIST_SHA512` from
    `https://archive.apache.org/dist/nifi/2.12.0/nifi-2.12.0-bin.zip.sha512` and verify the `.asc` signature
    against the Apache NiFi `KEYS` file.
11. **Network / air-gapped nodes.** The upgrade needs no internet access if you prepare these
    (`preflight` reports each one):
    * **Release zip**: download and verify it on a connected machine, then set `DIST_ZIP=/path/on/admin-host.zip`
      and leave `DIST_URL` empty (the zip is copied to every node), or place `nifi-2.12.0-bin.zip` in `STAGE_DIR`
      on each node.
    * **Python processor dependencies**: NiFi runs `pip install` on first start for Python processors that declare
      dependencies (`requirements.txt` / `ProcessorDetails.dependencies`), into `nifi.python.working.directory`
      (default `./work/python` = inside the install dir, so every new version re-installs). Externalize that
      directory before the upgrade (e.g. `/var/lib/nifi/work/python`, it is then carried over and reused), or
      point pip at an internal mirror: `/etc/pip.conf` (`index-url = ...`), and `UV_INDEX_URL` if `uv` is
      installed (NiFi prefers `uv`). Processors without dependencies need nothing.
    * **OS packages** (Java 21, python3, unzip) from an internal mirror; the **OIDC IdP** must be reachable from
      every node at startup (an internal IdP is fine).

## 4. Procedure

### T-1 day (no downtime)

```bash
cp nifi-upgrade.conf.example nifi-upgrade.conf && vi nifi-upgrade.conf
./nifi-upgrade.sh -c nifi-upgrade.conf preflight      # must end with PREFLIGHT PASSED
./nifi-upgrade.sh -c nifi-upgrade.conf stage          # unpacks + configures 2.12.0 next to 2.0.0-M4
```
Review `/opt/nifi/upgrade-report-2.0.0-M4-to-2.12.0.txt` on every node. Every `REVIEW` line needs a decision.
Expected on a stock config: removed keys `nifi.cluster.protocol.is.secure`, `nifi.content.viewer.url`,
`nifi.documentation.working.directory`, `nifi.listener.bootstrap.port`; bootstrap keys `java`, `nifi.bootstrap.listen.port`.
Stage can be re-run with `FORCE_RESTAGE=yes`.

### T-0 — the window

| # | Step | Command | Go / No-go |
|---|---|---|---|
| 1 | Announce, pause upstream producers if they can buffer | — | |
| 2 | Re-run preflight | `./nifi-upgrade.sh -c nifi-upgrade.conf preflight` | PASSED, all nodes CONNECTED |
| 3 | Upgrade | `./nifi-upgrade.sh -c nifi-upgrade.conf upgrade` (asks for `yes`) | ends with `VERIFY PASSED` |
| 4 | Smoke-test while components are still stopped | UI: login, open flows, check bulletins, list a queue | no errors |
| 5 | Resume | `./nifi-upgrade.sh -c nifi-upgrade.conf resume` | `not running: none` |
| 6 | Watch 15–30 min | UI / metrics: throughput, back pressure, bulletins, heap | normal |
| 7 | Finalize | `./nifi-upgrade.sh -c nifi-upgrade.conf finalize` | `finalize ok` on every node |

If `upgrade` stops with **VERIFY FAILED**, nothing has been resumed. Read the FAIL lines, fix what can be fixed
(then `./nifi-upgrade.sh -c nifi-upgrade.conf verify`) or roll back (§5).

Logs: `runs/<date>-2.0.0-M4-to-2.12.0/` (orchestrator log, one log per node and step, `baseline.json`, `baseline.post.json`).

## 5. Rollback

Triggers: nodes do not connect, VERIFY FAILED and not fixable within the window, data errors after resume.

```bash
./nifi-upgrade.sh -c nifi-upgrade.conf rollback
```
Per node: stop NiFi, move every data directory the new version touched to `<dir>.failed-2.12.0-<ts>` (kept for analysis),
restore the backup (checksum verified), point `/opt/nifi/current` back to 2.0.0-M4, start. Then the orchestrator waits
for the cluster and restarts what was running before the upgrade. Restore ZooKeeper from its backup if
cluster-scope state must also go back.

Not undone by a rollback:
* data that NiFi 2.12 already **delivered** downstream (it will not be re-sent, nothing is lost)
* commits made to an external flow registry after the upgrade — affected PGs show `STALE` / `LOCALLY_MODIFIED_AND_STALE`

## 6. NiFi Registry 2.0.0-M4 → GitLab Flow Registry Client (after the upgrade, no downtime)

2.0.0-M4 has no GitLab client; 2.12.0 has `GitLabFlowRegistryClient`. NiFi 2.12 works fine with Registry 2.0.0-M4
(commit, change version, revert all tested), so migrate **after** the upgrade has settled.

Network: internal only. The tool talks to the NiFi API; NiFi talks to NiFi Registry and to GitLab; the tool calls
the GitLab API directly only to create missing bucket directories. Every NiFi node needs HTTPS to GitLab (outbound
internet only if you use gitlab.com).

1. GitLab: project (e.g. `nifi/nifi-flows`, branch `main`), project access token (role Maintainer, scope `api`).
2. NiFi (Controller Settings): if GitLab uses a private CA, create a controller-level **StandardSSLContextService**
   with a truststore holding that CA. Add a **GitLabFlowRegistryClient**: API URL, Repository Namespace, Repository Name,
   Access Token, Default Branch, SSL Context Service. Buckets are top-level directories of the repository.
3. Bring every versioned PG to `UP_TO_DATE` (commit or revert local changes, update stale ones). The tool skips others.
4. Dry run, then migrate (one flow first):
   ```bash
   export NIFI_API_URL=... NIFI_CLIENT_CERT=... NIFI_CLIENT_KEY=... NIFI_CA_CERT=...
   ./migrate-registry-to-gitlab.py --source-client <registry client name> --target-client <gitlab client name> \
       --gitlab-url https://gitlab.example.com --gitlab-project nifi/nifi-flows --gitlab-token-file token.env --dry-run
   ./migrate-registry-to-gitlab.py ... --only <one PG name>
   ./migrate-registry-to-gitlab.py ...                       # all; safe to re-run (resumes, never duplicates history)
   ```
   Result per flow in `<bucket>/<flow name>.json`: one git commit per Registry version
   (`[migrated from NiFi Registry vN] <original comment> (author, timestamp)`) + one `[migrated] cutover` commit;
   the live PG tracks GitLab and is `UP_TO_DATE`. The JSON report maps every Registry version to its git SHA.
5. Check: every PG `UP_TO_DATE` on the GitLab client; change one flow to an old version and back; commit a change.
6. Retire the Registry: confirm no PG references the old client, delete the client, stop + disable `nifi-registry`.
   Keep its data directory until you no longer need the history there.

Limits: nested versioned PGs are refused (migrate manually); git versions are commit SHAs, not numbers; commits are
authored by the token's bot user (original author is kept in the message); snapshots written by 2.12 use the new
property names (values identical — verified on 63 versions).

## 7. Problems found while testing

| Problem | Effect if missed | Handling |
|---|---|---|
| Python processor type `python.X` (M4) vs `X` (2.12) | processors load as ghosts, flow invalid | `patch-flow` before first start |
| `nifi.python.command` is commented out in 2.12 `nifi.properties` | Python processors disabled after upgrade | `stage` uncomments + carries it |
| `autoResumeState=false` also leaves controller services disabled | dependent processors invalid at verify | `verify` enables baseline services first |
| 2.12 renames legacy property keys, adds new properties | API scripts silently set ignored keys | prerequisite 8 |
| `/access/config` returns 401 on 2.12 | health checks report NiFi down | prerequisite 9 |
| Removed `nifi.properties` / `bootstrap.conf` keys | none (ignored), but config drift | REVIEW lines in the stage report |
| Fresh OIDC install: initial admin gets no root-group policies | admin cannot edit the flow | not upgrade-related; grant once via Policies |

## 8. Test evidence (single node, 2026-10-02)

Environment: NiFi 2.0.0-M4 secured with GitLab CE 19.4.1 OIDC, 50 test flows (165 processors: record conversion,
routing, split/merge, ListFile state, ListenHTTP, sensitive parameters, custom Python processor, 130 FlowFiles held
in queues), NiFi Registry 2.0.0-M4 with 50 versioned flows / 63 versions.

* Upgrade with these scripts (`NODES=local`): verify 10/10, held FlowFiles byte-identical (SHA-256), 145 processors
  resumed, 31/31 functional checks, OIDC + authorization checks 9/9.
* Rollback with these scripts: back on 2.0.0-M4 in 2 min 40 s, held data identical, 145 processors resumed;
  second upgrade clean.
* Registry → GitLab: 50/50 flows, 63 versions, history order and content verified, version change / commit /
  import from GitLab all working; re-run after rollback resumed without duplicating history.

**Network:** the test host had internet access; downloads were the only external calls (release zips, GitLab image).
The test Python processor declares no dependencies, so NiFi did not run pip (log: "All dependencies have already been
imported"). The `DIST_ZIP` path in `local` mode and the pip-mirror setup were not exercised end to end.

**Not tested here** (rehearse on staging): a real multi-node cluster (parallel SSH, flow election, node reconnection),
external ZooKeeper and `ZK_BACKUP_CMD`, client-certificate API authentication, large repositories / backup duration.
