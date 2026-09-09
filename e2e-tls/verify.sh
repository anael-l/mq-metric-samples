#!/usr/bin/env bash
# End-to-end check: the Prometheus exporter connects to the containerised
# queue manager over mutual TLS (PKCS#12 key repository by default, the CMS
# kdb is checked as well), is identified by its certificate, and reports
# real metrics. Also proves a client WITHOUT a certificate is refused, and that
# the OTel collector image connects the same way (stdout exporter).
#
# Usage:  ./verify.sh            (expects `docker compose up -d` already done)
#         ./verify.sh --fresh    (regenerates PKI, recreates the stack first)
set -uo pipefail
cd "$(dirname "$0")"

QM=mq-e2e-qm1
EXP=mq-e2e-exporter
IMAGE="${EXPORTER_IMAGE:-ghcr.io/anael-l/mq-metric-samples:master}"
OTEL_IMAGE="${OTEL_IMAGE:-ghcr.io/anael-l/mq-metric-samples:master-otel}"
METRICS=http://localhost:9157/metrics
NMSG=7
KDB_PW="${KDB_PW:-passw0rd}"
fail=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
nope() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
mqsc() { docker exec "$QM" sh -c "echo \"$1\" | runmqsc QM1" 2>&1; }

if [ "${1:-}" = "--fresh" ]; then
  docker compose down -v --remove-orphans >/dev/null 2>&1
  ./gen-certs.sh >/dev/null
  docker compose up -d
fi

echo "== 1. exporter connected over TLS"
for i in $(seq 1 30); do
  docker logs "$EXP" 2>&1 | grep -q "Connected to queue manager QM1" && break
  sleep 2
