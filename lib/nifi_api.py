#!/usr/bin/env python3
"""Cluster-level NiFi REST helper for nifi-upgrade.sh (stdlib only).

  nifi_api.py record  OUT.json      capture running components, queue totals, validity, versioning, nodes
  nifi_api.py quiesce               stop source processors, wait for queues to drain/settle, stop the root group
  nifi_api.py wait-up [NODES]       wait until the API answers and (if clustered) NODES nodes are CONNECTED
  nifi_api.py verify  PRE.json      compare the freshly started new version against PRE (no components running yet)
  nifi_api.py resume  PRE.json      re-enable services / restart exactly the components that were running in PRE

Auth (first match wins): NIFI_TOKEN, NIFI_TOKEN_CMD (prints a bearer token), NIFI_CLIENT_CERT + NIFI_CLIENT_KEY (mTLS).
TLS: NIFI_CA_CERT (PEM bundle to trust); NIFI_INSECURE=1 disables verification (lab only).
"""
import json, os, ssl, subprocess, sys, time, urllib.error, urllib.request

API = os.environ['NIFI_API_URL'].rstrip('/')
_tok = None


def ctx():
    c = ssl.create_default_context(cafile=os.environ.get('NIFI_CA_CERT') or None)
    if os.environ.get('NIFI_INSECURE') == '1':
        c.check_hostname, c.verify_mode = False, ssl.CERT_NONE
    if os.environ.get('NIFI_CLIENT_CERT'):
        c.load_cert_chain(os.environ['NIFI_CLIENT_CERT'], os.environ.get('NIFI_CLIENT_KEY'))
    return c


CTX = ctx()


def token(refresh=False):
    global _tok
    if os.environ.get('NIFI_TOKEN') and not refresh:
        return os.environ['NIFI_TOKEN']
    if os.environ.get('NIFI_TOKEN_CMD') and (refresh or _tok is None):
        _tok = subprocess.run(os.environ['NIFI_TOKEN_CMD'], shell=True, capture_output=True, text=True, check=True).stdout.strip()
    return _tok


class HTTPFail(RuntimeError):
    def __init__(self, code, msg):
        super().__init__(msg); self.code = code


def call(method, path, body=None, retry=True):
    h = {'Content-Type': 'application/json'} if body is not None else {}
    t = token()
    if t:
        h['Authorization'] = 'Bearer ' + t
    req = urllib.request.Request(API + path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=120) as r:
            s = r.read().decode()
            return json.loads(s) if s.strip().startswith(('{', '[')) else s
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry and os.environ.get('NIFI_TOKEN_CMD'):
            token(refresh=True)
            return call(method, path, body, retry=False)
        raise HTTPFail(e.code, '%s %s -> %s %s' % (method, path, e.code, e.read().decode()[:500]))


def log(*a):
    print(time.strftime('%FT%T'), *a, flush=True)


# ---------------------------------------------------------------- inventory
def walk(pg='root'):
    """Yield (group_id, flow) for the root group and every descendant group."""
    f = call('GET', '/flow/process-groups/%s' % pg)['processGroupFlow']
    yield f['id'], f['flow']
    for child in f['flow']['processGroups']:
        yield from walk(child['id'])


def cluster_nodes():
    try:
        return [{'address': n['address'], 'status': n['status']} for n in call('GET', '/controller/cluster')['cluster']['nodes']]
    except HTTPFail as e:
        if e.code in (404, 409):  # standalone instance ("Only a node connected to a cluster...")
            return None
        raise


