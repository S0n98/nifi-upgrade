# Step-by-step: offline upgrade of a 3-node NiFi cluster on RHEL 9 (2.0.0-M4 → 2.12.0)

Environment assumed by this guide:

| | |
|---|---|
| Nodes | `10.0.178.10`, `10.0.178.11`, `10.0.178.12` — RHEL 9, python3, unzip and curl installed, **no internet access** |
| NiFi now | 2.0.0-M4, systemd service `nifi`, installed under `/data` as described in Phase 0 |
| ZooKeeper | external |
| Admin host | a RHEL 9 machine inside the network, with SSH to the nodes (user with passwordless sudo) |
| Transfer host | any machine **with** internet access (ideally RHEL 9), used only to build the offline bundle |

Java: NiFi 2.0.0-M4 already requires Java 21, so the nodes already have the right Java and the bundle does not
include it. Step 3.2 checks this.

For background on what each script step does, see [RUNBOOK.md](RUNBOOK.md). This guide is the operator checklist.

---

## Phase 0 — Install layout under `/data` and the systemd unit

Do this once, before the upgrade project starts. The scripts and every later phase assume this layout.

### 0.1 Target layout (same on every node)

```
/data/nifi/                       install base            (NIFI_BASE in nifi-upgrade.conf)
├── nifi-2.0.0-M4/                unpacked release
├── nifi-2.12.0/                  added by "stage"
├── current -> nifi-2.0.0-M4      the active release      (NIFI_LINK) - "upgrade" switches it
└── .staging/                     release zip during stage
/data/nifi-data/                  everything that must survive an upgrade or rollback
├── flow/                         flow.json.gz + archive/
├── flowfile_repository/  content_repository/  provenance_repository/  database_repository/
├── state/local/                  local component state
├── auth/                         users.xml, authorizations.xml
├── python-extensions/            custom Python processors
├── work/python/                  pip-installed processor dependencies (reused across versions)
├── logs/                         nifi-app.log, nifi-bootstrap.log, nifi-user.log  (set by the systemd unit)
└── run/                          pid file                                          (set by the systemd unit)
/data/backups/nifi/               BACKUP_DIR - better on another disk if you have one
```

Nothing that holds data lives inside `nifi-<version>/`. That is what lets the upgrade switch only the symlink, and
`preflight` fails otherwise. Keystores and truststores may stay in `conf/`, because `stage` copies them to the new
version.

### 0.2 Paths in the NiFi configuration

In `/data/nifi/current/conf/nifi.properties`:

```properties
nifi.flow.configuration.file=/data/nifi-data/flow/flow.json.gz
nifi.flow.configuration.archive.dir=/data/nifi-data/flow/archive/
nifi.database.directory=/data/nifi-data/database_repository
nifi.flowfile.repository.directory=/data/nifi-data/flowfile_repository
nifi.content.repository.directory.default=/data/nifi-data/content_repository
nifi.provenance.repository.directory.default=/data/nifi-data/provenance_repository
nifi.python.extensions.source.directory.default=/data/nifi-data/python-extensions
nifi.python.working.directory=/data/nifi-data/work/python
```

In `conf/state-management.xml`, inside the `local-provider` block:

```xml
<property name="Directory">/data/nifi-data/state/local</property>
```

In `conf/authorizers.xml`, file-user-group-provider and file-access-policy-provider:

```xml
<property name="Users File">/data/nifi-data/auth/users.xml</property>
<property name="Authorizations File">/data/nifi-data/auth/authorizations.xml</property>
```

### 0.3 Moving an existing M4 install to `/data` (one-time, short downtime)

Skip this if NiFi already runs from `/data/nifi/current` with data in `/data/nifi-data`. Otherwise do it as its own
change, **before** the upgrade window, and check the cluster afterwards. The example assumes the old install is
`/opt/nifi/nifi-2.0.0-M4` with data in `/opt/nifi/nifi-2.0.0-M4/*_repository` etc.; adapt the source paths.

