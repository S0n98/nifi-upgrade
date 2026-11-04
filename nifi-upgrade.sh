#!/usr/bin/env bash
# nifi-upgrade.sh - orchestrate a NiFi cluster upgrade (default 2.0.0-M4 -> 2.12.0) from an admin host.
#
#   nifi-upgrade.sh -c nifi-upgrade.conf preflight    read-only checks on every node + cluster inventory
#   nifi-upgrade.sh -c nifi-upgrade.conf stage        download/verify/unpack/configure the new version on every node (no downtime)
#   nifi-upgrade.sh -c nifi-upgrade.conf upgrade      DOWNTIME: record -> quiesce -> stop -> backup -> patch -> switch -> start -> verify
#   nifi-upgrade.sh -c nifi-upgrade.conf verify       re-run the post-start verification (services enabled, processors still stopped)
#   nifi-upgrade.sh -c nifi-upgrade.conf resume       restart exactly what was running before (after verify passed)
#   nifi-upgrade.sh -c nifi-upgrade.conf finalize     restore autoResumeState on every node
#   nifi-upgrade.sh -c nifi-upgrade.conf rollback     DOWNTIME: restore every node from its backup and start the old version
#   nifi-upgrade.sh -c nifi-upgrade.conf status       per-node link / service state
#   nifi-upgrade.sh -c nifi-upgrade.conf all          preflight + stage + upgrade + resume + finalize (asks before downtime)
#
# Options: -y      do not ask for confirmation before downtime steps
#          -z ZIP  release zip already downloaded to this admin host (overrides DIST_ZIP); copied to every node by stage.
#                  SHA-512 comes from DIST_SHA512, else from ZIP.sha512 next to it, else is computed from the zip itself.
#                  Without -z/DIST_ZIP/DIST_URL, ./nifi-<NEW_VERSION>-bin.zip (here or in the current dir) is used.
# NiFi 2.0.0-M4 and 2.12.0 nodes cannot be mixed in one cluster, so the upgrade stops ALL nodes together (no rolling upgrade).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="" ; YES=no ; ZIP_ARG=""
while getopts "c:yz:" o; do case $o in c) CONF=$OPTARG ;; y) YES=yes ;; z) ZIP_ARG=$OPTARG ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
CMD=${1:-}
[ -n "$CONF" ] && [ -f "$CONF" ] || { sed -n '2,19p' "$0"; exit 2; }
# Windows line endings (CRLF) break bash with errors like "set: pipefail\r: invalid option name"
CRLF=$(grep -lI $'\r' "$CONF" "$HERE"/lib/*.sh "$HERE"/lib/*.py 2>/dev/null || true)
[ -z "$CRLF" ] || { printf 'ERROR: Windows line endings (CRLF) in:\n%s\nfix with: sed -i '"'"'s/\\r$//'"'"' <files>\n' "$CRLF"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
[ -n "$ZIP_ARG" ] && DIST_ZIP=$ZIP_ARG

: "${NODES:?}" "${OLD_VERSION:?}" "${NEW_VERSION:?}" "${NIFI_API_URL:?}"
NIFI_BASE=${NIFI_BASE:-/data/soft/nifi}; NIFI_LINK=${NIFI_LINK:-$NIFI_BASE/current}; SERVICE=${SERVICE:-nifi}
BACKUP_DIR=${BACKUP_DIR:-/data/backups/nifi}; SSH_USER=${SSH_USER:-root}; SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}
RUN_DIR=${RUN_DIR:-$HERE/runs/$(date +%Y%m%d)-$OLD_VERSION-to-$NEW_VERSION}
mkdir -p "$RUN_DIR"
export OLD_VERSION NEW_VERSION NIFI_API_URL NIFI_TOKEN NIFI_TOKEN_CMD NIFI_CLIENT_CERT NIFI_CLIENT_KEY NIFI_CA_CERT NIFI_INSECURE DRAIN_TIMEOUT DRAIN_SETTLE_POLLS START_TIMEOUT
read -r -a NODE_LIST <<< "$NODES"
REMOTE_AGENT=/tmp/nifi-node-upgrade.sh

log() { printf '%s %s\n' "$(date +%FT%T)" "$*" | tee -a "$RUN_DIR/upgrade.log"; }
die() { log "ABORT: $*"; exit 1; }
api() { python3 "$HERE/lib/nifi_api.py" "$@" 2>&1 | tee -a "$RUN_DIR/upgrade.log"; return "${PIPESTATUS[0]}"; }
confirm() {
  [ "$YES" = yes ] && return 0
  read -r -p "$1 [type 'yes' to continue] " a; [ "$a" = yes ] || die "cancelled by operator"
}

agent_env() { # environment passed to the node agent
  local v
  for v in OLD_VERSION NEW_VERSION NIFI_BASE NIFI_LINK SERVICE BACKUP_DIR NIFI_USER STAGE_DIR MIN_FREE_GB DIST_URL DIST_SHA512 \
           BACKUP_COMPRESS BACKUP_EXTRA_PATHS COPY_CUSTOM_NARS FORCE_RESTAGE KEEP_ZIP ROLLBACK_BACKUP ROLLBACK_START; do
    if [ -n "${!v:-}" ]; then printf '%s=%q ' "$v" "${!v}"; fi
  done
  return 0
}

resolve_dist() { # decide where the release zip comes from; with a local zip, nodes never download anything
  if [ -z "${DIST_ZIP:-}" ] && [ -z "${DIST_URL:-}" ]; then
    local c; for c in "$HERE/nifi-$NEW_VERSION-bin.zip" "$PWD/nifi-$NEW_VERSION-bin.zip"; do
      [ -f "$c" ] && { DIST_ZIP=$c; break; }
    done
    [ -n "${DIST_ZIP:-}" ] || die "no release zip: use -z /path/nifi-$NEW_VERSION-bin.zip (or set DIST_ZIP or DIST_URL in $CONF)"
  fi
  if [ -z "${DIST_ZIP:-}" ]; then  # online: every node downloads DIST_URL and checks it against DIST_SHA512
    [ -n "${DIST_SHA512:-}" ] || die "DIST_SHA512 not set in $CONF (needed to check the DIST_URL download)"
    log "release: nodes download $DIST_URL"
    return 0
  fi
  DIST_ZIP=$(readlink -f "$DIST_ZIP"); DIST_URL=""
  [ -r "$DIST_ZIP" ] || die "cannot read $DIST_ZIP"
  python3 - "$DIST_ZIP" "nifi-$NEW_VERSION/bin/nifi.sh" <<'EOF' || die "$DIST_ZIP is not a NiFi $NEW_VERSION release zip"
import sys, zipfile
sys.exit(0 if sys.argv[2] in zipfile.ZipFile(sys.argv[1]).namelist() else 1)
EOF
  local file_sha="" sum
  [ -f "$DIST_ZIP.sha512" ] && file_sha=$(awk '{print $1; exit}' "$DIST_ZIP.sha512")
  if [ -n "${DIST_SHA512:-}" ] || [ -n "$file_sha" ]; then
    local want=${DIST_SHA512:-$file_sha}
    log "checking SHA-512 of $DIST_ZIP"
    echo "$want  $DIST_ZIP" | sha512sum -c --quiet - || die "SHA-512 mismatch for $DIST_ZIP"
    log "release: $DIST_ZIP (SHA-512 matches ${DIST_SHA512:+DIST_SHA512}${DIST_SHA512:-$DIST_ZIP.sha512})"
    DIST_SHA512=$want
  else
    log "computing SHA-512 of $DIST_ZIP (no DIST_SHA512 / .sha512 given: trusting the operator's own check)"
    sum=$(sha512sum "$DIST_ZIP"); DIST_SHA512=${sum%% *}
    log "release: $DIST_ZIP sha512=${DIST_SHA512:0:16}... (nodes re-check it after the copy)"
  fi
}

push_zip() { # push_zip NODE -> copy DIST_ZIP into the node's STAGE_DIR unless an identical file is already there
  local node=$1 dir=${STAGE_DIR:-$NIFI_BASE/.staging} dst
  dst="$dir/nifi-$NEW_VERSION-bin.zip"
  if [ "$node" = local ]; then
    mkdir -p "$dir"
    [ "$(sha512sum "$dst" 2>/dev/null | cut -d' ' -f1)" = "$DIST_SHA512" ] && { echo "release zip already in $dir"; return 0; }
    cp "$DIST_ZIP" "$dst.part" && mv "$dst.part" "$dst"
  else
    ssh $SSH_OPTS "$SSH_USER@$node" "sudo mkdir -p $dir && sudo chown $SSH_USER $dir"
    [ "$(ssh $SSH_OPTS "$SSH_USER@$node" "sha512sum $dst 2>/dev/null" | cut -d' ' -f1)" = "$DIST_SHA512" ] \
      && { echo "release zip already in $dir"; return 0; }
    echo "copying $(du -h "$DIST_ZIP" | cut -f1) release zip to $node:$dir"
    scp $SSH_OPTS -q "$DIST_ZIP" "$SSH_USER@$node:$dst.part" && ssh $SSH_OPTS "$SSH_USER@$node" "mv $dst.part $dst"
  fi
}

on_node() { # on_node NODE SUBCOMMAND  -> runs the agent on that node, output to RUN_DIR/NODE.log
  local node=$1 sub=$2 env; env=$(agent_env)
  if [ -n "${DIST_ZIP:-}" ] && [ "$sub" = stage ]; then push_zip "$node" || return 1; fi
  if [ "$node" = local ]; then
    eval "env $env bash \"\$HERE/lib/nifi-node.sh\" \"\$sub\""
  else
    scp $SSH_OPTS -q "$HERE/lib/nifi-node.sh" "$SSH_USER@$node:$REMOTE_AGENT"
    ssh $SSH_OPTS "$SSH_USER@$node" "sudo env $env bash $REMOTE_AGENT $sub"
  fi
}

all_nodes() { # all_nodes SUBCOMMAND -> run on every node in parallel, fail if any node fails
  local sub=$1 pids=() rc=0 node i=0
  for node in "${NODE_LIST[@]}"; do
    ( on_node "$node" "$sub" > "$RUN_DIR/$node.$sub.log" 2>&1 ) & pids+=($!)
  done
  for node in "${NODE_LIST[@]}"; do
    if wait "${pids[$i]}"; then log "  [$node] $sub ok"; else log "  [$node] $sub FAILED (see $RUN_DIR/$node.$sub.log)"; rc=1; fi
    sed 's/^/      /' "$RUN_DIR/$node.$sub.log" | tail -n "${LOG_TAIL:-12}" | tee -a "$RUN_DIR/upgrade.log" >/dev/null
    i=$((i + 1))
  done
  return $rc
}

step_preflight() {
  log "== PREFLIGHT ($OLD_VERSION -> $NEW_VERSION) on ${#NODE_LIST[@]} node(s): $NODES"
  command -v python3 >/dev/null || die "python3 needed on admin host"
  resolve_dist
  all_nodes preflight || die "preflight failed on at least one node"
  api record "$RUN_DIR/preflight-inventory.json" || die "cannot read cluster inventory through the API"
  python3 - "$RUN_DIR/preflight-inventory.json" "${#NODE_LIST[@]}" <<'EOF' || die "cluster not healthy"
import json, sys
inv, n = json.load(open(sys.argv[1])), int(sys.argv[2])
assert inv['version'] == __import__('os').environ.get('OLD_VERSION', inv['version']), 'cluster runs %s' % inv['version']
if inv['nodes'] is not None:
    bad = [x for x in inv['nodes'] if x['status'] != 'CONNECTED']
    assert not bad and len(inv['nodes']) == n, 'nodes not all connected: %s' % inv['nodes']
assert not inv['ghosts'], 'ghost components already present: %s' % inv['ghosts']
print('cluster healthy: %s, %s, %d invalid processor(s) before upgrade' % (inv['version'], 'standalone' if inv['nodes'] is None else '%d nodes connected' % len(inv['nodes']), len(inv['invalid'])))
EOF
  log "PREFLIGHT PASSED"
}

step_stage() {
  log "== STAGE $NEW_VERSION (no downtime)"
  [ "${DIST_RESOLVED:-}" = yes ] || resolve_dist
  all_nodes stage || die "stage failed"
  log "review the per-node reports: $NIFI_BASE/upgrade-report-$OLD_VERSION-to-$NEW_VERSION.txt (REVIEW lines need a human)"
}

step_upgrade() {
  log "== UPGRADE (downtime starts)"
  confirm "This stops ALL NiFi nodes ($NODES). Proceed?"
  api record "$RUN_DIR/pre-upgrade.json" || die "record failed"
  api quiesce || die "quiesce failed"
  api record "$RUN_DIR/pre-stop.json" || die "record after quiesce failed"
  # keep the run-state from BEFORE quiesce; queue totals/versioning from AFTER quiesce (what must survive the restart)
  python3 - "$RUN_DIR" <<'EOF'
import json, sys
d = sys.argv[1]
a, b = json.load(open(d + '/pre-upgrade.json')), json.load(open(d + '/pre-stop.json'))
for k in ('running_processors', 'running_ports', 'sources', 'enabled_services', 'running_reporting_tasks'):
    b[k] = a[k]
json.dump(b, open(d + '/baseline.json', 'w'), indent=1)
EOF
  all_nodes stop || die "stop failed - cluster partially down, investigate"
  if [ -n "${ZK_BACKUP_CMD:-}" ]; then  # cluster-scoped component state lives in ZooKeeper, not in the node backups
    log "ZooKeeper backup: $ZK_BACKUP_CMD"
    bash -c "$ZK_BACKUP_CMD" >> "$RUN_DIR/zk-backup.log" 2>&1 || die "ZK backup failed - old version can be restarted with: systemctl start $SERVICE"
  fi
  all_nodes backup || die "backup failed - old version can be restarted with: systemctl start $SERVICE"
  all_nodes patch-flow || die "patch-flow failed"
  all_nodes switch || die "switch failed"
  log "starting all nodes together (flow election)"
  all_nodes start || die "start failed - consider: $0 -c $CONF rollback"
  api wait-up "$( [ "${NODE_LIST[0]}" = local ] && echo '' || echo ${#NODE_LIST[@]})" || die "cluster did not come up - consider rollback"
  if api verify "$RUN_DIR/baseline.json"; then
    log "VERIFY PASSED - components are still stopped. Next: $0 -c $CONF resume"
  else
    die "VERIFY FAILED - nothing was resumed. Investigate, or: $0 -c $CONF rollback"
  fi
}

step_resume() {
  [ -f "$RUN_DIR/baseline.json" ] || die "no baseline in $RUN_DIR"
  log "== RESUME"
  api resume "$RUN_DIR/baseline.json" || die "some components did not start (see above)"
}

step_finalize() { log "== FINALIZE"; all_nodes finalize; all_nodes status; }

step_rollback() {
  log "== ROLLBACK to $OLD_VERSION"
  confirm "This stops ALL nodes and restores the pre-upgrade backup (data written by $NEW_VERSION is moved aside). Proceed?"
  all_nodes rollback || die "rollback failed on at least one node"
  api wait-up "$( [ "${NODE_LIST[0]}" = local ] && echo '' || echo ${#NODE_LIST[@]})" || die "old version did not come up"
  if [ -f "$RUN_DIR/baseline.json" ]; then
    # the backup was taken after quiesce (everything stopped): bring back exactly what ran before the upgrade
    api resume "$RUN_DIR/baseline.json" || log "WARN some components did not restart - check the UI"
  fi
  log "rolled back to $OLD_VERSION"
}

case "$CMD" in
  preflight) step_preflight ;;
  stage) step_stage ;;
  upgrade) step_upgrade ;;
  verify) api verify "$RUN_DIR/baseline.json" ;;
  resume) step_resume ;;
  finalize) step_finalize ;;
  rollback) step_rollback ;;
  status) all_nodes status ;;
  all) step_preflight; DIST_RESOLVED=yes; step_stage; step_upgrade; step_resume; step_finalize ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
log "done: $CMD (logs in $RUN_DIR)"
