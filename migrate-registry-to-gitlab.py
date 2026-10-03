#!/usr/bin/env python3
"""Move every process group versioned in a NiFi Registry client to a GitLab Flow Registry Client, keeping full history.

For each versioned process group (PG) tracked by --source-client:
  1. every Registry version v1..vN is imported into a temporary PG, detached, and committed to the GitLab flow
     <bucket>/<flow>.json (v1 creates the flow) - so each Registry version becomes one git commit written by NiFi itself;
     the commit message keeps the original comment, author and timestamp
  2. the live PG is detached from the Registry and attached to the GitLab flow with a final "cutover" commit
PGs that are LOCALLY_MODIFIED / STALE / SYNC_FAILURE are skipped unless you decide otherwise (see options).

usage: migrate-registry-to-gitlab.py --source-client NAME --target-client NAME [--gitlab-url URL --gitlab-project PATH
         --gitlab-token-file FILE] [--only PG_NAME ...] [--commit-local-changes] [--dry-run] [--report FILE]
Auth/TLS for NiFi: same environment variables as lib/nifi_api.py (NIFI_API_URL, NIFI_TOKEN / NIFI_TOKEN_CMD / client cert, NIFI_CA_CERT).
"""
import argparse, json, os, ssl, sys, time, urllib.parse, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
import nifi_api as A  # noqa: E402

MARK = '[migrated from NiFi Registry v%s]'


def client(name):
    for c in A.call('GET', '/flow/registries')['registries']:
        if c['component']['name'] == name:
            return c['id']
    sys.exit('registry client %r not found' % name)


def versioned_pgs(source_id):
    out = []
    for gid, flow in A.walk():
        for g in flow['processGroups']:
            v = (g.get('component') or {}).get('versionControlInformation')
            if v and v['registryId'] == source_id:
                out.append((g['id'], gid, g['component']['name'], v))
    return out


def pg(pid):
    return A.call('GET', '/process-groups/' + pid)


def stop_vc(pid):
    e = pg(pid)
    if e['component'].get('versionControlInformation'):
        A.call('DELETE', '/versions/process-groups/%s?version=%d' % (pid, e['revision']['version']))


def start_vc(pid, target_id, bucket, flow_name, flow_id, comment, description=''):
    e = pg(pid)
    vf = {'registryId': target_id, 'bucketId': bucket, 'flowName': flow_name, 'description': description,
          'comments': comment, 'action': 'COMMIT'}
    if flow_id:
        vf['flowId'] = flow_id
    return A.call('POST', '/versions/process-groups/' + pid, {'processGroupRevision': e['revision'], 'versionedFlow': vf})['versionControlInformation']


def target_versions(target_id, bucket, flow_id):
    try:
        s = A.call('GET', '/flow/registries/%s/buckets/%s/flows/%s/versions' % (target_id, bucket, flow_id))['versionedFlowSnapshotMetadataSet']
    except A.HTTPFail:
        return []
    return [x['versionedFlowSnapshotMetadata'] for x in s]


def ensure_bucket(target_id, bucket, args):
    names = [b['bucket']['name'] for b in A.call('GET', '/flow/registries/%s/buckets' % target_id)['buckets']]
    if bucket in names:
        return
    if not (args.gitlab_url and args.gitlab_project and args.gitlab_token_file):
        sys.exit('bucket directory %r does not exist in the repository; create it or pass --gitlab-url/--gitlab-project/--gitlab-token-file' % bucket)
    tok = open(args.gitlab_token_file).read().strip().split('=', 1)[-1]
    ctx = ssl.create_default_context(cafile=os.environ.get('GITLAB_CA_CERT') or os.environ.get('NIFI_CA_CERT') or None)
    body = {'branch': args.branch, 'commit_message': 'Create bucket %s for flows migrated from NiFi Registry' % bucket,
            'actions': [{'action': 'create', 'file_path': '%s/README.md' % bucket, 'content': 'NiFi bucket %s (migrated from NiFi Registry)\n' % bucket}]}
    url = '%s/api/v4/projects/%s/repository/commits' % (args.gitlab_url.rstrip('/'), urllib.parse.quote(args.gitlab_project, safe=''))
    urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(), method='POST',
                           headers={'PRIVATE-TOKEN': tok, 'Content-Type': 'application/json'}), context=ctx)
    A.log('created bucket directory %s in %s' % (bucket, args.gitlab_project))
    for _ in range(30):
        if bucket in [b['bucket']['name'] for b in A.call('GET', '/flow/registries/%s/buckets' % target_id)['buckets']]:
            return
        time.sleep(2)
    sys.exit('bucket %s not visible to the target client' % bucket)