1. Stop **all three** nodes (`sudo systemctl stop nifi`). Wait until `pgrep -u nifi -f org.apache.nifi` prints nothing.
2. On every node, copy and keep the original until the cluster is verified:
   ```bash
   sudo mkdir -p /data/nifi /data/nifi-data/{flow,state,auth,work,logs,run} /data/backups/nifi
   sudo rsync -aHAX /opt/nifi/nifi-2.0.0-M4/ /data/nifi/nifi-2.0.0-M4/
   cd /data/nifi/nifi-2.0.0-M4
   for d in flowfile_repository content_repository provenance_repository database_repository; do
     [ -d "$d" ] && sudo mv "$d" /data/nifi-data/
   done
   sudo mv conf/flow.json.gz conf/archive /data/nifi-data/flow/ 2>/dev/null || true
   sudo mv state/local /data/nifi-data/state/ 2>/dev/null || true
   sudo mv conf/users.xml conf/authorizations.xml /data/nifi-data/auth/ 2>/dev/null || true
   sudo mv python/extensions /data/nifi-data/python-extensions 2>/dev/null || sudo mkdir -p /data/nifi-data/python-extensions
   sudo ln -sfn /data/nifi/nifi-2.0.0-M4 /data/nifi/current
   sudo chown -R nifi:nifi /data/nifi /data/nifi-data /data/backups/nifi
   ```
   If your repositories were already somewhere else (absolute paths), move those directories instead.
3. Edit the paths in 0.2 on every node.
4. Install the systemd unit (0.5) and label for SELinux (0.4).
5. Start **all three** nodes, then check that all are connected:
   ```bash
   curl -s --cacert ca.pem --cert admin.crt --key admin.key https://10.0.178.10:8443/nifi-api/controller/cluster | grep -o '"status":"[A-Z]*"'
   ```
   Check also that queues show the same counts as before and `/data/nifi-data/logs/nifi-app.log` has no errors.
   Only then remove `/opt/nifi/nifi-2.0.0-M4`.

### 0.4 SELinux (RHEL 9, enforcing)

Files created under `/data` get the generic label `default_t`. systemd will not execute `nifi.sh` with that label;
`systemctl status nifi` then shows `status=203/EXEC` and the audit log has an AVC denial. Label the `bin/`
directories of every release as executables. The rule also covers releases unpacked later, such as 2.12.0:

```bash
sudo dnf list installed policycoreutils-python-utils   # provides semanage (normally present on RHEL 9 servers)
sudo semanage fcontext -a -t bin_t '/data/nifi/nifi-[^/]+/bin(/.*)?'
sudo restorecon -Rv /data/nifi
ls -Z /data/nifi/current/bin/nifi.sh                   # expect ...:bin_t:...
```

After starting NiFi, `sudo ausearch -m avc -ts recent` should show nothing for nifi. Check `getenforce` first; on
`Permissive` or `Disabled` nodes this step changes nothing.

### 0.5 Install the systemd unit

Use [`systemd/nifi.service`](systemd/nifi.service) from this repository:

```bash
sudo cp systemd/nifi.service /etc/systemd/system/nifi.service
readlink -f "$(command -v java)"      # adjust JAVA_HOME in the unit if Java 21 lives elsewhere
sudo systemctl daemon-reload
sudo systemctl enable nifi
```

What the unit does:

| Setting | Why |
|---|---|
| `ExecStart=/data/nifi/current/bin/nifi.sh run`, `WorkingDirectory=/data/nifi/current` | always runs the release the symlink points to, so the upgrade and rollback never touch the unit |
| `NIFI_OVERRIDE_NIFIENV=true` + `NIFI_LOG_DIR` / `NIFI_PID_DIR` | logs and pid in `/data/nifi-data`, so they stay put when the release changes (2.0.0-M4 and 2.12.0 both honour this) |
| `KillMode=mixed`, `TimeoutStopSec=600` | stop sends SIGTERM only to the bootstrap, which shuts NiFi down cleanly (repositories flushed); never a quick SIGKILL |
| `Restart=on-failure`, `StartLimitBurst=5` in 15 min | restarts after a crash, but stops retrying on a persistent fault (full disk, bad config) instead of looping |
| `LimitNOFILE=50000` | NiFi needs many open files (repositories, connections) |

