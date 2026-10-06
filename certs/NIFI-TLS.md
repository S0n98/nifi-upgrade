# How TLS works in a NiFi 2.x cluster — and how to set it up

This guide explains where NiFi uses TLS and what each certificate must contain. It then shows how to issue
certificates with [`gen-nifi-certs.sh`](gen-nifi-certs.sh) and deploy them to a 3-node cluster:

| Node | Hostname (example) | IP |
|---|---|---|
| 1 | nifi-1.example.com | 10.0.178.10 |
| 2 | nifi-2.example.com | 10.0.178.11 |
| 3 | nifi-3.example.com | 10.0.178.12 |

Replace the example hostnames with your real ones. **The hostnames must resolve (DNS or `/etc/hosts`) on every
node and on every client.**

> NiFi 1.x shipped a **TLS Toolkit** that generated certificates. NiFi 2.x no longer includes it, so you issue
> certificates yourself — the script does it with `openssl` and `keytool`.

---

## 1. Where NiFi uses TLS

```
   browser / curl / nifi-upgrade.sh
            │  HTTPS 8443  (server cert of the node; optional client cert = user identity)
            ▼
 ┌───────────────────┐  cluster protocol 11443 (mTLS)   ┌───────────────────┐
 │ nifi-1 10.0.178.10│◄──── heartbeats, flow sync ─────►│ nifi-2 10.0.178.11│
 │  keystore.p12     │◄──── request replication ───────►│  keystore.p12     │
 │  truststore.p12   │      (HTTPS 8443, node = client) │  truststore.p12   │
 └─────────┬─────────┘◄──── load balancing 6342 (mTLS) ►└─────────┬─────────┘
           │              site-to-site (mTLS)                     │
           └──────────────────────► nifi-3 10.0.178.12 ◄──────────┘
                ▲
                │ ZooKeeper 2181 (plain, or TLS if configured separately)
```

