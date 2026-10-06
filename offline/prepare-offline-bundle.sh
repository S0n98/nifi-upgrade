#!/usr/bin/env bash
# prepare-offline-bundle.sh - run on a machine WITH internet access; produces one tarball to carry into the
# air-gapped network for the NiFi 2.0.0-M4 -> 2.12.0 upgrade.
#
# usage: prepare-offline-bundle.sh [options]
#   -v VERSION        NiFi version (default 2.12.0)
#   -o DIR            output directory (default ./nifi-offline-bundle-VERSION)
#   -p                also download python3.12 RPMs + deps (must run on RHEL 9 with dnf + subscription);
#                     needed only if your flows use Python processors (NiFi 2.12 needs Python 3.10-3.12, RHEL 9 has 3.9)
#   -r REQ_FILE       also download wheels for Python processor dependencies (requirements.txt), may repeat
#   -a ARTIFACT       Apache artifact name to fetch instead of nifi-VERSION-bin.zip (testing only)
#   -n                no tarball, leave the directory only
#
# Result: DIR/ and DIR.tar containing
#   nifi/nifi-VERSION-bin.zip (+ .sha512 .asc KEYS)   verified: SHA-512 always, PGP signature when gpg is available
#   rpms/   (with -p)  python3.12 RPMs for: dnf install --disablerepo='*' rpms/*.rpm
#   wheels/ (with -r)  wheels for: pip install --no-index --find-links wheels ...
#   runbook/           nifi-upgrade.sh, lib/, migrate-registry-to-gitlab.py, certs/, docs (no secrets, no run logs)
#   MANIFEST.sha256    checksum of every file - check on the other side with: sha256sum -c MANIFEST.sha256
set -euo pipefail

VERSION=2.12.0; OUT=""; WITH_RPMS=no; REQS=(); ARTIFACT=""; TARBALL=yes
while getopts "v:o:pr:a:nh" o; do
  case $o in
    v) VERSION=$OPTARG ;; o) OUT=$OPTARG ;; p) WITH_RPMS=yes ;; r) REQS+=("$OPTARG") ;; a) ARTIFACT=$OPTARG ;;
    n) TARBALL=no ;; *) sed -n '2,22p' "$0"; exit 2 ;;
  esac
