#!/usr/bin/env bash
# gen-nifi-certs.sh - private CA, per-node keystores, shared truststore and an admin client certificate
# for a NiFi 2.x cluster (NiFi 2.x no longer ships the TLS Toolkit; this uses openssl + keytool).
#
# usage: gen-nifi-certs.sh [-o OUT_DIR] [-s "/C=VN/O=Example"] [-a ADMIN_CN] [-d DAYS] HOST:IP [HOST:IP ...]
#   gen-nifi-certs.sh nifi-1.example.com:10.0.178.10 nifi-2.example.com:10.0.178.11 nifi-3.example.com:10.0.178.12
#
# Safe to re-run: the CA, the truststore and existing node/admin certificates are never overwritten,
# so you can add a node later with the same CA. Delete a node's directory to re-issue it.
# Output (keep it secret, never commit it):
#   OUT/ca/ca.key, ca.crt             the CA - move ca.key OFFLINE once all certificates are issued
#   OUT/truststore.p12 (+ .password)  trusts the CA; identical on every node
#   OUT/nodes/<host>/                 keystore.p12, truststore.p12, nifi-tls.properties, node.crt, node.key
#   OUT/admin/                        admin.crt + admin.key (curl/scripts), admin.p12 (+ .password, browser)
set -euo pipefail

OUT=./nifi-certs; SUBJ_PREFIX="/C=VN/O=Example";   # RDNs before CN (country first = conventional encoding)
 ADMIN_CN=nifi-admin; CERT_DAYS=825; CA_DAYS=3650
while getopts "o:s:a:d:h" o; do
  case $o in o) OUT=$OPTARG ;; s) SUBJ_PREFIX=$OPTARG ;; a) ADMIN_CN=$OPTARG ;; d) CERT_DAYS=$OPTARG ;; *) sed -n '2,15p' "$0"; exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { sed -n '2,15p' "$0"; exit 2; }
for e in "$@"; do [[ $e == *:* ]] || { echo "bad node '$e' (want HOST:IP)"; exit 2; }; done
command -v openssl >/dev/null && command -v keytool >/dev/null || { echo "needs openssl and keytool (JDK)"; exit 1; }

umask 077
mkdir -p "$OUT/ca" "$OUT/nodes" "$OUT/admin"
cd "$OUT"
pw() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-24; }
dn() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }

# 1. CA -------------------------------------------------------------------------------------------
if [ ! -f ca/ca.key ]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "$CA_DAYS" \
    -subj "$SUBJ_PREFIX/CN=NiFi Internal CA" -keyout ca/ca.key -out ca/ca.crt \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  echo "created CA: $(dn ca/ca.crt)"
else
  echo "using existing CA: $(dn ca/ca.crt)"
fi

# 2. truststore: only the CA certificate; the same file on every node --------------------------------
if [ ! -f truststore.p12 ]; then
  pw > truststore.password
  keytool -importcert -noprompt -alias nifi-ca -file ca/ca.crt -keystore truststore.p12 \
    -storetype PKCS12 -storepass "$(cat truststore.password)" >/dev/null 2>&1
fi
TS_PW=$(cat truststore.password)

sign() { # sign CSR CRT EXTFILE
  openssl x509 -req -sha256 -days "$CERT_DAYS" -in "$1" -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
    -extfile "$3" -out "$2" 2>/dev/null
}

# 3. node certificates: serverAuth (HTTPS, cluster protocol) + clientAuth (node-to-node requests) -----
for e in "$@"; do
  host=${e%%:*}; ip=${e##*:}; d="nodes/$host"
  if [ -f "$d/keystore.p12" ]; then echo "node $host: exists, skipped"; continue; fi
  mkdir -p "$d"
  openssl req -newkey rsa:2048 -nodes -subj "$SUBJ_PREFIX/CN=$host" -keyout "$d/node.key" -out "$d/node.csr" 2>/dev/null
  printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth,clientAuth" "subjectAltName=DNS:$host,IP:$ip" > "$d/ext.cnf"
  sign "$d/node.csr" "$d/node.crt" "$d/ext.cnf"
  ks_pw=$(pw)
  openssl pkcs12 -export -name nifi-key -inkey "$d/node.key" -in "$d/node.crt" -certfile ca/ca.crt \
    -out "$d/keystore.p12" -passout "pass:$ks_pw"
  cp truststore.p12 "$d/truststore.p12"
  cat > "$d/nifi-tls.properties" <<EOF
# --- merge into conf/nifi.properties on $host ($ip) ---
nifi.web.https.host=$host
nifi.web.https.port=8443
nifi.cluster.node.address=$host
nifi.remote.input.host=$host
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=$ks_pw
nifi.security.keyPasswd=$ks_pw
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=$TS_PW
EOF
  rm -f "$d/node.csr" "$d/ext.cnf"
  echo "node $host ($ip): issued  DN=$(dn "$d/node.crt")"
done

# 4. admin client certificate: clientAuth only -----------------------------------------------------
if [ ! -f admin/admin.crt ]; then
  openssl req -newkey rsa:2048 -nodes -subj "$SUBJ_PREFIX/CN=$ADMIN_CN" -keyout admin/admin.key -out admin/admin.csr 2>/dev/null
  printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature" "extendedKeyUsage=clientAuth" > admin/ext.cnf
  sign admin/admin.csr admin/admin.crt admin/ext.cnf
  pw > admin/admin.p12.password
  openssl pkcs12 -export -name "$ADMIN_CN" -inkey admin/admin.key -in admin/admin.crt -certfile ca/ca.crt \
    -out admin/admin.p12 -passout "pass:$(cat admin/admin.p12.password)"
  rm -f admin/admin.csr admin/ext.cnf
  echo "admin client: issued  DN=$(dn admin/admin.crt)"
fi

# 5. self-check --------------------------------------------------------------------------------------
echo "--- verification"
for c in nodes/*/node.crt admin/admin.crt; do
  printf '%-40s %s  expires %s\n' "$c" "$(openssl verify -CAfile ca/ca.crt "$c" | awk '{print $NF}')" \
    "$(openssl x509 -in "$c" -noout -enddate | cut -d= -f2)"
done

cat <<EOF
--- authorizers.xml (identities as NiFi sees them; see NIFI-TLS.md "Identities")
EOF
i=1
for c in nodes/*/node.crt; do echo "  <property name=\"Node Identity $i\">$(dn "$c" | sed 's/,/, /g')</property>"; i=$((i + 1)); done
echo "  <property name=\"Initial Admin Identity\">$(dn admin/admin.crt | sed 's/,/, /g')</property>"
echo "done: $(pwd)  (move ca/ca.key offline; copy nodes/<host>/{keystore.p12,truststore.p12} to that node's conf/)"
