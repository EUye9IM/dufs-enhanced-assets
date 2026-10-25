#!/usr/bin/env bash
# Mint the TLS material dufs needs for a secure context on a home LAN.
#
#   ./scripts/gen-tls.sh              # create CA if missing, (re)issue the server cert
#   ./scripts/gen-tls.sh --host 192.168.1.100 --host nas.local
#   ./scripts/gen-tls.sh --verify     # only re-run the sanity checks
#
# Why a private CA instead of a single self-signed certificate: a server certificate's SAN
# must name the address clients actually type, so a self-signed cert has to be replaced
# (and re-trusted on every device) whenever the LAN IP changes. With a CA the client trusts
# the CA once, and re-issuing the leaf is invisible to every device.
#
# Nothing secret is ever written under assets/. That directory is served by dufs over HTTP
# under /__dufs_v<version>__/, so only the CA *certificate* (a public key) is published
# there — never a private key. The script enforces this in both directions.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$REPO_DIR/assets"
PUBLISH_DIR="$ASSETS_DIR/trust"
DEFAULT_OUT_DIR="$REPO_DIR/tls"

OUT_DIR="$DEFAULT_OUT_DIR"
CA_DAYS=3650
LEAF_DAYS=825
KEY_ALG="ec"
FORCE=0
FORCE_CA=0
AUTO_HOSTS=1
VERIFY_ONLY=0
QUIET=0
PUBLISH=1
MOBILECONFIG=0
MOBILECONFIG_PATH=""
HOSTS=""
COMMON_NAME="dufs-lan"

usage() {
  cat <<'EOF'
Usage: scripts/gen-tls.sh [options]

  --host <name|ip>     extra SAN entry (repeatable)
  --no-auto            only use --host entries plus loopback (skip address auto-detection)
  --cn <name>          certificate common name (default: dufs-lan)
  --out-dir <dir>      where key material is written (default: <repo>/tls)
  --mobileconfig [f]   also write an iOS/iPadOS trust profile
                       (default: <out-dir>/dufs-ca.mobileconfig)
  --ca-days <n>        CA validity in days (default: 3650)
  --leaf-days <n>      server certificate validity in days (default: 825)
  --rsa                RSA-2048 keys instead of EC P-256
  --force              re-issue the server certificate even if it is still valid
  --force-ca           regenerate the CA (every device must be re-trusted)
  --no-publish         do not copy ca.crt/mobileconfig into assets/trust/
  --verify             only run the sanity checks, generate nothing
  -q, --quiet          print only the essentials
  -h, --help           this text

Published files (public key material only, served by dufs):
  assets/trust/ca.crt                  root certificate to install on clients
  assets/trust/dufs-ca.mobileconfig    same, as an iOS/iPadOS profile

Never served, never committed:
  <out-dir>/ca.key, <out-dir>/dufs.key
EOF
}

# ---------------------------------------------------------------- output helpers

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host helpers
# Defined before argument parsing: --host calls add_host directly.

add_host() {
  local h="${1:-}"
  h="$(printf '%s' "$h" | tr -d '[:space:]')"
  [ -n "$h" ] || return 0
  case "$h" in *[!A-Za-z0-9.:_-]*) fail "refusing suspicious SAN entry: $h" ;; esac
  if printf '%s' "$HOSTS" | grep -Fxq -- "$h"; then
    return 0
  fi
  HOSTS="${HOSTS}${h}"$'\n'
}

is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_ipv6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- argument parsing

need_value() { [ $# -ge 2 ] || fail "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        need_value "$@"; add_host "$2"; shift 2 ;;
    --host=*)      add_host "${1#*=}"; shift ;;
    --no-auto)     AUTO_HOSTS=0; shift ;;
    --cn)          need_value "$@"; COMMON_NAME="$2"; shift 2 ;;
    --out-dir)     need_value "$@"; OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --mobileconfig) MOBILECONFIG=1
                    if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                      MOBILECONFIG_PATH="$2"; shift 2
                    else
                      MOBILECONFIG_PATH=""; shift
                    fi ;;
    --ca-days)     need_value "$@"; CA_DAYS="$2"; shift 2 ;;
    --leaf-days)   need_value "$@"; LEAF_DAYS="$2"; shift 2 ;;
    --rsa)         KEY_ALG="rsa"; shift ;;
    --force)       FORCE=1; shift ;;
    --force-ca)    FORCE_CA=1; shift ;;
    --no-publish)  PUBLISH=0; shift ;;
    --verify)      VERIFY_ONLY=1; shift ;;
    -q|--quiet)    QUIET=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             fail "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- hosts / SAN set