`nifi-upgrade.sh` includes the unit file in its backups and does not change it.

---

## Phase 1 — Find out what the bundle must contain (on one node, read-only)

### 1.1 Do your flows use Python processors?

```bash
ssh ops@10.0.178.10
sudo zcat "$(sudo grep '^nifi.flow.configuration.file=' /data/nifi/current/conf/nifi.properties | cut -d= -f2-)" \
  | grep -c '"artifact":"python-extensions"'
python3 --version
```

- **0** → no Python processors. Skip 1.2 and every "Python" step below.
- **More than 0** → read this: **NiFi 2.12 runs Python processors only with Python 3.10, 3.11 or 3.12. RHEL 9's
  `python3` is 3.9.** You will install `python3.12` from the bundle (step 3.3), otherwise those processors
  stop working after the upgrade. The upgrade `preflight` refuses to continue until this is fixed.

### 1.2 (Python only) Do your Python processors need extra packages?

```bash
D=$(sudo grep '^nifi.python.extensions.source.directory.default=' /data/nifi/current/conf/nifi.properties | cut -d= -f2-)
sudo find "$D" -name requirements.txt                      # file-based dependencies
sudo grep -rlE '^\s*dependencies\s*=' --include='*.py' "$D"  # inline dependencies in ProcessorDetails
```

Copy every `requirements.txt` you find, and the dependency lists from those `.py` files, to the transfer host. If
nothing is found, NiFi needs no packages and you can skip the wheels.

### 1.3 Note the facts you will need later

```bash
sudo grep -E '^nifi\.(web\.https\.(host|port)|cluster\.node\.address|zookeeper\.connect\.string|python\.(command|working\.directory))=' \
  /data/nifi/current/conf/nifi.properties
df -h /data /data/backups           # need >= 4 GB in /data/nifi, plus room for a full data backup
command -v zstd || echo "no zstd -> use BACKUP_COMPRESS=gzip"
```

---

## Phase 2 — Build the offline bundle (transfer host, with internet)

### 2.1 Get the project

```bash
git clone https://github.com/S0n98/nifi-upgrade.git
cd nifi-upgrade
```

### 2.2 Build the bundle

The script downloads `nifi-2.12.0-bin.zip`, verifies its SHA-512 and its Apache PGP signature, and packs everything
into one tarball with a checksum manifest.

```bash
# no Python processors:
offline/prepare-offline-bundle.sh

# Python processors -> run on a RHEL 9 host with repos enabled to also get python3.12 RPMs:
offline/prepare-offline-bundle.sh -p

# Python processors with dependencies -> add every requirements file from step 1.2:
offline/prepare-offline-bundle.sh -p -r /path/to/requirements.txt
```

Expected end of output:

```
SHA-512 OK
PGP signature OK: Good signature from "..."
manifest: NN files, ~850M
bundle: .../nifi-offline-bundle-2.12.0.tar (...), sha256 in .tar.sha256
```

If the PGP line says `WARN gpg not installed`, install `gnupg2` and run again. The script resumes and does not
download the zip again.

### 2.3 Carry two files into the network

`nifi-offline-bundle-2.12.0.tar` and `nifi-offline-bundle-2.12.0.tar.sha256` → admin host, e.g. `/srv/nifi-upgrade/`.

---

## Phase 3 — Prepare the admin host and the nodes (inside the network, no downtime)

### 3.1 Unpack and verify on the admin host

```bash
cd /srv/nifi-upgrade
sha256sum -c nifi-offline-bundle-2.12.0.tar.sha256          # -> OK
tar -xf nifi-offline-bundle-2.12.0.tar
cd nifi-offline-bundle-2.12.0
sha256sum -c --quiet MANIFEST.sha256 && echo "bundle intact"
cat VERSIONS.txt
```

From here on, `B=/srv/nifi-upgrade/nifi-offline-bundle-2.12.0`.

### 3.2 Check SSH, sudo and Java on every node