| Channel | Who is the client | Certificate used | Notes |
|---|---|---|---|
| Web UI / REST API (`nifi.web.https.port`, 8443) | browser, curl, scripts | node **server** cert; caller's **client** cert is optional | NiFi *asks* for a client certificate but does not require one. If the caller presents one signed by a CA in the truststore, that certificate is the identity. Otherwise the caller authenticates with OIDC / a login provider (JWT). Tested on NiFi 2.12 with OIDC enabled. |
| Request replication | the node that received the request | node cert as **client** | A UI/API request to one node is replayed to all nodes. That node acts as a proxy for the user, so node identities need the **proxy user requests** policy. |
| Cluster protocol (`nifi.cluster.node.protocol.port`) | node ↔ cluster coordinator | node cert, both directions (mutual TLS) | In 2.x this always uses TLS; the old `nifi.cluster.protocol.is.secure` property was removed. |
| Load-balanced connections (`nifi.cluster.load.balance.port`, 6342) | sending node | node cert, mutual TLS | |
| Site-to-Site | remote NiFi / MiNiFi | node cert, mutual TLS | The remote side's identity needs site-to-site policies. |
| Outbound from flows (InvokeHTTP, DB, Kafka, registry clients…) | NiFi | an **SSL Context Service** you configure | Independent of the node keystore. Point it at the right truststore (see the GitLab client in RUNBOOK §6). |
| OIDC (NiFi → identity provider) | NiFi | `nifi.security.user.oidc.truststore.strategy` | `NIFI` = use the node truststore (add the IdP's CA to it). `JDK` = use Java's cacerts. |
| ZooKeeper | NiFi | separate `nifi.zookeeper.security.*` settings | Optional; not covered by this script. |

**Consequence:** each node certificate is used as both a **server** and a **client** certificate. It must carry
both `serverAuth` and `clientAuth` in Extended Key Usage. A server-only certificate breaks the cluster.

## 2. Trust model

- **One private CA** signs every node certificate and the admin client certificate.
- **truststore.p12** holds only the CA certificate and is identical on every node. A node trusts anything signed
  by the CA, so adding a node later only needs a new keystore, not a truststore change.
- **keystore.p12** (one per node) holds that node's private key and its certificate chain (node cert + CA).
- **ca.key** is the only thing that can create new trusted identities. Generate on a secure admin host, then move it
  **offline**.

## 3. What each certificate must contain

| | Node certificate | Admin client certificate |
|---|---|---|
| Subject DN | `CN=nifi-1.example.com, O=Example, C=VN` | `CN=nifi-admin, O=Example, C=VN` |
| Subject Alternative Name | `DNS:nifi-1.example.com, IP:10.0.178.10` — **every name or IP that clients or other nodes use** | none needed |
| Extended Key Usage | `serverAuth, clientAuth` | `clientAuth` |
| Key Usage | `digitalSignature, keyEncipherment` | `digitalSignature` |
| Key / validity | RSA 2048, 825 days | RSA 2048, 825 days |
| Format | PKCS12 keystore; key password = keystore password | PEM (`admin.crt` + `admin.key`) for curl/scripts, PKCS12 for browsers |

Hostname verification checks the **SAN**, not the CN. If anything connects to `https://10.0.178.10:8443`, the IP must
be in the SAN; if it connects by name, the name must be. If users reach the UI through a load balancer, add the
LB's DNS name to every node's SAN and to `nifi.web.proxy.host` (or terminate TLS on the LB).

## 4. Identities: the DN string must match exactly

NiFi authorizes a certificate user by the subject DN string. NiFi 2.12 formats it as
**`CN=…, O=…, C=…`** — RFC 2253 order, comma **plus space** between parts. This was checked on NiFi 2.12:
`GET /nifi-api/flow/current-user` with the admin cert returned `"identity":"CN=nifi-admin, O=Example, C=VN"`.

That exact string goes into `authorizers.xml`. A missing space or a different RDN order means "unknown user".
The script prints the strings to paste.

Certificates are issued with the subject written country-first (`/C=VN/O=Example/CN=host`), the conventional
encoding, so the DN reads `CN=host, O=Example, C=VN`. Writing it CN-first produces the reversed string
`C=VN, O=Example, CN=host`.

**Optional — identity mapping.** To use plain names (`nifi-1.example.com`, `nifi-admin`) instead of full DNs, add
this to `nifi.properties` on every node:

```properties
nifi.security.identity.mapping.pattern.dn=^CN=(.*?), .*$
nifi.security.identity.mapping.value.dn=$1
nifi.security.identity.mapping.transform.dn=NONE
```

The mapped value is then what `authorizers.xml` and policies use. OIDC email identities don't match the pattern,
so they are unaffected. Decide this **before** creating users: on an existing cluster it changes the identity of
every certificate user.

## 5. Generate the certificates

On a secure admin host (needs `openssl` and a JDK's `keytool`):

```bash
./gen-nifi-certs.sh -o ./nifi-certs -s "/C=VN/O=Example" -a nifi-admin \
    nifi-1.example.com:10.0.178.10 nifi-2.example.com:10.0.178.11 nifi-3.example.com:10.0.178.12
```

Output (all files mode 600 — **never commit them**):

```
nifi-certs/
  ca/ca.crt  ca/ca.key                 CA (move ca.key offline when done)
  truststore.p12  truststore.password
  nodes/nifi-1.example.com/
      keystore.p12  truststore.p12     -> copy to the node's conf/
      nifi-tls.properties              -> merge into the node's nifi.properties (has the passwords)
      node.crt  node.key               PEM copies (for checks; node.key need not go to the node)
  nodes/nifi-2.example.com/ ...  nodes/nifi-3.example.com/ ...
  admin/admin.crt  admin.key          client cert for curl / nifi-upgrade.sh (NIFI_CLIENT_CERT/KEY)
  admin/admin.p12  admin.p12.password import into a browser
```

The script is safe to re-run. It reuses the CA and truststore, skips nodes that already exist, and prints a
verification summary plus the `authorizers.xml` identity lines. To add a 4th node later, run it again with the new
`host:ip`. To re-issue a certificate, delete that node's directory and run it again.

## 6. Deploy to the 3 nodes

### 6.1 Copy the files

For each node:

```bash
H=nifi-1.example.com
scp nifi-certs/nodes/$H/{keystore.p12,truststore.p12} ops@$H:/tmp/
ssh ops@$H 'sudo install -o nifi -g nifi -m 600 /tmp/keystore.p12 /tmp/truststore.p12 /data/nifi/current/conf/ && rm /tmp/*.p12'
```

### 6.2 `nifi.properties` on each node

Start from that node's `nifi-tls.properties` (keystore, truststore, passwords, host), then the cluster settings:

```properties
nifi.web.https.host=nifi-1.example.com          # this node
nifi.web.https.port=8443
nifi.web.http.port=                             # leave HTTP disabled
nifi.web.proxy.host=                            # add LB name:port here if users come through a load balancer

nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=<from nifi-tls.properties>
nifi.security.keyPasswd=<same as keystorePasswd>
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=<from nifi-tls.properties>

nifi.cluster.is.node=true
nifi.cluster.node.address=nifi-1.example.com    # this node
nifi.cluster.node.protocol.port=11443
nifi.cluster.load.balance.host=nifi-1.example.com
nifi.cluster.load.balance.port=6342
nifi.remote.input.host=nifi-1.example.com
nifi.zookeeper.connect.string=zk-1:2181,zk-2:2181,zk-3:2181
```

Keep the passwords out of version control. `nifi.properties` should be mode 640 or tighter, owned by `nifi`.

### 6.3 `authorizers.xml` (identical on all nodes)

Paste the lines printed by the script into `file-user-group-provider` **and** `file-access-policy-provider`:

```xml
<!-- file-user-group-provider -->
<property name="Initial User Identity 1">CN=nifi-admin, O=Example, C=VN</property>
<property name="Initial User Identity 2">CN=nifi-1.example.com, O=Example, C=VN</property>
<property name="Initial User Identity 3">CN=nifi-2.example.com, O=Example, C=VN</property>
<property name="Initial User Identity 4">CN=nifi-3.example.com, O=Example, C=VN</property>

<!-- file-access-policy-provider -->
<property name="Initial Admin Identity">CN=nifi-admin, O=Example, C=VN</property>
<property name="Node Identity 1">CN=nifi-1.example.com, O=Example, C=VN</property>
<property name="Node Identity 2">CN=nifi-2.example.com, O=Example, C=VN</property>
<property name="Node Identity 3">CN=nifi-3.example.com, O=Example, C=VN</property>
```

**The "Initial …" properties are only applied when `users.xml` and `authorizations.xml` do not exist yet.** On an
existing cluster they are ignored. In that case, as an admin, add the three node identities as users (Users
page or `/nifi-api/tenants/users`). Give them the policies **proxy user requests** (`/proxy`, write) and
**view the user interface** (`/flow`, read), plus site-to-site policies if you use S2S. Do this **before**
switching to the new certificates, while the cluster still works.

If you use OIDC for people (as in the test setup), keep it — certificates and OIDC work side by side. The admin
client certificate is then the identity for automation (`nifi-upgrade.sh`).

### 6.4 Restart

If this is the first TLS setup or a **CA change**, stop all nodes, deploy, then start all nodes. Nodes that trust
different CAs cannot talk to each other. If you only renew node certificates from the **same CA**, you can
restart one node at a time.

## 7. Verify

```bash
# 1. server certificate, chain and SAN, as a client sees it (from any host that has ca.crt)
openssl s_client -connect 10.0.178.10:8443 -servername nifi-1.example.com -CAfile nifi-certs/ca/ca.crt </dev/null 2>/dev/null \
  | grep -E 'Verify return code|subject='                 # expect: Verify return code: 0 (ok)

# 2. admin identity via client certificate
curl -s --cacert nifi-certs/ca/ca.crt --cert nifi-certs/admin/admin.crt --key nifi-certs/admin/admin.key \
  https://nifi-1.example.com:8443/nifi-api/flow/current-user | grep -o '"identity":"[^"]*"'
# expect: "identity":"CN=nifi-admin, O=Example, C=VN"

# 3. all nodes joined over TLS
curl -s --cacert nifi-certs/ca/ca.crt --cert nifi-certs/admin/admin.crt --key nifi-certs/admin/admin.key \
  https://nifi-1.example.com:8443/nifi-api/controller/cluster | grep -o '"status":"[A-Z]*"'
# expect: "CONNECTED" three times

# 4. keystore content on a node
keytool -list -v -keystore /data/nifi/current/conf/keystore.p12 -storetype PKCS12 | grep -E 'Owner|Valid|DNSName|IPAddress'
```

Settings for [`nifi-upgrade.sh`](../nifi-upgrade.sh) automation:
`NIFI_CA_CERT=nifi-certs/ca/ca.crt`, `NIFI_CLIENT_CERT=nifi-certs/admin/admin.crt`,
`NIFI_CLIENT_KEY=nifi-certs/admin/admin.key`.

## 8. Renewal and rotation

- **Expiry:** certificates are valid for 825 days. Check with
  `openssl x509 -enddate -noout -in node.crt`, and alert at about 60 days before.
- **Renew a node (same CA):** delete `nodes/<host>/`, re-run the script, deploy that node's `keystore.p12`, and
  restart that node. The identity DN is unchanged, so no policy changes are needed.
- **Rotate the CA:** NiFi trusts every CA in the truststore, so overlap the old and new CAs:
  1. Add the new CA to every node's truststore and restart the nodes one at a time.
  2. Issue new keystores from the new CA, deploy them and restart the nodes one at a time.
  3. Remove the old CA from the truststores and restart once more.
- **Upgrades:** `nifi-upgrade.sh stage` copies `keystore.p12` and `truststore.p12` and their properties to the
  new version, so certificates carry across NiFi upgrades.

## 9. Troubleshooting

| Symptom (log or client) | Cause | Fix |
|---|---|---|
| `PKIX path building failed` / `unable to find valid certification path` | peer's CA not in the truststore | Same `truststore.p12` on all nodes. For OIDC/GitLab: put that CA in the truststore and set `oidc.truststore.strategy=NIFI` |
| `No subject alternative names matching IP address …` / `… DNS name …` | the name or IP used to connect is not in the SAN | Re-issue with that name or IP, or connect with a name that is in the SAN |
| Node never joins; `certificate_unknown` / `bad_certificate` during handshake | node cert lacks `clientAuth` EKU, or nodes trust different CAs | Use this script's certs (both EKUs); one CA everywhere |
| `Untrusted proxy CN=nifi-2…` / 403 when using the UI | node identity lacks the **proxy user requests** policy | Add the node user and `/proxy` write (6.3) |
| `Unknown user with identity 'CN=…'` | DN string in `authorizers.xml` / users doesn't match exactly | Copy the string from `/flow/current-user` or the script output (format in §4) |
| NiFi won't start: keystore password / `Get Key failed` | wrong password, or `keyPasswd` ≠ `keystorePasswd` for PKCS12 | Use the values from `nifi-tls.properties` (both equal) |
| Browser keeps asking for a certificate | normal: NiFi requests (but does not require) a client cert | Cancel to use OIDC, or pick the imported admin cert |
| Works by IP but not by name (or the reverse) | DNS / `/etc/hosts` differs between nodes or clients | Make names resolve identically everywhere |

## 10. Security checklist

- [ ] `ca.key` moved offline after issuing. Not on any NiFi node.
- [ ] Keystores, truststores and `nifi.properties`: owner `nifi`, mode 600 or 640.
- [ ] No certificate or password file committed. `.gitignore` here covers `nifi-certs/`, `*.p12`, `*.key`, `*.password`.
- [ ] HTTP port disabled (`nifi.web.http.port` empty).
- [ ] The admin client key is stored like a password; it grants full admin access.
- [ ] Certificate expiry is monitored.

---

**What was tested** (2026-10-05, on the single-node test host):
- The script ran for these three nodes. Chains verify; the SANs contain hostname + IP; the EKUs are as in §3;
  Java's `keytool` reads every keystore.
- Re-running it skips existing certificates.
- NiFi 2.12 accepted the admin client certificate next to OIDC and reported the identity in the format in §4.

A real 3-node TLS cluster (cluster protocol, load balancing, request replication between these certificates) was
**not** tested here. Verify with §7 on staging first.
