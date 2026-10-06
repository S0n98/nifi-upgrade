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
# Options: -y  do not ask for confirmation before downtime steps
# NiFi 2.0.0-M4 and 2.12.0 nodes cannot be mixed in one cluster, so the upgrade stops ALL nodes together (no rolling upgrade).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="" ; YES=no
while getopts "c:y" o; do case $o in c) CONF=$OPTARG ;; y) YES=yes ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
CMD=${1:-}
[ -n "$CONF" ] && [ -f "$CONF" ] || { sed -n '2,15p' "$0"; exit 2; }
# shellcheck disable=SC1090
source "$CONF"

: "${NODES:?}" "${OLD_VERSION:?}" "${NEW_VERSION:?}" "${NIFI_API_URL:?}"
NIFI_BASE=${NIFI_BASE:-/data/nifi}; NIFI_LINK=${NIFI_LINK:-$NIFI_BASE/current}; SERVICE=${SERVICE:-nifi}
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

on_node() { # on_node NODE SUBCOMMAND  -> runs the agent on that node, output to RUN_DIR/NODE.log
  local node=$1 sub=$2 env; env=$(agent_env)
  if [ "$node" = local ]; then
    if [ -n "${DIST_ZIP:-}" ] && [ "$sub" = stage ]; then  # offline: use the zip the operator provided
      mkdir -p "${STAGE_DIR:-$NIFI_BASE/.staging}"
      cp "$DIST_ZIP" "${STAGE_DIR:-$NIFI_BASE/.staging}/nifi-$NEW_VERSION-bin.zip"
    fi
    eval "env $env bash \"\$HERE/lib/nifi-node.sh\" \"\$sub\""
  else
    scp $SSH_OPTS -q "$HERE/lib/nifi-node.sh" "$SSH_USER@$node:$REMOTE_AGENT"
    if [ -n "${DIST_ZIP:-}" ] && [ "$sub" = stage ]; then
      ssh $SSH_OPTS "$SSH_USER@$node" "sudo mkdir -p ${STAGE_DIR:-$NIFI_BASE/.staging} && sudo chown $SSH_USER ${STAGE_DIR:-$NIFI_BASE/.staging}"
      scp $SSH_OPTS -q "$DIST_ZIP" "$SSH_USER@$node:${STAGE_DIR:-$NIFI_BASE/.staging}/nifi-$NEW_VERSION-bin.zip"
    fi
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
  [ -n "${DIST_SHA512:-}" ] || die "DIST_SHA512 not set in $CONF"
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
  all) step_preflight; step_stage; step_upgrade; step_resume; step_finalize ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
log "done: $CMD (logs in $RUN_DIR)"