```bash
for n in 10.0.178.10 10.0.178.11 10.0.178.12; do
  echo "== $n"; ssh -o BatchMode=yes ops@$n 'sudo -n true && sudo -u nifi java -version 2>&1 | head -1'
done
```

Every node must print a `21.x` version. The scripts need passwordless sudo, which `sudo -n true` checks.

### 3.3 (Python processors only) Install Python 3.12 on every node

```bash
for n in 10.0.178.10 10.0.178.11 10.0.178.12; do
  scp -r $B/rpms ops@$n:/tmp/py312-rpms
  ssh ops@$n 'sudo dnf install -y --disablerepo="*" /tmp/py312-rpms/*.rpm && python3.12 --version && rm -rf /tmp/py312-rpms'
done
```

Then point NiFi at it. Edit the **current (M4)** config on every node. The upgrade carries this setting over; M4
itself picks it up at its next restart and works with 3.12 as well:

```bash
sudo sed -i 's/^#\?nifi.python.command=.*/nifi.python.command=python3.12/' /data/nifi/current/conf/nifi.properties
```

### 3.4 (Python processors with dependencies only) Local package source on every node

NiFi runs `pip install` for these processors the first time 2.12.0 starts, so pip must find the packages locally:

```bash
for n in 10.0.178.10 10.0.178.11 10.0.178.12; do
  scp -r $B/wheels ops@$n:/tmp/wheels
  ssh ops@$n 'sudo mkdir -p /data/nifi-wheels && sudo cp /tmp/wheels/*.whl /data/nifi-wheels/ && rm -rf /tmp/wheels &&
              printf "[global]\nno-index = true\nfind-links = /data/nifi-wheels\n" | sudo tee /etc/pip.conf'
done
```

Also check `nifi.python.working.directory` from step 1.3. If it is relative (default `./work/python`), NiFi installs
the dependencies again for the new version, which works with the local source above. If it points outside
`/data/nifi`, the installed packages are reused.

### 3.5 API credentials for the automation

`nifi-upgrade.sh` calls the NiFi REST API. OIDC browser logins can't be scripted, so use an **admin client
certificate**:

- If you already have one (DN with admin policies), use it.
- Otherwise issue one with `runbook/certs/gen-nifi-certs.sh` and add its DN as a user with the admin's policies.
  [certs/NIFI-TLS.md](certs/NIFI-TLS.md) §4–6 explains how. The CA must be in the nodes' truststore.

Test from the admin host:

```bash
curl -s --cacert /path/ca.pem --cert /path/admin.crt --key /path/admin.key \
  https://10.0.178.10:8443/nifi-api/flow/current-user | grep -o '"identity":"[^"]*"'
```

### 3.6 Write the configuration

```bash
cd $B/runbook
cp nifi-upgrade.conf.example nifi-upgrade.conf
grep DIST_SHA512 $B/nifi/DIST_SHA512          # value to paste below
```

Edit `nifi-upgrade.conf`:

```bash
NODES="10.0.178.10 10.0.178.11 10.0.178.12"      # or the hostnames from your certificates
SSH_USER=ops
NIFI_API_URL=https://10.0.178.10:8443/nifi-api   # must match a name/IP in the node certificate SAN

OLD_VERSION=2.0.0-M4
NEW_VERSION=2.12.0
DIST_URL=                                        # empty = offline
DIST_ZIP=/srv/nifi-upgrade/nifi-offline-bundle-2.12.0/nifi/nifi-2.12.0-bin.zip
DIST_SHA512=<value from nifi/DIST_SHA512>

NIFI_BASE=/data/nifi
NIFI_LINK=/data/nifi/current
SERVICE=nifi
NIFI_USER=nifi
MIN_FREE_GB=4

BACKUP_DIR=/data/backups/nifi                    # another disk is better than /data itself
BACKUP_COMPRESS=gzip                             # zstd only if every node has zstd (step 1.3)
BACKUP_EXTRA_PATHS=""                            # e.g. "/etc/nifi-tls" if certs live outside conf/

ZK_BACKUP_CMD='ssh ops@<zk-host> "sudo tar -czf /var/backups/zk-pre-nifi-2.12.0.tgz -C /var/lib/zookeeper ."'

NIFI_CA_CERT=/path/ca.pem
NIFI_CLIENT_CERT=/path/admin.crt
NIFI_CLIENT_KEY=/path/admin.key
```

