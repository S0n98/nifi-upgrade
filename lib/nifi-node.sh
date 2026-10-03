#!/usr/bin/env bash
# nifi-node.sh - node-side agent for nifi-upgrade.sh. Runs ON a NiFi node (as root).
# Subcommands: preflight | stage | stop | backup | patch-flow | switch | start | finalize | rollback | status
# All settings come from environment variables exported by nifi-upgrade.sh (see nifi-upgrade.conf.example).
set -euo pipefail

: "${OLD_VERSION:?}" "${NEW_VERSION:?}" "${NIFI_BASE:?}" "${NIFI_LINK:?}" "${SERVICE:?}" "${BACKUP_DIR:?}"
OLD_HOME="$NIFI_BASE/nifi-$OLD_VERSION"
NEW_HOME="$NIFI_BASE/nifi-$NEW_VERSION"
NIFI_USER="${NIFI_USER:-nifi}"
STAGE_DIR="${STAGE_DIR:-$NIFI_BASE/.staging}"
MIN_FREE_GB="${MIN_FREE_GB:-3}"
HOST="$(hostname -s)"
REPORT="$NIFI_BASE/upgrade-report-$OLD_VERSION-to-$NEW_VERSION.txt"

log()  { printf '%s [%s] %s\n' "$(date +%FT%T)" "$HOST" "$*"; }
die()  { log "ERROR: $*"; exit 1; }
prop() { # prop FILE KEY -> value of KEY in a .properties file
  grep -E "^${2//./\\.}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
abspath() { # resolve a NiFi path (relative paths are relative to NIFI_HOME)
  case "$2" in /*) echo "$2" ;; *) echo "$1/${2#./}" ;; esac
}

# ---------------------------------------------------------------- data locations (from the OLD configuration)
data_paths() { # prints one absolute path per line: everything that holds state or data
  local h=$1 p=$1/conf/nifi.properties
  local flow; flow=$(abspath "$h" "$(prop "$p" nifi.flow.configuration.file)")
  echo "$(dirname "$flow")"
  abspath "$h" "$(prop "$p" nifi.database.directory)"
  abspath "$h" "$(prop "$p" nifi.flowfile.repository.directory)"
  grep -E '^nifi\.(content|provenance)\.repository\.directory\.' "$p" | cut -d= -f2- | while read -r d; do abspath "$h" "$d"; done
  local s; s=$(python3 - "$h/conf/state-management.xml" <<'EOF'
import re, sys
x = re.sub(r'<!--.*?-->', '', open(sys.argv[1]).read(), flags=re.S)
m = re.search(r'<id>local-provider</id>.*?<property name="Directory">([^<]*)</property>', x, re.S)
print(m.group(1) if m else '')
EOF
)
  [ -n "$s" ] && abspath "$h" "$s"
  local py; py=$(prop "$p" nifi.python.extensions.source.directory.default); [ -n "$py" ] && abspath "$h" "$py"
  python3 - "$h/conf/authorizers.xml" <<'EOF'
import re, sys
x = re.sub(r'<!--.*?-->', '', open(sys.argv[1]).read(), flags=re.S)
for k in ('Users File', 'Authorizations File'):
    for v in re.findall(r'<property name="%s">([^<]+)</property>' % k, x):
        print(v)
EOF
}

# ---------------------------------------------------------------- subcommands
cmd_preflight() {
  local rc=0 warn
  log "preflight: $OLD_VERSION -> $NEW_VERSION"
  [ "$(readlink -f "$NIFI_LINK")" = "$(readlink -f "$OLD_HOME")" ] || { log "FAIL $NIFI_LINK does not point to $OLD_HOME"; rc=1; }
  [ -f "$OLD_HOME/conf/nifi.properties" ] || { log "FAIL missing $OLD_HOME/conf/nifi.properties"; rc=1; }
  systemctl cat "$SERVICE" >/dev/null 2>&1 || { log "FAIL systemd unit $SERVICE not found"; rc=1; }
  local jv; jv=$(sudo -u "$NIFI_USER" bash -c 'java -version 2>&1' | awk -F'"' '/version/ {print $2}' | cut -d. -f1)
  [ "${jv:-0}" -ge 21 ] && log "ok   java $jv" || { log "FAIL java 21+ required (found '${jv:-none}')"; rc=1; }
  command -v python3 >/dev/null || { log "FAIL python3 required on node"; rc=1; }
  command -v unzip >/dev/null || { log "FAIL unzip required on node"; rc=1; }
  local free; free=$(df -BG --output=avail "$NIFI_BASE" | tail -1 | tr -dc 0-9)
  [ "$free" -ge "$MIN_FREE_GB" ] && log "ok   ${free}G free in $NIFI_BASE" || { log "FAIL only ${free}G free in $NIFI_BASE (need $MIN_FREE_GB)"; rc=1; }
  [ -n "$(prop "$OLD_HOME/conf/nifi.properties" nifi.sensitive.props.key)" ] && log "ok   sensitive props key set" \
    || { log "FAIL nifi.sensitive.props.key is empty - set and back it up first"; rc=1; }
  # every data location must live OUTSIDE the install dir, otherwise switching the symlink would orphan it
  while read -r d; do
    [ -z "$d" ] && continue
    case "$d" in "$OLD_HOME"/*) log "FAIL data path inside install dir: $d (externalize it first)"; rc=1 ;;
                 *) log "ok   data path $d" ;; esac
  done < <(data_paths "$OLD_HOME" | sort -u)
  # backup space estimate
  local need; need=$(du -scBG $(data_paths "$OLD_HOME" | sort -u | while read -r d; do [ -e "$d" ] && echo "$d"; done) 2>/dev/null | tail -1 | tr -dc 0-9)
  mkdir -p "$BACKUP_DIR"
  local bfree; bfree=$(df -BG --output=avail "$BACKUP_DIR" | tail -1 | tr -dc 0-9)
  [ "$bfree" -gt "${need:-0}" ] && log "ok   backup needs ~${need}G, ${bfree}G free in $BACKUP_DIR" \
    || { log "FAIL backup needs ~${need}G but only ${bfree}G free in $BACKUP_DIR"; rc=1; }
  # things that need a human decision
  warn=$(ls "$OLD_HOME/extensions" 2>/dev/null | grep -v -E '^(README|\.)' || true)
  [ -n "$warn" ] && log "WARN custom NARs in $OLD_HOME/extensions (rebuild for $NEW_VERSION; copied only if COPY_CUSTOM_NARS=yes): $warn"
  if zcat "$(abspath "$OLD_HOME" "$(prop "$OLD_HOME/conf/nifi.properties" nifi.flow.configuration.file)")" 2>/dev/null | grep -q '"type":"python\.'; then
    log "INFO flow contains Python processors typed 'python.<Name>' - patch-flow will rename them for $NEW_VERSION"
  fi
  [ "$(prop "$OLD_HOME/conf/nifi.properties" nifi.cluster.is.node)" = "true" ] && log "INFO clustered node, ZK: $(prop "$OLD_HOME/conf/nifi.properties" nifi.zookeeper.connect.string)"
  [ $rc -eq 0 ] && log "preflight PASSED" || log "preflight FAILED"
  return $rc
}

cmd_stage() {
  [ -e "$NEW_HOME" ] && [ "${FORCE_RESTAGE:-no}" != "yes" ] && die "$NEW_HOME exists (set FORCE_RESTAGE=yes to rebuild it)"
  rm -rf "$NEW_HOME"; mkdir -p "$STAGE_DIR"
  local zip="$STAGE_DIR/nifi-$NEW_VERSION-bin.zip"
  if [ ! -f "$zip" ]; then
    [ -n "${DIST_URL:-}" ] || die "no $zip and no DIST_URL"
    log "downloading $DIST_URL"
    curl -sSfL --retry 3 -o "$zip.part" "$DIST_URL" || { rm -f "$zip.part"; die "download failed: $DIST_URL"; }
    mv "$zip.part" "$zip"
  fi
  [ -n "${DIST_SHA512:-}" ] || die "DIST_SHA512 not set"
  echo "$DIST_SHA512  $zip" | sha512sum -c --quiet - || die "SHA-512 mismatch for $zip"
  log "SHA-512 verified"
  unzip -q "$zip" -d "$NIFI_BASE"
  [ -x "$NEW_HOME/bin/nifi.sh" ] || die "unpack failed"
  configure_new
  chown -R "$NIFI_USER:$NIFI_USER" "$NEW_HOME"
  [ "${KEEP_ZIP:-no}" = yes ] || rm -f "$zip"
  log "staged $NEW_HOME (report: $REPORT)"
}

configure_new() {
  # carry the site configuration from OLD to the freshly unpacked NEW tree; never copy nifi.properties wholesale
  python3 - "$OLD_HOME" "$NEW_HOME" "$REPORT" "${COPY_CUSTOM_NARS:-no}" <<'EOF'
import os, re, shutil, sys
old, new, report, copy_nars = sys.argv[1:5]
rep = []

def load(p):
    d = {}
    for l in open(p):
        if '=' in l and not l.lstrip().startswith('#'):
            k, v = l.rstrip('\n').split('=', 1); d[k.strip()] = v
    return d

# 1. nifi.properties: keep the NEW file's layout, take OLD values for keys present in both
op, np_ = load(old + '/conf/nifi.properties'), load(new + '/conf/nifi.properties')
lines, changed = [], []
for l in open(new + '/conf/nifi.properties'):
    m = re.match(r'^([^#=\s][^=]*)=(.*)$', l.rstrip('\n'))
    if m and m.group(1) in op and op[m.group(1)] != m.group(2):
        k = m.group(1); l = '%s=%s\n' % (k, op[k]); changed.append(k)
    lines.append(l)
# keys the NEW file only ships commented-out (e.g. '#nifi.python.command=') but the OLD config sets
for i, l in enumerate(lines):
    m = re.match(r'^#\s*([a-z][a-zA-Z0-9._-]*)=(.*)$', l.rstrip('\n'))
    if m and m.group(1) in op and m.group(1) not in np_ and op[m.group(1)] != '':
        k = m.group(1); lines[i] = '%s=%s\n' % (k, op[k]); changed.append(k); np_[k] = op[k]
open(new + '/conf/nifi.properties', 'w').write(''.join(lines))
secret = re.compile(r'(passw|secret|props\.key|token)', re.I)
rep.append('nifi.properties: carried %d value(s) from %s:' % (len(changed), os.path.basename(old)))
rep += ['  %s=%s' % (k, '<hidden>' if secret.search(k) else op[k]) for k in changed]
only_old = sorted(k for k in op if k not in np_ and op[k] != '')
rep.append('REVIEW keys set in old version but REMOVED in new version (not carried): %s' % (only_old or 'none'))
rep.append('INFO keys new in this version (defaults kept): %s' % (sorted(k for k in np_ if k not in op) or 'none'))

# 2. bootstrap.conf: carry java.arg.N / run.as / other key values
ob, nb = load(old + '/conf/bootstrap.conf'), load(new + '/conf/bootstrap.conf')
out = []
for l in open(new + '/conf/bootstrap.conf'):
    m = re.match(r'^([^#=\s][^=]*)=(.*)$', l.rstrip('\n'))
    if m and m.group(1) in ob and ob[m.group(1)] != m.group(2):
        rep.append('bootstrap.conf: %s=%s (was default %s)' % (m.group(1), ob[m.group(1)], m.group(2)))
        l = '%s=%s\n' % (m.group(1), ob[m.group(1)])
    out.append(l)
extra = [k for k in ob if k not in nb]
if extra:
    rep.append('REVIEW bootstrap.conf keys from old version that the new one no longer has (not carried): %s'
               % ['%s=%s' % (k, ob[k]) for k in extra])
open(new + '/conf/bootstrap.conf', 'w').write(''.join(out))

# 3. XML provider configs are copied as-is (format is stable across 2.x); logback is only diffed
for f in ('authorizers.xml', 'login-identity-providers.xml', 'state-management.xml', 'zookeeper.properties'):
    if os.path.exists(old + '/conf/' + f):
        shutil.copy2(old + '/conf/' + f, new + '/conf/' + f); rep.append('copied conf/%s' % f)
if open(old + '/conf/logback.xml').read() != open(new + '/conf/logback.xml').read():
    rep.append('REVIEW conf/logback.xml differs from the new default - re-apply custom logging by hand if any')

# 4. everything in old conf/ that the distribution does not ship (keystores, users.xml, flow.json.gz, archive/ ...)
shipped = set(os.listdir(new + '/conf'))
for f in os.listdir(old + '/conf'):
    if f in shipped:
        continue
    s, d = old + '/conf/' + f, new + '/conf/' + f
    (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, d)
    rep.append('copied non-distribution conf/%s' % f)

# 5. custom NARs
custom = [f for f in os.listdir(old + '/extensions') if f.endswith('.nar')] if os.path.isdir(old + '/extensions') else []
if custom and copy_nars == 'yes':
    for f in custom:
        shutil.copy2(old + '/extensions/' + f, new + '/extensions/' + f)
    rep.append('copied custom NARs (verify compatibility!): %s' % custom)
elif custom:
    rep.append('REVIEW custom NARs NOT copied: %s' % custom)
open(report, 'w').write('\n'.join(rep) + '\n')
print('\n'.join(rep))
EOF
}

cmd_stop() {
  log "stopping $SERVICE"
  systemctl stop "$SERVICE"
  for _ in $(seq 1 120); do
    pgrep -u "$NIFI_USER" -f 'org.apache.nifi.(NiFi|runtime.Application|bootstrap.RunNiFi)' >/dev/null || { log "$SERVICE stopped cleanly"; return 0; }
    sleep 2
  done
  die "NiFi processes still running after stop - investigate, do NOT kill -9"
}

cmd_backup() {
  systemctl is-active --quiet "$SERVICE" && die "$SERVICE is running - stop it before backup"
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local f="$BACKUP_DIR/nifi-$HOST-$OLD_VERSION-$ts.tar"
  local paths; paths=$( { data_paths "$OLD_HOME"; echo "$OLD_HOME/conf"; systemctl show -p FragmentPath --value "$SERVICE"; echo "${BACKUP_EXTRA_PATHS:-}" | tr ' ' '\n'; } \
                        | sort -u | while read -r p; do [ -n "$p" ] && [ -e "$p" ] && echo "${p#/}"; done)
  log "backing up: $(echo $paths)"
  case "${BACKUP_COMPRESS:-gzip}" in
    gzip) f="$f.gz"; tar -czf "$f" -C / $paths ;;
    zstd) f="$f.zst"; tar --zstd -cf "$f" -C / $paths ;;
    none) tar -cf "$f" -C / $paths ;;
  esac
  sha256sum "$f" > "$f.sha256"; chmod 600 "$f"
  echo "$f" > "$BACKUP_DIR/LATEST-$OLD_VERSION"
  log "backup $f ($(du -h "$f" | cut -f1))"
}

cmd_patch_flow() {
  local flow; flow=$(abspath "$NEW_HOME" "$(prop "$NEW_HOME/conf/nifi.properties" nifi.flow.configuration.file)")
  systemctl is-active --quiet "$SERVICE" && die "$SERVICE is running - patch only while stopped"
  [ -f "$flow" ] || { log "no flow file at $flow - nothing to patch"; return 0; }
  cp -p "$flow" "$flow.pre-$NEW_VERSION"
  python3 - "$flow" <<'EOF'
import gzip, re, sys
f = sys.argv[1]
txt = gzip.open(f, 'rt').read()
# 2.0.0-M* stored Python processors as "python.<Name>"; 2.x GA registers them as "<Name>"
new, n = re.subn(r'("type"\s*:\s*")python\.([A-Za-z0-9_]+")', r'\1\2', txt)
if n:
    with gzip.open(f, 'wt') as o:
        o.write(new)
print('patch-flow: renamed %d python processor type(s)' % n)
EOF
  chown "$NIFI_USER:$NIFI_USER" "$flow"
}

set_prop() { # set_prop FILE KEY VALUE (literal)
  python3 - "$@" <<'EOF'
import re, sys
p, k, v = sys.argv[1:4]
s = open(p).read()
s, n = re.subn(r'(?m)^' + re.escape(k) + '=.*$', lambda m: k + '=' + v, s)
if not n:
    s += '\n%s=%s\n' % (k, v)
open(p, 'w').write(s)
EOF
}

cmd_switch() {
  [ -x "$NEW_HOME/bin/nifi.sh" ] || die "$NEW_HOME not staged"
  systemctl is-active --quiet "$SERVICE" && die "$SERVICE is running"
  # first start of the new version comes up with every component stopped; nifi-upgrade.sh resumes them after verification
  set_prop "$NEW_HOME/conf/nifi.properties" nifi.flowcontroller.autoResumeState false
  ln -sfn "$NEW_HOME" "$NIFI_LINK"
  systemctl daemon-reload
  log "$NIFI_LINK -> $(readlink "$NIFI_LINK") (autoResumeState=false for first start)"
}

cmd_start() {
  systemctl start "$SERVICE"
  log "$SERVICE started ($(readlink "$NIFI_LINK"))"
}

cmd_finalize() {
  set_prop "$(readlink -f "$NIFI_LINK")/conf/nifi.properties" nifi.flowcontroller.autoResumeState "$(prop "$OLD_HOME/conf/nifi.properties" nifi.flowcontroller.autoResumeState || echo true)"
  log "autoResumeState restored to $(prop "$(readlink -f "$NIFI_LINK")/conf/nifi.properties" nifi.flowcontroller.autoResumeState) (effective on next restart, no restart needed)"
}

cmd_rollback() {
  local f; f=${ROLLBACK_BACKUP:-$(cat "$BACKUP_DIR/LATEST-$OLD_VERSION" 2>/dev/null || true)}
  [ -f "$f" ] || die "no backup found (set ROLLBACK_BACKUP)"
  (cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f").sha256") || die "backup checksum mismatch: $f"
  systemctl is-active --quiet "$SERVICE" && cmd_stop
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  # move the data the new version touched aside (kept for forensics), then restore the backup exactly
  data_paths "$OLD_HOME" | sort -u | while read -r d; do
    [ -e "$d" ] && mv "$d" "$d.failed-$NEW_VERSION-$ts" && log "moved aside $d"
  done
  case "$f" in *.gz) tar -xzf "$f" -C / ;; *.zst) tar --zstd -xf "$f" -C / ;; *) tar -xf "$f" -C / ;; esac
  ln -sfn "$OLD_HOME" "$NIFI_LINK"; systemctl daemon-reload
  log "restored $f, $NIFI_LINK -> $OLD_HOME"
  [ "${ROLLBACK_START:-yes}" = yes ] && cmd_start
}

cmd_status() {
  log "link=$(readlink "$NIFI_LINK") service=$(systemctl is-active "$SERVICE" || true) autoResume=$(prop "$(readlink -f "$NIFI_LINK")/conf/nifi.properties" nifi.flowcontroller.autoResumeState)"
}

case "${1:-}" in
  preflight) cmd_preflight ;; stage) cmd_stage ;; stop) cmd_stop ;; backup) cmd_backup ;;
  patch-flow) cmd_patch_flow ;; switch) cmd_switch ;; start) cmd_start ;; finalize) cmd_finalize ;;
  rollback) cmd_rollback ;; status) cmd_status ;;
  *) echo "usage: $0 preflight|stage|stop|backup|patch-flow|switch|start|finalize|rollback|status"; exit 2 ;;
esac
