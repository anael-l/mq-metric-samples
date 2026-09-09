#!/usr/bin/env bash
# Generate a private CA, a queue manager certificate and a monitor client
# certificate, then package the client identity two ways for the MQ C client:
# a PKCS#12 file (what compose uses by default) and a CMS key database (kdb).
#
# Nothing is required on the host except docker: openssl runs in the
# alpine/openssl image and runmqakm runs in the MQ server image (the exporter
# image is built from the Redistributable Client, whose runmqakm cannot load ICU).
#
# Output layout (all under ./pki, gitignored):
#   qm/keys/qm1/{tls.key,tls.crt,ca.crt}   -> /etc/mqm/pki/keys/qm1 in the MQ container
#   qm/trust/0/tls.crt                     -> /etc/mqm/pki/trust/0    (CA that signed the client cert)
#   client/mqmon.p12                       -> mounted into the exporter, MQSSLKEYR=.../mqmon.p12 + MQKEYRPWD
#   client/key.kdb, key.sth, key.rdb       -> same identity as a CMS kdb, MQSSLKEYR=.../key (stash, no password)
#   client-nocert/key.kdb, key.sth         -> CA only, used for the negative test
set -euo pipefail

cd "$(dirname "$0")"
PKI="$(pwd)/pki"
MQ_IMAGE="${MQ_IMAGE:-icr.io/ibm-messaging/mq:latest}"
KDB_PW="${KDB_PW:-passw0rd}"
UIDGID="$(id -u):$(id -g)"

rm -rf "$PKI"
mkdir -p "$PKI/qm/keys/qm1" "$PKI/qm/trust/0" "$PKI/client" "$PKI/client-nocert" "$PKI/tmp"

# ---- PEM material via openssl -------------------------------------------------
docker run --rm --user "$UIDGID" -e KDB_PW="$KDB_PW" -v "$PKI/tmp:/work" -w /work --entrypoint sh alpine/openssl -euc '
  # CA
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout ca.key -out ca.crt -subj "/CN=MQ e2e test CA/O=e2e"

  # Queue manager identity. SAN covers the compose service name and localhost.
  openssl req -new -newkey rsa:2048 -nodes -keyout qm1.key -out qm1.csr -subj "/CN=QM1/O=e2e"
  printf "subjectAltName=DNS:qm1,DNS:localhost\nextendedKeyUsage=serverAuth\n" > qm1.ext
  openssl x509 -req -in qm1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 \
    -extfile qm1.ext -out qm1.crt

  # Monitor client identity. The CN is what the CHLAUTH SSLPEERMAP rule matches.
  openssl req -new -newkey rsa:2048 -nodes -keyout mqmon.key -out mqmon.csr -subj "/CN=mqmon/O=e2e"
  printf "extendedKeyUsage=clientAuth\n" > mqmon.ext
  openssl x509 -req -in mqmon.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 \
    -extfile mqmon.ext -out mqmon.crt

  # PKCS#12 used directly by the client (MQ 9.x/10 accept a .p12 as the key
  # repository). OpenSSL 3 defaults (AES-256-CBC, PBKDF2, SHA-256 MAC) are fine.
  # It must contain the CA as well, and the friendly name (-name) must match
  # certificateLabel in the CCDT.
  openssl pkcs12 -export -in mqmon.crt -inkey mqmon.key -certfile ca.crt \
    -name mqmon -out mqmon.p12 -passout "pass:$KDB_PW"

  # Second PKCS#12 only for import into the CMS kdb below: runmqakm/GSKit does
  # not understand the OpenSSL 3 defaults, so force the older PBE algorithms.
  openssl pkcs12 -export -in mqmon.crt -inkey mqmon.key -certfile ca.crt \
    -name mqmon -out mqmon-legacy.p12 -passout "pass:$KDB_PW" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
'

cp "$PKI/tmp/qm1.key"  "$PKI/qm/keys/qm1/tls.key"
cp "$PKI/tmp/qm1.crt"  "$PKI/qm/keys/qm1/tls.crt"
cp "$PKI/tmp/ca.crt"   "$PKI/qm/keys/qm1/ca.crt"
cp "$PKI/tmp/ca.crt"   "$PKI/qm/trust/0/tls.crt"
# The MQ container runs as uid 1001 and copies these into its own keystore at
# start-up, so they must be readable by that uid. Test material only.
chmod 644 "$PKI"/qm/keys/qm1/* "$PKI"/qm/trust/0/*

# ---- Client PKCS#12: nothing more to do, it is the key repository as-is -------
cp "$PKI/tmp/mqmon.p12" "$PKI/client/mqmon.p12"

# ---- Client kdb via runmqakm (inside the MQ server image) ---------------------
# Kept as the documented alternative: a CMS kdb has a stash file (.sth) so no
# password has to be passed to the exporter, at the price of needing runmqakm.
docker run --rm --user "$UIDGID" -e HOME=/tmp -e KDB_PW="$KDB_PW" \
  -v "$PKI/tmp:/work" -v "$PKI/client:/out" -v "$PKI/client-nocert:/out2" \
  --entrypoint sh "$MQ_IMAGE" -euc '
  export PATH=$PATH:/opt/mqm/bin
  runmqakm -keydb -create -db /out/key.kdb -pw "$KDB_PW" -type cms -stash
  runmqakm -cert -add    -db /out/key.kdb -stashed -label e2eca -file /work/ca.crt -format ascii -trust enable
  runmqakm -cert -import -file /work/mqmon-legacy.p12 -pw "$KDB_PW" -type pkcs12 \
           -target /out/key.kdb -target_stashed -label mqmon -new_label mqmon
  echo "--- client keystore contents ---"
  runmqakm -cert -list -db /out/key.kdb -stashed

  # Second keystore that trusts the CA but holds no personal certificate. Used by
  # verify.sh to prove the queue manager refuses a client without a certificate.
  runmqakm -keydb -create -db /out2/key.kdb -pw "$KDB_PW" -type cms -stash
  runmqakm -cert -add    -db /out2/key.kdb -stashed -label e2eca -file /work/ca.crt -format ascii -trust enable
'

chmod 644 "$PKI"/client/* "$PKI"/client-nocert/*
rm -rf "$PKI/tmp"
echo "PKI generated under $PKI"