def inventory():
    inv = {'version': call('GET', '/flow/about')['about']['version'], 'nodes': cluster_nodes(),
           'running_processors': [], 'running_ports': [], 'processors': 0, 'invalid': [], 'ghosts': [], 'versioned': {},
           'sources': []}
    for gid, flow in walk():
        for p in flow['processors']:
            c = p.get('component') or {}
            inv['processors'] += 1
            if c.get('state') == 'RUNNING':
                inv['running_processors'].append(p['id'])
                if c.get('inputRequirement') == 'INPUT_FORBIDDEN':
                    inv['sources'].append(p['id'])
            if c.get('validationStatus') == 'INVALID':
                inv['invalid'].append('%s (%s)' % (c.get('name'), p['id']))
            if c.get('extensionMissing'):
                inv['ghosts'].append('%s %s (%s)' % (c.get('type'), c.get('name'), p['id']))
        for kind in ('inputPorts', 'outputPorts'):
            for p in flow[kind]:
                if (p.get('component') or {}).get('state') == 'RUNNING':
                    inv['running_ports'].append([kind, p['id']])
        for g in flow['processGroups']:
            v = (g.get('component') or {}).get('versionControlInformation')
            if v:
                inv['versioned'][g['id']] = {'flowId': v['flowId'], 'version': str(v['version']), 'state': v['state']}
    svcs = call('GET', '/flow/process-groups/root/controller-services?includeAncestorGroups=false&includeDescendantGroups=true')['controllerServices']
    svcs += call('GET', '/flow/controller/controller-services')['controllerServices']
    inv['enabled_services'] = sorted({s['id'] for s in svcs if s['component']['state'] in ('ENABLED', 'ENABLING')})
    inv['running_reporting_tasks'] = [t['id'] for t in call('GET', '/flow/reporting-tasks')['reportingTasks'] if t['component']['state'] == 'RUNNING']
    inv['registry_clients'] = sorted(r['component']['name'] for r in call('GET', '/flow/registries')['registries'])
    st = call('GET', '/flow/process-groups/root/status')['processGroupStatus']['aggregateSnapshot']
    inv['queued_count'], inv['queued_bytes'] = st['flowFilesQueued'], st['bytesQueued']
    inv['parameter_contexts'] = sorted(c['component']['name'] for c in call('GET', '/flow/parameter-contexts')['parameterContexts'])
    inv['users'] = sorted(u['component']['identity'] for u in call('GET', '/tenants/users')['users'])
    return inv


def cmd_record(out):
    inv = inventory()
    json.dump(inv, open(out, 'w'), indent=1)
    log('recorded %s: NiFi %s, nodes=%s, processors=%d (running %d, sources %d), invalid=%d, services enabled=%d, '
        'versioned PGs=%d, queued=%d FlowFiles / %d bytes' % (out, inv['version'], len(inv['nodes']) if inv['nodes'] else 'standalone',
        inv['processors'], len(inv['running_processors']), len(inv['sources']), len(inv['invalid']), len(inv['enabled_services']),
        len(inv['versioned']), inv['queued_count'], inv['queued_bytes']))


# ---------------------------------------------------------------- run state
def set_proc(pid, state):
    p = call('GET', '/processors/' + pid)
    if p['component']['state'] != state:
        call('PUT', '/processors/%s/run-status' % pid, {'revision': p['revision'], 'state': state, 'disconnectedNodeAcknowledged': False})


def cmd_quiesce():
    inv = inventory()
    log('stopping %d source processors' % len(inv['sources']))
    for pid in inv['sources']:
        set_proc(pid, 'STOPPED')
    timeout, settle = int(os.environ.get('DRAIN_TIMEOUT', '900')), int(os.environ.get('DRAIN_SETTLE_POLLS', '6'))
    t0, last, same = time.time(), None, 0
    while time.time() - t0 < timeout:
        q = call('GET', '/flow/process-groups/root/status')['processGroupStatus']['aggregateSnapshot']['flowFilesQueued']
        same = same + 1 if q == last else 0
        last = q
        if q == 0 or same >= settle:
            break
        time.sleep(10)
    log('queues settled at %s FlowFiles (data that cannot drain stays in the repositories and is preserved)' % last)
    rid = call('GET', '/flow/process-groups/root')['processGroupFlow']['id']
    call('PUT', '/flow/process-groups/' + rid, {'id': rid, 'state': 'STOPPED'})
    for _ in range(60):
        if not inventory()['running_processors']:
            break
        time.sleep(5)
    log('all processors stopped')


def cmd_wait_up(expected):
    t0 = time.time()
    while time.time() - t0 < int(os.environ.get('START_TIMEOUT', '1200')):
        try:
            call('GET', '/flow/about')
            nodes = cluster_nodes()
            if nodes is None:
                log('API up (standalone)'); return
            conn = [n for n in nodes if n['status'] == 'CONNECTED']
            log('cluster: %d/%s nodes connected' % (len(conn), expected))
            if expected and len(conn) >= int(expected):
                return
        except Exception as e:
            log('waiting for API: %s' % str(e)[:120])
        time.sleep(15)
    sys.exit('timed out waiting for NiFi')