> ZooKeeper backup: use your ZooKeeper team's standard method. A copy of the data directory is consistent only
> while NiFi (its only writer) is stopped, which is when the script runs this command.

---

## Phase 4 — Preflight and stage (the day before, no downtime)

### 4.1 Preflight (read-only)

```bash
cd $B/runbook
./nifi-upgrade.sh -c nifi-upgrade.conf preflight
```

It must end with `PREFLIGHT PASSED`. Per-node details are in `runs/<date>-2.0.0-M4-to-2.12.0/<node>.preflight.log`.
On RHEL 9, look for these lines:

| Line | Meaning / action |
|---|---|
| `ok java 21` | — |
| `FAIL data path inside install dir` | move that directory out of `/data/nifi/nifi-2.0.0-M4` first (RUNBOOK §3 item 2) |
| `INFO stage expects DIST_ZIP pushed from the admin host` | correct for offline |
| `FAIL flow uses Python processors but nifi.python.command=... is Python 3.9` | do step 3.3 |
| `WARN Python processors declare pip dependencies ...` | do step 3.4 |
| `INFO flow contains Python processors typed 'python.<Name>'` | expected; fixed automatically during the upgrade |
| `cluster healthy: 2.0.0-M4, 3 nodes connected` | — |

### 4.2 Stage

```bash
./nifi-upgrade.sh -c nifi-upgrade.conf stage
```

This copies the zip to each node, verifies its SHA-512, unpacks `/data/nifi/nifi-2.12.0` and carries the
configuration over. The running cluster is not touched.

### 4.3 Review the per-node report

```bash
for n in 10.0.178.10 10.0.178.11 10.0.178.12; do
  echo "== $n"; ssh ops@$n 'grep -E "^(REVIEW|bootstrap)" /data/nifi/upgrade-report-2.0.0-M4-to-2.12.0.txt'
done
```

Expected `REVIEW` lines on a stock config. All of these are harmless:
- removed properties `nifi.cluster.protocol.is.secure`, `nifi.content.viewer.url`,
  `nifi.documentation.working.directory`, `nifi.listener.bootstrap.port`;
- bootstrap keys `java=java`, `nifi.bootstrap.listen.port`;
- a note to re-apply custom `logback.xml` changes, if you had any.

Anything else needs a decision before the window.

### 4.4 SELinux (only if enforcing)

```bash
for n in 10.0.178.10 10.0.178.11 10.0.178.12; do ssh ops@$n 'getenforce; sudo restorecon -R /data/nifi/nifi-2.12.0; ls -Z /data/nifi/nifi-2.12.0/bin/nifi.sh'; done
```

With the `semanage` rule from 0.4, the new `bin/` gets `bin_t` like the old one. Without it, the switch in 5.2
starts NiFi into `203/EXEC`. No firewall changes are needed, because the ports stay the
same.

---

## Phase 5 — The maintenance window

Budget **30–60 minutes**. Steps 5.2–5.5 are downtime.

| # | Do | Command | Continue only if |
|---|---|---|---|
| 5.1 | Re-run preflight | `./nifi-upgrade.sh -c nifi-upgrade.conf preflight` | `PREFLIGHT PASSED` |
| 5.2 | Upgrade (type `yes`) | `./nifi-upgrade.sh -c nifi-upgrade.conf upgrade` | ends with `VERIFY PASSED` |
| 5.3 | Smoke test, everything still stopped | UI on each node: log in, open a few process groups, bulletins empty, list a queue | no errors |
| 5.4 | Resume | `./nifi-upgrade.sh -c nifi-upgrade.conf resume` | `not running: none` |
| 5.5 | Watch 15–30 min | throughput, queues, bulletins, heap, `/data/nifi-data/logs/nifi-app.log`, `df -h /data` | normal |
| 5.6 | Finalize | `./nifi-upgrade.sh -c nifi-upgrade.conf finalize` | `finalize ok` ×3 |