def migrate_one(pid, parent, name, v, src, tgt, root, args, report):
    hist = sorted(A.call('GET', '/flow/registries/%s/buckets/%s/flows/%s/versions' % (src, v['bucketId'], v['flowId']))['versionedFlowSnapshotMetadataSet'],
                  key=lambda x: int(x['versionedFlowSnapshotMetadata']['version']))
    hist = [h['versionedFlowSnapshotMetadata'] for h in hist]
    bucket, flow_name = v['bucketName'], v['flowName']
    rec = {'pg': pid, 'name': name, 'registry': {'bucket': bucket, 'flowId': v['flowId'], 'version': str(v['version']), 'state': v['state'],
           'history': [h['version'] for h in hist]}, 'git': {}}
    report.append(rec)
    if v['state'] not in ('UP_TO_DATE',) and not (v['state'] == 'LOCALLY_MODIFIED' and args.commit_local_changes):
        rec['skipped'] = 'state %s - commit/revert local changes or update to latest first (or --commit-local-changes)' % v['state']
        A.log('SKIP %-28s %s' % (name, rec['skipped'])); return False
    if str(v['version']) != str(hist[-1]['version']):
        rec['skipped'] = 'PG at v%s but latest is v%s' % (v['version'], hist[-1]['version'])
        A.log('SKIP %-28s %s' % (name, rec['skipped'])); return False
    if args.dry_run:
        A.log('DRY  %-28s %d version(s) -> %s/%s.json' % (name, len(hist), bucket, flow_name)); return True
    ensure_bucket(tgt, bucket, args)
    existing = target_versions(tgt, bucket, flow_name)
    done = {}
    for m in existing:  # resume support: versions already replayed by a previous run
        c = m.get('comments') or ''
        for h in hist:
            if c.startswith(MARK % h['version']):
                done[str(h['version'])] = m['version']
    if existing and not done:
        rec['skipped'] = 'target flow %s/%s already exists and was not created by this tool' % (bucket, flow_name)
        A.log('SKIP %-28s %s' % (name, rec['skipped'])); return False
    flow_id = flow_name if existing else None
    for h in hist:
        ver = str(h['version'])
        if ver in done:
            rec['git'][ver] = done[ver]; continue
        tmp = A.call('POST', '/process-groups/%s/process-groups?parameterContextHandlingStrategy=KEEP_EXISTING' % root, {
            'revision': {'version': 0}, 'component': {'name': '_migrate_%s_v%s' % (name, ver), 'position': {'x': -5000, 'y': -5000},
                                                       'versionControlInformation': {'registryId': src, 'bucketId': v['bucketId'],
                                                                                     'flowId': v['flowId'], 'version': ver}}})['id']
        try:
            stop_vc(tmp)
            when = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(h['timestamp'] / 1000)) if h.get('timestamp') else '?'
            info = start_vc(tmp, tgt, bucket, flow_name, flow_id, '%s %s (author: %s, %s)' % (MARK % ver, h.get('comments') or '', h.get('author'), when),
                            v.get('flowDescription') or '')
            flow_id = info['flowId']
            rec['git'][ver] = info['version']
        finally:
            stop_vc(tmp)
            e = pg(tmp)
            A.call('DELETE', '/process-groups/%s?version=%d' % (tmp, e['revision']['version']))
    # cutover: the live PG now tracks the GitLab flow
    stop_vc(pid)
    info = start_vc(pid, tgt, bucket, flow_name, flow_id, '[migrated] cutover: live process group %s now tracks GitLab (was NiFi Registry v%s, %s)'
                    % (pid, v['version'], v['state']))
    rec['git']['cutover'] = info['version']
    for _ in range(30):
        st = pg(pid)['component']['versionControlInformation']['state']
        if st == 'UP_TO_DATE':
            break
        time.sleep(1)
    rec['final_state'] = st
    A.log('OK   %-28s registry v1..v%s -> %d git commits + cutover %s (%s)' % (name, v['version'], len(hist), info['version'][:8], st))
    return st == 'UP_TO_DATE'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--source-client', required=True); ap.add_argument('--target-client', required=True)
    ap.add_argument('--gitlab-url'); ap.add_argument('--gitlab-project'); ap.add_argument('--gitlab-token-file'); ap.add_argument('--branch', default='main')
    ap.add_argument('--only', nargs='*'); ap.add_argument('--commit-local-changes', action='store_true'); ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--report', default='registry-migration-report.json')
    args = ap.parse_args()
    src, tgt = client(args.source_client), client(args.target_client)
    root = A.call('GET', '/flow/process-groups/root')['processGroupFlow']['id']
    pgs = versioned_pgs(src)
    if args.only:
        pgs = [p for p in pgs if p[2] in args.only]
    nested = [p[2] for p in pgs if any(q[0] == p[1] for q in pgs)]
    if nested:
        sys.exit('nested versioned process groups are not handled by this tool: %s' % nested)
    A.log('%d process group(s) versioned in %s -> %s%s' % (len(pgs), args.source_client, args.target_client, ' (dry run)' if args.dry_run else ''))
    report, ok = [], 0
    for p in pgs:
        try:
            ok += bool(migrate_one(*p, src, tgt, root, args, report))
        except Exception as e:
            report.append({'pg': p[0], 'name': p[2], 'error': str(e)[:500]})
            A.log('FAIL %-28s %s' % (p[2], str(e)[:300]))
        json.dump(report, open(args.report, 'w'), indent=1)
    A.log('migrated %d/%d (report: %s)' % (ok, len(pgs), args.report))
    sys.exit(0 if ok == len(pgs) else 1)


if __name__ == '__main__':
    main()
