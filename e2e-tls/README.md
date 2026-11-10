# TLS end-to-end test: mq_prometheus and mq_otel against a containerised queue manager

Two containers, one network, no passwords: the exporter authenticates to the
queue manager with a client certificate only.

```
gen-certs.sh                      docker compose                    verify.sh
   |                                   |                                 |
   | openssl (alpine/openssl)          | qm1: icr.io/ibm-messaging/mq   | put msgs (amqsput)
   |   CA, QM1 cert, mqmon cert        |   PEM -> /etc/mqm/pki/...       | scrape :9157
   |   mqmon.p12 (key+cert+CA)         |   30-monitor.mqsc               | DIS CHSTATUS
   | runmqakm (MQ server image)        | exporter: ghcr.io/anael-l/...   | negative test
   |   key.kdb (+ CA-only kdb/p12)     |   CCDT + MQSSLKEYR + MQKEYRPWD  | otel image (stdout)
   | runmqsc -n (MQ server image)      |                                 | ... per scenario
   |   AMQCLCHL.TAB                    |                                 |
   v                                   |                                 |
  pki/                                 v                                 v
```

## Scenarios

| Scenario   | CCDT                                         | Key repository                                   |
|------------|----------------------------------------------|--------------------------------------------------|
| `ccdt-p12` | JSON, `config/ccdt.json`                     | PKCS#12 `mqmon.p12`, password in `MQKEYRPWD`     |
| `tab-kdb`  | binary, `pki/client/AMQCLCHL.TAB`            | CMS `key.kdb` + `key.sth` stash, no password     |

verify.sh runs each scenario against both images (mq_prometheus and mq_otel)
and prints a PASS/FAIL line per scenario per collector at the end; it exits
non-zero if any fails. Per scenario it checks: connection, `DIS CHSTATUS`
(cipher, `SSLPEER` with `CN=mqmon`, `MCAUSER(mqmon)`), queue depth and other
metrics, no authority failures, refusal of a CA-only keystore of the same
format, and the OTel image's exported metrics. The `tab-kdb` runs do not mount
`ccdt.json` at all, so the TAB is the only CCDT the client can find.

## Run

```bash
./verify.sh --fresh             # gen-certs.sh + qm1 + both scenarios
SCENARIO=tab-kdb ./verify.sh    # one scenario (ccdt-p12 or tab-kdb), PKI already generated
docker compose down -v
```

verify.sh starts `qm1` itself and runs its own exporter containers (one per
scenario), removing the compose `exporter` if it is up. To just run the stack
by hand: `./gen-certs.sh && docker compose up -d` gives `ccdt-p12`;
`CCDT_URL=file:///opt/config/ssl/AMQCLCHL.TAB MQSSLKEYR=/opt/config/ssl/key docker compose up -d`
gives `tab-kdb`.

`EXPORTER_IMAGE=...` overrides the Prometheus exporter image for verify.sh and
compose; `OTEL_IMAGE=...` the OTel image run by verify.sh (`ghcr.io/anael-l/mq-metric-otel:master`);
`MQ_IMAGE=...` the queue manager image for gen-certs.sh and compose, e.g.
`MQ_IMAGE=icr.io/ibm-messaging/mq:9.4.5.1-r1 ./verify.sh --fresh` to test
against an MQ 9.4 queue manager.

## How the pieces fit

- **Queue manager**: the mq-container image builds its keystore from PEM files
  mounted at `/etc/mqm/pki/keys/qm1` (identity) and `/etc/mqm/pki/trust/0`
  (the CA that signed the client cert). `mqsc/30-monitor.mqsc` is picked up
  automatically from `/etc/mqm` and defines:
  - `MON.SVRCONN` with `SSLCAUTH(REQUIRED)` and `MCAUSER('nobody')`
  - a CHLAUTH `SSLPEERMAP` rule mapping `CN=mqmon,O=e2e` to user `mqmon`
  - an `ADDRESSMAP ... USERSRC(NOACCESS)` rule so nothing else gets in
  - the read-only `SET AUTHREC` list the collector needs
  - `MON.TEST.QUEUE`
- **Exporter**: `config/mq_prometheus.yaml` points `ccdtUrl` at
  `config/ccdt.json` (`ANY_TLS12_OR_HIGHER`, `certificateLabel: mqmon`).
  No `user`/`password` is configured. The container runs as uid 1001 with no
  passwd entry, as OpenShift would run it.
- **Binary CCDT**: `gen-certs.sh` writes `pki/client/AMQCLCHL.TAB` with
  `runmqsc -n` in the MQ server image (`MQCHLLIB`/`MQCHLTAB` set, a tmpfs on
  `/mnt/mqm` because `runmqsc -n` still wants a writable `/var/mqm`). It holds
  the same CLNTCONN as `ccdt.json`. `CERTLABL('mqmon')` must be quoted or MQSC
  folds it to `MQMON`. The collector reads it through `ccdtUrl`
  (`file:///opt/config/ssl/AMQCLCHL.TAB`, set by verify.sh with
  `IBMMQ_CONNECTION_CCDTURL`): the MQ 10 client accepts a binary TAB there.
  `MQCHLLIB`/`MQCHLTAB` also work, but only if `ccdtUrl` is absent from the
  YAML; an empty `IBMMQ_CONNECTION_CCDTURL` does not clear the YAML value.
- **Key repository**: `gen-certs.sh` packages the same client identity two ways:
  - `pki/client/mqmon.p12` (`ccdt-p12`). Plain OpenSSL 3 output, no MQ tooling.
    `MQSSLKEYR=/opt/config/ssl/mqmon.p12` and the password in `MQKEYRPWD`
    (exactly that name; `MQSSLKEYRPWD` is ignored). The p12 must contain the
    CA and its friendly name must equal `certificateLabel`. To keep the
    password out of the environment, put `SSLKeyRepositoryPassword` in an
    `mqclient.ini` SSL stanza (`MQCLNTCF=...`); `runmqicred` in the image can
    encrypt it.
  - `pki/client/key.kdb` (+ `.sth`) (`tab-kdb`). CMS key database built with
    `runmqakm`; the stash file means no password is needed.
    `MQSSLKEYR=/opt/config/ssl/key` (path without `.kdb`).
  - PEM files are **not** accepted as a key repository by the MQ 10 C client.
- **OTel collector**: verify.sh also runs the `mq_otel` image once per scenario with
  `config/mq_otel.yaml` (same connection block, empty `otel.endpoint` so the
  stdout exporter is used, `MQIGO_UNITTEST_MAX_LOOPS=3` so it exits) and
  checks the JSON it prints for the same queue depth and channel status.
- **Proof of TLS auth**: `DIS CHSTATUS(MON.SVRCONN)` shows the negotiated
  cipher, `SSLPEER(...CN=mqmon...)` and `MCAUSER(mqmon)`; the `$SYS/MQ`
  subscriptions are owned by `mqmon`; and a second run with a keystore that
  holds only the CA (`pki/client-nocert/ca.p12` or `key.kdb`, matching the
  scenario) is refused.

## Notes

- `pki/` is regenerated by `gen-certs.sh` and gitignored. Keys are chmod 644
  because the containers run as other uids. Test material only.
- The `metadataMap` entry in the YAML only takes effect with an exporter built
  from a recent upstream commit; older images ignore it.
- The kdb is built with `runmqakm` from the queue manager image. The exporter
  image (MQ 10 Redistributable Client) ships `runmqakm` too, but it fails with
  "Failed to dlopen ICU library". The p12 path needs no MQ tooling at all.