detect_hosts() {
  local h
  add_host localhost
  add_host 127.0.0.1
  add_host "::1"
  h="$(hostname 2>/dev/null || true)"
  add_host "$h"
  add_host "$(hostname -s 2>/dev/null || true)"
  [ -n "$h" ] && add_host "$h.local"

  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r h; do add_host "$h"; done <<EOF
$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
EOF
  elif command -v hostname >/dev/null 2>&1; then
    for h in $(hostname -I 2>/dev/null || true); do add_host "$h"; done
  fi
}

san_entries() {
  local h entry out=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if is_ipv4 "$h" || is_ipv6 "$h"; then
      entry="IP:$h"
    else
      entry="DNS:$h"
    fi
    if [ -z "$out" ]; then out="$entry"; else out="$out,$entry"; fi
  done <<EOF
$HOSTS
EOF
  printf '%s' "$out"
}

# OpenSSL prints SAN entries as "IP Address:1.2.3.4" while our input uses "IP:1.2.3.4",
# and it prints IPv6 in expanded form. Canonicalise both before comparing sets, so a
# no-op re-run really is a no-op.
normalize_san() {
  tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^IP Address:/IP:/; s/^IP:0:0:0:0:0:0:0:1$/IP:::1/' |
    grep -v '^$' | sort | tr '\n' ' '
}

san_of_cert() {
  local file="$1" text
  if text="$(openssl x509 -in "$file" -noout -ext subjectAltName 2>/dev/null)"; then
    printf '%s\n' "$text" | tail -n +2
  else
    openssl x509 -in "$file" -noout -text 2>/dev/null |
      sed -n '/Subject Alternative Name/{n;s/^[[:space:]]*//;p;q;}'
  fi
}

first_lan_address() {
  local h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    case "$h" in
      localhost|127.0.0.1|::1) ;;
      *) if is_ipv4 "$h"; then printf '%s' "$h"; return 0; fi ;;
    esac
  done <<EOF
$HOSTS
EOF
  printf '%s' "localhost"
}

# ---------------------------------------------------------------- preflight

command -v openssl >/dev/null 2>&1 || fail "openssl not found in PATH"

if [ "$AUTO_HOSTS" -eq 1 ]; then
  detect_hosts
fi
# --host may have been parsed before detect_hosts, so re-add the base set if needed.
add_host localhost
add_host 127.0.0.1
add_host "::1"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
ASSETS_DIR="$(cd "$ASSETS_DIR" 2>/dev/null && pwd -P || printf '%s' "$ASSETS_DIR")"