What 5.2 prints, in order:

```
recorded .../pre-upgrade.json: NiFi 2.0.0-M4, nodes=3, processors=..., queued=N FlowFiles / B bytes
stopping X source processors ... queues settled at N FlowFiles
  [10.0.178.10] stop ok      (and .11, .12)
ZooKeeper backup: ...
  [10.0.178.10] backup ok    patch-flow ok    switch ok    start ok
cluster: 3/3 nodes connected
PASS S controller services enabled on new version
PASS queued data preserved: N/B -> N/B
PASS no ghost components / no newly invalid processors / registry clients / ... / version control of P PGs unchanged
VERIFY PASSED - components are still stopped
```

If 5.2 ends with **VERIFY FAILED**, nothing has been restarted. Read the `FAIL` lines and fix the problem, then run
`./nifi-upgrade.sh -c nifi-upgrade.conf verify` again, or roll back (Phase 7). Don't run `resume` while verify fails.

---

## Phase 6 — After the upgrade

1. **Health checks / monitoring**: `/nifi-api/access/config` now answers 401. Switch checks to `/nifi-api/flow/about`
   with credentials, or to a TCP check.
2. **Scripts and CI jobs** that set processor properties through the API: 2.12 renames many legacy keys (e.g.
   `generate-ff-custom-text` → `Custom Text`). Update them.
3. **NiFi Registry → GitLab** (optional, no downtime, any time later): [RUNBOOK.md §6](RUNBOOK.md#6-nifi-registry-200-m4--gitlab-flow-registry-client-after-the-upgrade-no-downtime).
   It needs only internal network access to GitLab.
4. **Clean up after 1–2 weeks** of stable running, on each node:
   `sudo rm -rf /data/nifi/nifi-2.0.0-M4 /data/nifi/.staging` and old backups in `/data/backups/nifi`. Keep the
   bundle tarball until then.

## Phase 7 — Rollback

Trigger: nodes don't connect, VERIFY FAILED and not fixable in the window, or data problems after resume.

```bash
./nifi-upgrade.sh -c nifi-upgrade.conf rollback        # type 'yes'
```

On each node, the script:
1. Stops NiFi and moves the data directories 2.12 touched to `*.failed-2.12.0-<time>`.
2. Restores the backup taken in step 5.2 (checksum verified) and points the link back to 2.0.0-M4.
3. Starts NiFi. The cluster comes back with the components that were running before.

Restore ZooKeeper from the `ZK_BACKUP_CMD` copy as well if cluster-scope state must go back.

Not undone by a rollback: data already delivered by 2.12, and commits already pushed to a flow registry.

## Phase 8 — Where to look when something goes wrong

| Where | What |
|---|---|
| `runs/<date>-2.0.0-M4-to-2.12.0/upgrade.log` | everything the orchestrator did |
| `runs/.../<node>.<step>.log` | node-side output of each step |
| `runs/.../baseline.json`, `baseline.post.json` | what was recorded before and found after |
| node: `/data/nifi/upgrade-report-2.0.0-M4-to-2.12.0.txt` | configuration carry-over report |
| node: `/data/nifi-data/logs/nifi-app.log`, `nifi-bootstrap.log` | NiFi startup, Python, cluster join |
| node: `journalctl -u nifi` | service start/stop, JVM errors |
| node: `df -h` | a full disk stops NiFi — keep ≥ 20 % free on data and log filesystems |

---

**Tested vs not tested.** The scripts were tested end to end on a single node, including upgrade, rollback,
re-upgrade and the GitLab migration (see RUNBOOK §8). The bundle script was tested with a small Apache artifact
and a sample `requirements.txt`.

**Not yet tested:**
- a full run against this 3-node RHEL 9 cluster;
- `dnf download` of the Python 3.12 RPMs (`-p`);
- the offline `DIST_ZIP` path in cluster mode.

Rehearse on a staging copy of the cluster first.