def cmd_verify(pre_path):
    pre = json.load(open(pre_path))
    pending = enable_services(pre)  # services move no data; processors stay stopped until 'resume'
    time.sleep(5)
    post = inventory()
    json.dump(post, open(pre_path.replace('.json', '') + '.post.json', 'w'), indent=1)
    bad = []

    def chk(ok, msg):
        log('%s %s' % ('PASS' if ok else 'FAIL', msg))
        ok or bad.append(msg)

    chk(post['version'] != pre['version'], 'version %s -> %s' % (pre['version'], post['version']))
    chk(not pending, '%d controller services enabled on new version %s' % (len(pre['enabled_services']), pending[:5] or ''))
    if pre['nodes']:
        chk(len([n for n in post['nodes'] or [] if n['status'] == 'CONNECTED']) == len(pre['nodes']), 'all %d nodes connected' % len(pre['nodes']))
    chk((post['queued_count'], post['queued_bytes']) == (pre['queued_count'], pre['queued_bytes']),
        'queued data preserved: %s/%sB -> %s/%sB' % (pre['queued_count'], pre['queued_bytes'], post['queued_count'], post['queued_bytes']))
    chk(post['processors'] == pre['processors'], 'processor count %d -> %d' % (pre['processors'], post['processors']))
    chk(not post['ghosts'], 'no ghost components %s' % (post['ghosts'][:5] or ''))
    new_invalid = sorted(set(post['invalid']) - set(pre['invalid']))
    chk(not new_invalid, 'no newly invalid processors %s' % (new_invalid[:5] or ''))
    chk(post['registry_clients'] == pre['registry_clients'], 'registry clients %s' % post['registry_clients'])
    chk(post['parameter_contexts'] == pre['parameter_contexts'], '%d parameter contexts' % len(pre['parameter_contexts']))
    chk(post['users'] == pre['users'], '%d users' % len(pre['users']))
    vdiff = [g for g, v in pre['versioned'].items() if post['versioned'].get(g) != v]
    chk(not vdiff, 'version control of %d PGs unchanged %s' % (len(pre['versioned']), vdiff[:5] or ''))
    if bad:
        log('VERIFY FAILED (%d) - do not resume; investigate or roll back' % len(bad)); sys.exit(1)
    log('VERIFY PASSED')


def enable_services(pre):
    """Enable the controller services that were enabled before the upgrade (autoResumeState=false leaves them disabled)."""
    for sid in pre['enabled_services']:
        s = call('GET', '/controller-services/' + sid)
        if s['component']['state'] not in ('ENABLED', 'ENABLING'):
            call('PUT', '/controller-services/%s/run-status' % sid, {'revision': s['revision'], 'state': 'ENABLED'})
    for _ in range(60):
        pending = [sid for sid in pre['enabled_services'] if call('GET', '/controller-services/' + sid)['component']['state'] != 'ENABLED']
        if not pending:
            break
        time.sleep(5)
    log('controller services enabled: %d (pending %d)' % (len(pre['enabled_services']), len(pending)))
    return pending


def cmd_resume(pre_path):
    pre = json.load(open(pre_path))
    enable_services(pre)
    for tid in pre['running_reporting_tasks']:
        t = call('GET', '/reporting-tasks/' + tid)
        call('PUT', '/reporting-tasks/%s/run-status' % tid, {'revision': t['revision'], 'state': 'RUNNING'})
    # start everything that was running EXCEPT sources first, then the sources
    others = [p for p in pre['running_processors'] if p not in pre['sources']]
    for pid in others + pre['sources']:
        set_proc(pid, 'RUNNING')
    for kind, pid in pre['running_ports']:
        path = '/input-ports/' if kind == 'inputPorts' else '/output-ports/'
        p = call('GET', path + pid)
        call('PUT', path + pid + '/run-status', {'revision': p['revision'], 'state': 'RUNNING'})
    now = inventory()
    missing = sorted(set(pre['running_processors']) - set(now['running_processors']))
    log('resumed %d processors, %d ports, %d reporting tasks; not running: %s' % (
        len(pre['running_processors']), len(pre['running_ports']), len(pre['running_reporting_tasks']), missing or 'none'))
    sys.exit(1 if missing else 0)


if __name__ == '__main__':
    c = sys.argv[1] if len(sys.argv) > 1 else ''
    if c == 'record': cmd_record(sys.argv[2])
    elif c == 'quiesce': cmd_quiesce()
    elif c == 'wait-up': cmd_wait_up(sys.argv[2] if len(sys.argv) > 2 else None)
    elif c == 'verify': cmd_verify(sys.argv[2])
    elif c == 'resume': cmd_resume(sys.argv[2])
    else: sys.exit(__doc__)