case "$OUT_DIR/" in
  "$ASSETS_DIR"/*)
    fail "--out-dir must not be inside assets/ — everything under assets/ is served over HTTP by dufs" ;;
esac

CA_KEY="$OUT_DIR/ca.key"
CA_CRT="$OUT_DIR/ca.crt"
LEAF_KEY="$OUT_DIR/dufs.key"
LEAF_CRT="$OUT_DIR/dufs.crt"
LEAF_CSR="$OUT_DIR/dufs.csr"
SERIAL="$OUT_DIR/ca.srl"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------- key algorithms

gen_key() { # $1 = output path
  case "$KEY_ALG" in
    ec)  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null ;;
    rsa) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null ;;
  esac
  chmod 600 "$1"
}

key_is_pkcs8() { head -n 1 "$1" 2>/dev/null | grep -q 'BEGIN PRIVATE KEY'; }

cert_matches_key() { # $1 = cert, $2 = key
  local a b
  a="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  b="$(openssl pkey -in "$2" -pubout 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# ---------------------------------------------------------------- CA

ca_present=0
if [ -s "$CA_KEY" ] && [ -s "$CA_CRT" ]; then
  ca_present=1
fi

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$FORCE_CA" -eq 1 ]; then
  say "==> Regenerating the CA"
  printf 'This invalidates the trust you installed on every device.\nType "yes" to continue: '
  read -r answer
  [ "$answer" = "yes" ] || fail "aborted"
  rm -f "$CA_KEY" "$CA_CRT" "$SERIAL"
  ca_present=0
fi

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$ca_present" -eq 0 ]; then
  say "==> Creating private CA (${CA_DAYS}d)"
  cat >"$WORK_DIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${COMMON_NAME}-ca
O = dufs-enhanced-assets private CA
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
  gen_key "$CA_KEY"
  openssl req -x509 -new -key "$CA_KEY" -days "$CA_DAYS" -sha256 \
    -config "$WORK_DIR/ca.cnf" -extensions v3_ca -out "$CA_CRT" 2>/dev/null
  chmod 644 "$CA_CRT"
  ca_present=1
fi

[ "$ca_present" -eq 1 ] || fail "no CA at $CA_CRT (run without --verify first)"

# ---------------------------------------------------------------- leaf

SAN="$(san_entries)"
[ -n "$SAN" ] || fail "no SAN entries — pass --host <name|ip>"

leaf_ok=0
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -s "$LEAF_CRT" ] && [ -s "$LEAF_KEY" ]; then
  if openssl verify -CAfile "$CA_CRT" "$LEAF_CRT" >/dev/null 2>&1 &&
     openssl x509 -in "$LEAF_CRT" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 &&
     cert_matches_key "$LEAF_CRT" "$LEAF_KEY" &&
     [ "$(san_of_cert "$LEAF_CRT" | normalize_san)" = "$(printf '%s' "$SAN" | normalize_san)" ]; then
    leaf_ok=1
  fi
fi

if [ "$VERIFY_ONLY" -eq 0 ]; then
  if [ "$leaf_ok" -eq 1 ]; then
    say "==> Server certificate still valid and SAN unchanged — keeping it"
  else
    say "==> Issuing server certificate (${LEAF_DAYS}d)"
    say "    SAN: $SAN"
    cat >"$WORK_DIR/leaf.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${COMMON_NAME}
EOF
    cat >"$WORK_DIR/leaf.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = ${SAN}
EOF
    rm -f "$LEAF_CRT" "$LEAF_KEY"
    gen_key "$LEAF_KEY"
    openssl req -new -key "$LEAF_KEY" -config "$WORK_DIR/leaf.cnf" -out "$LEAF_CSR" 2>/dev/null
    openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAserial "$SERIAL" \
      -CAcreateserial -days "$LEAF_DAYS" -sha256 -extfile "$WORK_DIR/leaf.ext" \
      -out "$LEAF_CRT" 2>/dev/null
    chmod 644 "$LEAF_CRT"
    rm -f "$LEAF_CSR"
  fi
fi

# ---------------------------------------------------------------- iOS profile

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$MOBILECONFIG" -eq 1 ] && [ -z "$MOBILECONFIG_PATH" ]; then
  MOBILECONFIG_PATH="$OUT_DIR/dufs-ca.mobileconfig"
fi

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-F' 'a-f'
  else
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

write_mobileconfig() { # $1 = output path
  local der uuid1 uuid2
  der="$(openssl x509 -in "$CA_CRT" -outform der | base64 | tr -d '\n')"
  uuid1="$(new_uuid)"
  uuid2="$(new_uuid)"
  cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadCertificateFileName</key>
			<string>ca.crt</string>
			<key>PayloadContent</key>
			<data>${der}</data>
			<key>PayloadDescription</key>
			<string>Adds the private root CA used by dufs on this network.</string>
			<key>PayloadDisplayName</key>
			<string>dufs LAN root CA</string>
			<key>PayloadIdentifier</key>
			<string>local.dufs.trust.root</string>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadUUID</key>
			<string>${uuid2}</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>Trusts the private CA used by dufs on the local network, so HTTPS works without warnings. Installing this profile is not enough on its own: enable full trust under Settings &gt; General &gt; About &gt; Certificate Trust Settings.</string>
	<key>PayloadDisplayName</key>
	<string>dufs LAN trust</string>
	<key>PayloadIdentifier</key>
	<string>local.dufs.trust</string>
	<key>PayloadOrganization</key>
	<string>dufs-enhanced-assets</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>${uuid1}</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF
  chmod 644 "$1"
}

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$MOBILECONFIG" -eq 1 ]; then
  write_mobileconfig "$MOBILECONFIG_PATH"
  say "==> iOS profile:  $MOBILECONFIG_PATH"
fi

# ---------------------------------------------------------------- verification

problems=0
check() { # $1 = description, rest = command
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    return 0
  fi
  printf 'FAIL  %s\n' "$desc" >&2
  problems=$((problems + 1))
}

check "CA certificate parses"            openssl x509 -in "$CA_CRT" -noout
check "server certificate parses"        openssl x509 -in "$LEAF_CRT" -noout
check "server certificate signed by CA"  openssl verify -CAfile "$CA_CRT" "$LEAF_CRT"
check "server key is PKCS#8"             key_is_pkcs8 "$LEAF_KEY"
check "CA key is PKCS#8"                 key_is_pkcs8 "$CA_KEY"
check "server cert matches server key"   cert_matches_key "$LEAF_CRT" "$LEAF_KEY"
check "CA cert matches CA key"           cert_matches_key "$CA_CRT" "$CA_KEY"

san_now="$(san_of_cert "$LEAF_CRT" | normalize_san)"
[ -n "$san_now" ] || { printf 'FAIL  server certificate has no SAN\n' >&2; problems=$((problems + 1)); }
case "$san_now" in
  *IP:127.0.0.1*) ;;
  *) printf 'FAIL  server certificate SAN is missing 127.0.0.1\n' >&2; problems=$((problems + 1)) ;;
esac
nonloopback=0
for entry in $san_now; do
  case "$entry" in
    IP:127.*|IP:::1|DNS:localhost) ;;
    IP:*|DNS:*) nonloopback=1 ;;
  esac
done
if [ "$nonloopback" -eq 0 ]; then
  printf 'WARN  SAN contains loopback only — clients will need a --host entry\n' >&2
fi

# Nothing secret may live under assets/ (that directory is an HTTP namespace).
if [ -d "$ASSETS_DIR" ]; then
  if grep -rl 'PRIVATE KEY' "$ASSETS_DIR" 2>/dev/null | grep -q .; then
    printf 'FAIL  a private key is present under assets/ — that directory is served over HTTP:\n' >&2
    grep -rl 'PRIVATE KEY' "$ASSETS_DIR" 2>/dev/null | sed 's/^/      /' >&2
    problems=$((problems + 1))
  fi
fi

# ---------------------------------------------------------------- publish

if [ "$VERIFY_ONLY" -eq 0 ] && [ "$PUBLISH" -eq 1 ]; then
  case "$PUBLISH_DIR" in
    "$ASSETS_DIR"/trust) ;;
    *) fail "refusing to publish outside assets/trust (resolved: $PUBLISH_DIR)" ;;
  esac
  mkdir -p "$PUBLISH_DIR"
  install -m 644 "$CA_CRT" "$PUBLISH_DIR/ca.crt"
  if [ -n "$MOBILECONFIG_PATH" ] && [ -s "$MOBILECONFIG_PATH" ]; then
    install -m 644 "$MOBILECONFIG_PATH" "$PUBLISH_DIR/dufs-ca.mobileconfig"
  fi
  say "==> Published:     $PUBLISH_DIR/ca.crt"
fi

[ "$problems" -eq 0 ] || fail "$problems check(s) failed"

# ---------------------------------------------------------------- banner

fingerprint="$(openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
notafter="$(openssl x509 -in "$LEAF_CRT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
lan="$(first_lan_address)"

cat <<EOF

==> TLS material ready
    CA certificate   $CA_CRT
    CA key           $CA_KEY          (secret — never publish, never commit)
    server cert      $LEAF_CRT   (expires $notafter)
    server key       $LEAF_KEY          (secret — never publish, never commit)
    CA SHA-256       $fingerprint

==> Serve
    dufs /srv/files --assets "$REPO_DIR/assets" \\
      --tls-cert "$LEAF_CRT" --tls-key "$LEAF_KEY" \\
      --bind 0.0.0.0 --port 24601

==> Trust (once per device)
    https://$lan:24601/__dufs_v<dufs-version>__/trust/index.html
    Everything is downloadable from there; no file has to be copied between devices.
    Linux    sudo cp ca.crt /usr/local/share/ca-certificates/dufs-lan.crt && sudo update-ca-certificates
    macOS    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
    Windows  certmgr.msc -> Trusted Root Certification Authorities -> Import
    Android  Settings -> Security -> Encryption & credentials -> Install a certificate -> CA certificate
    iOS      download dufs-ca.mobileconfig, install the profile, then enable full trust in
             Settings -> General -> About -> Certificate Trust Settings
    Firefox  has its own store: Settings -> Privacy & Security -> Certificates -> View Certificates

    Verify the fingerprint above before trusting the CA on a first visit.

EOF

say "Done."