done
ARTIFACT=${ARTIFACT:-nifi-$VERSION-bin.zip}
OUT=${OUT:-./nifi-offline-bundle-$VERSION}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the runbook directory
ARCHIVE=https://archive.apache.org/dist/nifi/$VERSION
MIRROR=${MIRROR:-https://downloads.apache.org/nifi/$VERSION}    # fast CDN; falls back to the archive
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$OUT/nifi"
cd "$OUT"

# 1. NiFi release ----------------------------------------------------------------------------------
fetch() { # fetch FILE -> nifi/FILE, mirror first, then archive
  local f=$1
  [ -s "nifi/$f" ] && { log "have nifi/$f"; return 0; }
  log "downloading $f"
  curl -fsSL --retry 3 -o "nifi/$f.part" "$MIRROR/$f" 2>/dev/null || curl -fsSL --retry 3 -o "nifi/$f.part" "$ARCHIVE/$f" \
    || { rm -f "nifi/$f.part"; die "cannot download $f"; }
  mv "nifi/$f.part" "nifi/$f"
}
fetch "$ARTIFACT"
# checksum and signature always from archive.apache.org (independent of the mirror that served the zip)
curl -fsSL -o "nifi/$ARTIFACT.sha512" "$ARCHIVE/$ARTIFACT.sha512" || die "cannot get $ARTIFACT.sha512"
curl -fsSL -o "nifi/$ARTIFACT.asc" "$ARCHIVE/$ARTIFACT.asc" || die "cannot get $ARTIFACT.asc"
curl -fsSL -o nifi/KEYS https://downloads.apache.org/nifi/KEYS || die "cannot get KEYS"
SHA=$(awk '{print $1}' "nifi/$ARTIFACT.sha512")
echo "$SHA  nifi/$ARTIFACT" | sha512sum -c --quiet - || die "SHA-512 mismatch - delete nifi/$ARTIFACT and retry"
log "SHA-512 OK"
if command -v gpg >/dev/null; then
  G=$(mktemp -d); trap 'rm -rf "$G"' EXIT
  GNUPGHOME=$G gpg --quiet --import nifi/KEYS 2>/dev/null
  if GNUPGHOME=$G gpg --verify "nifi/$ARTIFACT.asc" "nifi/$ARTIFACT" 2>"$G/out"; then
    log "PGP signature OK: $(grep -o 'Good signature from "[^"]*"' "$G/out")"
  else
    cat "$G/out"; die "PGP signature verification FAILED"
  fi
else
  log "WARN gpg not installed - signature NOT verified (SHA-512 was)"
fi
echo "DIST_SHA512=$SHA" > nifi/DIST_SHA512

# 2. Python 3.12 RPMs (RHEL 9) ---------------------------------------------------------------------
if [ "$WITH_RPMS" = yes ]; then
  command -v dnf >/dev/null || die "-p needs dnf (run on a RHEL 9 host with repositories enabled)"
  grep -q 'VERSION_ID="9' /etc/os-release || die "-p must run on RHEL 9 (RPMs must match the nodes)"
  mkdir -p rpms
  log "downloading python3.12 RPMs with dependencies"
  dnf download -q --resolve --destdir rpms python3.12 python3.12-pip python3.12-libs
  log "rpms: $(ls rpms | wc -l) files"
fi

# 3. wheels for Python processor dependencies -----------------------------------------------------
if [ ${#REQS[@]} -gt 0 ]; then
  mkdir -p wheels
  for r in "${REQS[@]}"; do
    log "downloading wheels for $r (Python 3.12, manylinux x86_64)"
    python3 -m pip download -q -d wheels -r "$r" --only-binary=:all: \
      --platform manylinux2014_x86_64 --platform manylinux_2_28_x86_64 --python-version 3.12 --implementation cp \
      || die "pip download failed for $r (a dependency without a binary wheel must be built on a RHEL 9 host)"
    cp "$r" "wheels/$(basename "$(dirname "$(readlink -f "$r")")")-requirements.txt"
  done
  log "wheels: $(ls wheels | wc -l) files"
fi

# 4. the runbook itself (code + docs only) --------------------------------------------------------
mkdir -p runbook
tar -C "$HERE" --exclude=runs --exclude=nifi-certs --exclude='*.p12' --exclude='*.key' --exclude='*.password' \
    --exclude='*.env' --exclude='local-test.conf' --exclude='nifi-upgrade.conf' --exclude=__pycache__ \
    --exclude=.git --exclude='nifi-offline-bundle-*' -cf - . | tar -C runbook -xf -

# 5. manifest + tarball ---------------------------------------------------------------------------
cat > VERSIONS.txt <<EOF
NiFi $VERSION  ($ARTIFACT)
created $(date -u +%FT%TZ) on $(hostname)
DIST_SHA512=$SHA
python3.12 RPMs: $WITH_RPMS   wheels: ${#REQS[@]} requirements file(s)
EOF
find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
log "manifest: $(wc -l < MANIFEST.sha256) files, $(du -sh . | cut -f1)"
cd ..
if [ "$TARBALL" = yes ]; then
  tar -cf "$(basename "$OUT").tar" "$(basename "$OUT")"
  sha256sum "$(basename "$OUT").tar" > "$(basename "$OUT").tar.sha256"
  log "bundle: $(pwd)/$(basename "$OUT").tar  ($(du -h "$(basename "$OUT").tar" | cut -f1)), sha256 in .tar.sha256"
fi
log "carry the .tar and .tar.sha256 into the air-gapped network"