done
keyr=$(docker inspect "$EXP" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^MQSSLKEYR=//p')
if docker logs "$EXP" 2>&1 | grep -q "Connected to queue manager QM1"; then
  pass "exporter log reports connection to QM1 (MQSSLKEYR=$keyr)"
else
  nope "exporter never connected (MQSSLKEYR=$keyr)"; docker logs "$EXP" 2>&1 | tail -20
fi

echo "== 1b. the other key repository format connects too"
if [ "${keyr##*.}" = "p12" ]; then alt=/opt/config/ssl/key; altpw=; else alt=/opt/config/ssl/mqmon.p12; altpw="$KDB_PW"; fi
# mq_prometheus only counts collection loops when scraped, so run it detached
# and watch its log for the connection line rather than waiting for an exit.
docker rm -f mq-e2e-alt >/dev/null 2>&1
docker run -d --name mq-e2e-alt --user 1001:0 --network mq-e2e-tls_default \
  -e MQSSLKEYR="$alt" -e MQKEYRPWD="$altpw" -e IBMMQ_GLOBAL_LOGLEVEL=INFO \
  -e IBMMQ_PROMETHEUS_KEEPRUNNING=false \
  -v "$PWD/config/mq_prometheus.yaml:/opt/config/mq_prometheus.yaml:ro" \
  -v "$PWD/config/ccdt.json:/opt/config/ccdt.json:ro" \
  -v "$PWD/pki/client:/opt/config/ssl:ro" \
  "$IMAGE" >/dev/null
altok=0
for i in $(seq 1 20); do
  alog=$(docker logs mq-e2e-alt 2>&1)
  grep "Connected to queue manager" <<<"$alog" >/dev/null && { altok=1; break; }
  grep "level=error" <<<"$alog" >/dev/null && break
  sleep 3
done
if [ $altok = 1 ]; then
  pass "exporter also connects with MQSSLKEYR=$alt"
else
  nope "exporter failed with MQSSLKEYR=$alt"; grep 'level=' <<<"$alog" | tail -3
fi
docker rm -f mq-e2e-alt >/dev/null 2>&1

echo "== 2. channel status on the queue manager"
chs=$(mqsc "DIS CHSTATUS(MON.SVRCONN) SSLCIPH SSLPEER MCAUSER STATUS")
echo "$chs" | grep -q "STATUS(RUNNING)"            && pass "MON.SVRCONN is RUNNING"            || nope "MON.SVRCONN not running"
cipher=$(echo "$chs" | grep -o 'SSLCIPH([^)]*)')
[ -n "$cipher" ] && [ "$cipher" != "SSLCIPH( )" ]  && pass "TLS cipher negotiated: $cipher"    || nope "no TLS cipher on channel"
echo "$chs" | grep -q "CN=mqmon"                   && pass "peer certificate DN contains CN=mqmon" || nope "unexpected SSLPEER"
echo "$chs" | grep -q "MCAUSER(mqmon)"             && pass "identity mapped by CHLAUTH to MCAUSER(mqmon)" || nope "MCAUSER not mqmon"

echo "== 3. put $NMSG messages on MON.TEST.QUEUE and read them back through metrics"
mqsc "CLEAR QLOCAL(MON.TEST.QUEUE)" >/dev/null
for i in $(seq 1 $NMSG); do echo "e2e message $i"; done \
  | docker exec -i "$QM" /opt/mqm/samp/bin/amqsput MON.TEST.QUEUE QM1 >/dev/null
# Queue depth arrives via $SYS/MQ publications (10s interval) and object status
# polling; allow a couple of scrapes.
depth=""
for i in $(seq 1 12); do
  sleep 5
  depth=$(curl -s "$METRICS" | awk -F'[ ]' '/^ibmmq_queue_depth\{.*queue="MON.TEST.QUEUE"/ {print $NF}')
  [ "$depth" = "$NMSG" ] && break
done
[ "$depth" = "$NMSG" ] && pass "ibmmq_queue_depth{queue=MON.TEST.QUEUE} = $depth" || nope "queue depth is '$depth', expected $NMSG"

echo "== 4. general metric health"
m=$(curl -s "$METRICS")
echo "$m" | grep -q '^ibmmq_qmgr_status{.*} 2$'      && pass "ibmmq_qmgr_status = 2 (running)"      || nope "qmgr status not 2"
n=$(echo "$m" | grep -c '^ibmmq_')
[ "$n" -gt 50 ]                                      && pass "$n ibmmq_* samples exposed"          || nope "only $n ibmmq_* samples"
# CPU/RAM metrics exist only through the $SYS/MQ publications (every 10s), and a
# scrape only carries them if a publication arrived since the previous scrape.
pubok=0
for i in 1 2 3; do
  sleep 11
  m=$(curl -s "$METRICS")
  echo "$m" | grep -q '^ibmmq_qmgr_user_cpu_time_percentage' && { pubok=1; break; }
done
[ $pubok = 1 ] && pass "published resource metrics present (qmgr cpu)" || nope "no published resource metrics in 3 scrapes"
# Channel status is re-polled every pollInterval (10s); allow a couple of scrapes.
chok=0
for i in 1 2 3; do
  m=$(curl -s "$METRICS")
  echo "$m" | grep -q -E '^ibmmq_channel_status\{[^}]*channel="MON.SVRCONN"' && { chok=1; break; }
  sleep 6
done
[ $chok = 1 ] && pass "channel status metric for MON.SVRCONN present" || nope "no channel metric in 3 scrapes"

echo "== 5. no authority failures on the queue manager"
auth=$(docker exec "$QM" sh -c 'grep -h -c AMQ8077 /var/mqm/qmgrs/QM1/errors/AMQERR01.LOG 2>/dev/null; true')
[ "${auth:-0}" = "0" ] && pass "no AMQ8077 (insufficient authority) entries" || { nope "$auth AMQ8077 entries"; docker exec "$QM" grep -h -A4 AMQ8077 /var/mqm/qmgrs/QM1/errors/AMQERR01.LOG | head -30; }
subs=$(mqsc "DIS SUB(*) WHERE(TOPICSTR LK '\$SYS*') SUBUSER" | grep -c "SUBUSER(mqmon)")
[ "$subs" -gt 0 ] && pass "$subs \$SYS/MQ subscriptions owned by mqmon" || nope "no subscriptions owned by mqmon"

echo "== 6. negative: a client without a certificate must be refused"
out=$(docker run --rm --user 1001:0 --network mq-e2e-tls_default \
  -e MQSSLKEYR=/opt/config/ssl/key -e IBMMQ_GLOBAL_LOGLEVEL=INFO -e IBMMQ_PROMETHEUS_KEEPRUNNING=false \
  -v "$PWD/config/mq_prometheus.yaml:/opt/config/mq_prometheus.yaml:ro" \
  -v "$PWD/config/ccdt.json:/opt/config/ccdt.json:ro" \
  -v "$PWD/pki/client-nocert:/opt/config/ssl:ro" \
  "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q -E "MQRC_SSL_INITIALIZATION_ERROR|MQRC_HOST_NOT_AVAILABLE|MQRC_Q_MGR_NOT_AVAILABLE|MQRC_NOT_AUTHORIZED|MQRC_SSL"; then
  pass "connection refused without client certificate (exit $rc: $(echo "$out" | grep -o 'MQRC_[A-Z_]*' | sort -u | tr '\n' ' '))"
else
  nope "client without certificate was not refused (exit $rc)"; echo "$out" | tail -5
fi
reason=$(docker exec "$QM" sh -c 'grep -h -o -E "AMQ9637|AMQ9660|AMQ9631|AMQ9209" /var/mqm/qmgrs/QM1/errors/AMQERR01.LOG /var/mqm/errors/AMQERR01.LOG 2>/dev/null | sort -u | tr "\n" " "')
[ -n "$reason" ] && pass "queue manager logged the TLS rejection: $reason" || echo "  (no AMQ96xx entry found in error log; rejection happened client side)"

echo "== 7. OTel collector image: same TLS setup (p12), stdout exporter, 3 collections"
oout=$(timeout 120 docker run --rm --user 1001:0 --network mq-e2e-tls_default \
  -e MQSSLKEYR=/opt/config/ssl/mqmon.p12 -e MQKEYRPWD="$KDB_PW" \
  -e IBMMQ_GLOBAL_LOGLEVEL=INFO -e MQIGO_UNITTEST_MAX_LOOPS=3 \
  -v "$PWD/config/mq_otel.yaml:/opt/config/mq_otel.yaml:ro" \
  -v "$PWD/config/ccdt.json:/opt/config/ccdt.json:ro" \
  -v "$PWD/pki/client:/opt/config/ssl:ro" \
  "$OTEL_IMAGE" 2>&1); orc=$?
# No "grep -q" on the big otel output: with pipefail the early exit kills echo.
if [ $orc -eq 0 ] && grep "Connected to queue manager" <<<"$oout" >/dev/null; then
  pass "otel image connected over TLS and exited cleanly after 3 collections"
else
  nope "otel image failed (exit $orc)"; echo "$oout" | grep 'level=' | tail -5
fi
# Each collection is one JSON document on stdout (very long lines; docker may
# wrap them). Join everything after the first document and put one metric per line.
osplit=$(echo "$oout" | sed -n '/^{"Resource"/,$p' | tr -d '\n' | sed 's/{"Name":/\n{"Name":/g')
on=$(echo "$osplit" | grep -c '^{"Name":"ibmmq\.')
[ "$on" -gt 50 ] && pass "$on ibmmq.* metric entries exported" || nope "only $on ibmmq.* metric entries exported"
odepth=$(echo "$osplit" | grep '^{"Name":"ibmmq.queue.depth"' \
  | grep -o '"Value":"MON.TEST.QUEUE"}}[^]]*\],"StartTime":"[^"]*","Time":"[^"]*","Value":[0-9]*' | tail -1 | grep -o '[0-9]*$')
[ "$odepth" = "$NMSG" ] && pass "otel ibmmq.queue.depth{queue=MON.TEST.QUEUE} = $odepth" || nope "otel queue depth is '$odepth', expected $NMSG"
echo "$osplit" | grep '^{"Name":"ibmmq.channel.status"' | grep '"Value":"MON.SVRCONN"' >/dev/null \
  && pass "otel ibmmq.channel.status for MON.SVRCONN present" || nope "no otel channel status for MON.SVRCONN"

echo
if [ $fail -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $fail
