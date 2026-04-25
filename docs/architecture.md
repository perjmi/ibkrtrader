# ibkrtrader architecture

Multi-strategy trading platform on a single IBKR account.

## Problem

Run N independent algorithmic trading strategies against one Interactive Brokers
account, with shared risk controls, broker-truth reconciliation, and operator
visibility — deployed by a single Helm chart.

## Hard constraints (the IBKR truths everything else flows from)

1. **Positions aggregate at the account level.** IBKR has no concept of "strategy
   A's 100 SPY." If A buys 100 and B sells 30, the broker sees +70. `clientId`
   isolates *order modification rights*; `orderRef` is a free-form label. Real
   per-strategy isolation requires separate IBKR accounts.
2. **One Gateway, up to 32 client connections.** Multiple strategy processes
   share one Gateway via unique `clientId`. Two Gateways for the same login race
   and the account locks out.
3. **Historical-data pacing kills you first.** 60 requests / 10-min rolling
   window, 5-minute lockout on breach. Stagger startup, cache locally.
4. **100 market-data lines** shared across all clients on the account. Subscribe
   once at the gateway, fan out via the bus.
5. **`nextValidId` is account-scoped.** Multiple clients must coordinate IDs or
   range-partition them.
6. **Daily restart of TWS/Gateway is mandatory.** Weekly 2FA tap on Sunday 01:00
   ET. GTC orders survive Gateway restart only if `transmit=True`.
7. **Subscriptions don't auto-resume on reconnect.** `reqPositions`,
   `reqAccountUpdates`, market-data — all must be re-issued.

These are the load-bearing facts. Every component below exists because of one of
them.

## Topology

```
┌─────────────────── one Helm release ───────────────────────┐
│                                                            │
│  Next.js dashboard ──SSE──► API svc                       │
│                              │                             │
│  Strategy pods (1 Deployment per entry in values.yaml):    │
│      meanrev-spx (clientId=11) ──┐                        │
│      pairs-energy (clientId=12) ─┤                        │
│      vol-carry    (clientId=13) ─┤                        │
│                                  │                        │
│                                  ▼ POST /orders            │
│                         ┌─────────────────┐                │
│                         │ Risk Gateway    │ ◄─── HALT flag │
│                         │ (in-path)       │                │
│                         │ - fat-finger    │                │
│                         │ - max position  │                │
│                         │ - max notional  │                │
│                         │ - rate limit    │                │
│                         │ - daily loss    │                │
│                         └────────┬────────┘                │
│                                  │                         │
│                                  ▼                         │
│                         ┌─────────────────┐                │
│                         │ IBGW StatefulSet│                │
│                         │ replicas=1      │                │
│                         │ gnzsnz/ib-gw    │                │
│                         │ + IBC + Xvfb    │                │
│                         └────────┬────────┘                │
│                                  │                         │
│                                  ▼                         │
│                            IBKR servers                    │
│                                                            │
│  All components pub/sub on NATS JetStream:                 │
│      orders.<strategy>.<symbol>                            │
│      fills.<account>.<symbol>                              │
│      marketdata.<feed>.<symbol>                            │
│      risk.events.<severity>                                │
│                                                            │
│  Risk Monitor (leader-elected x2)                          │
│      subscribes fills.* + pnl.*                            │
│      on breach: flips HALT, cancels open orders,           │
│      `kubectl scale --replicas=0` the offender             │
│                                                            │
│  Timescale (CNPG)  ◄── fills, pnl_ticks, order_events     │
│  Loki              ◄── ops logs (30d)                      │
│  Prometheus + AM   ◄── /metrics                            │
└────────────────────────────────────────────────────────────┘
```

## Components

### IBKR Gateway

- **Image:** `ghcr.io/gnzsnz/ib-gateway:stable`. Bundles JVM + Xvfb + IBC.
- **Workload:** `StatefulSet` with `replicas: 1`. Never a Deployment — rolling
  updates would briefly run two pods racing for the same login. `volumeClaimTemplates`
  for `/home/ibgateway/Jts` (settings + jts.ini).
- **Ports:** 4001 (live), 4002 (paper), 5900 (VNC for emergencies).
- **2FA:** IBKey on a phone you own. Set `AUTO_RESTART_TIME` so the gateway
  restarts within the existing session window without prompting fresh 2FA.
  Sunday 01:00 ET requires a real tap; pair with a phone alarm.
- **Probes:** Readiness via TCP socket on the API port with
  `initialDelaySeconds: 120` (cold boot is slow). Liveness checks the same
  socket but with longer timeouts to avoid restarts during IBKR brownouts.
- **Paper vs live:** two separate StatefulSets (`ibgw-paper`, `ibgw-live`) so
  both can coexist. `Values.ibkr.mode` selects which one strategies point at.
- **Future:** migrate to IBKR Web API + OAuth 2.0 once your OMS adapter
  supports it. Removes Xvfb, IBC, and the daily restart entirely.

### Strategies

- **Image per strategy.** Roll back one strategy without touching others.
- **Deployment per strategy.** Generated by a single Helm template that
  iterates `.Values.strategies`. Each entry has its own image, `clientId`,
  config, and risk limits.
- **Process model:** one strategy = one container = one IBKR client connection
  via unique `clientId`. Per-strategy resource limits enforced at the
  container level; an OOM in strategy A cannot affect strategy B.
- **Embedding Nautilus Trader is the recommended path** — it ships the OMS,
  RiskEngine, Cache, Portfolio, IBKR adapter, and reconciliation primitives
  this design otherwise requires you to build. v0 chart leaves the strategy
  image as a placeholder; v1 adopts Nautilus.

### Risk Gateway (in-path)

- **Synchronous chokepoint.** Every order goes `strategy → POST /orders → gateway → IBKR`.
  Strategies cannot bypass it (no direct broker socket allowed in their pods —
  enforce with NetworkPolicy in v2).
- **Fail-closed.** If the gateway's own state DB is unreachable it returns 503.
  Strategies treat 503 as halt-and-alert, never as retry.
- **Pre-trade checks (v0 minimum):**
  - max order notional, fat-finger price band (recalibrated from intraday vol)
  - max position per strategy and per account
  - max daily loss per strategy and per account
  - max order rate / cancel rate per strategy
  - duplicate order detection (idempotency on `(strategy_id, client_order_id)`)
  - reduce-only enforcement
  - restricted/halted symbol blocklist
  - HALT flag check (per-strategy and global)
- **Latency:** ~200µs added per order — invisible at IBKR's 5–50ms broker RTT.
- **Reference:** SEC Rule 15c3-5 mandates exactly this topology for
  broker-dealers (single chokepoint nothing can route around). FIA 2024 white
  paper enumerates the standard check set.

### Risk Monitor (out-of-band)

- **Separate Deployment, replicas=2, leader-elected via K8s `Lease`.**
  Subscribes to `fills.*` and `pnl.*` on NATS, computes account-wide drawdown
  and exposure, evaluates the HALT conditions independently of the in-path
  gateway.
- **Trip actions:**
  1. Flip `HALT[strategy_id]` (or global `HALT_ALL`) in Redis — Risk Gateway
     reads on every order.
  2. Issue `cancelOrder` for all open orders matching the breaching strategy
     (filtered by `clientId` + `orderRef`).
  3. `kubectl scale deploy/strategy-<name> --replicas=0` via in-cluster RBAC.
- **Why both layers:** the in-path gateway catches per-order breaches
  synchronously. The monitor catches portfolio-level breaches that emerge from
  the *combination* of orders and fills. They have different failure modes and
  fail independently.

### Self-reconciling data plane

- **Source of truth: append-only event log** (`order_events` Timescale
  hypertable). Every broker callback (ack, fill, cancel, reject, position
  update, commission) is appended immediately and idempotently keyed by
  `(execId, orderId)`.
- **Projections** rebuild current positions and per-strategy PnL by replay.
  The shadow book — `(strategy_id, instrument) → qty` — is a projection.
- **Reconciliation loop** (every 5–10s):
  - Pull `reqAllOpenOrders`, `reqPositions`, `reqExecutions` snapshots.
  - Diff against the projection.
  - Drift → emit `ReconciliationDrift` event, alert, optionally HALT the
    affected symbol pending operator review.
- **Drift recovery classes:**
  | Class | Detection | Recovery |
  |---|---|---|
  | Phantom local position | Book has it, broker doesn't | Synthetic flatten into `UNATTRIBUTED`, halt strategies that touched the symbol |
  | Phantom broker position | Broker has it, book doesn't | Synthetic open into `UNATTRIBUTED`, alert |
  | Quantity mismatch | Sums disagree | Re-pull executions since last checkpoint, replay |
- **Daily statement reconciliation.** Pull the IBKR Flex Query at T+1, diff
  against the projection, alert on any discrepancy. This is the audit-grade
  truth.

### Event bus: NATS JetStream

- Single binary, ~50MB RAM, official Helm chart, NACK CRDs for declarative
  streams. Vastly more headroom than this platform needs.
- **Subjects:**
  - `orders.<strategy>.<symbol>` — order intent (publish for audit)
  - `fills.<account>.<symbol>` — broker-confirmed fills
  - `marketdata.<feed>.<symbol>` — gateway-fan-out ticks
  - `risk.events.<severity>` — HALTs, drift, alerts
  - `pnl.<strategy>` — per-strategy PnL ticks
- **Streams:** `ORDERS` (replay 7d), `FILLS` (replay forever, mirrored to S3),
  `MARKETDATA` (ephemeral), `RISK` (replay 30d).

### Storage

- **TimescaleDB on CloudNativePG** using `ghcr.io/clevyr/cloudnativepg-timescale:17`.
  Postgres ergonomics + hypertables. CNPG handles failover, PITR, scheduled
  S3 backup via CRD.
- Hypertables: `fills`, `pnl_ticks`, `positions_snapshot`, `order_events`,
  `marketdata_bars`.
- Plain tables: `strategies`, `accounts`, `risk_limits`, `instruments`.
- ClickHouse added later only if backtest analytics over years of bars
  becomes a bottleneck.

### Dashboard

- **Next.js (App Router)** + shadcn/ui. Server components for static pages,
  client components for live PnL.
- **API service: FastAPI.** Reads from Postgres for history, subscribes to
  NATS for live events, fans out to browsers via SSE.
- **SSE not WebSocket** for telemetry — one-way, survives proxies,
  auto-reconnects, no socket.io. WebSocket only if browser → server commands
  are needed (manual flatten button), and even then keep telemetry on SSE.

### Observability

- **Metrics:** kube-prometheus-stack. Strategies expose `/metrics` via
  `prometheus_client`.
- **Logs:** Loki, 30d retention, S3/MinIO backend. *Trading audit data is not
  a logging concern* — it lives in `order_events` with retention forever and
  CNPG → S3 with object-lock.
- **Alerts that earn their keep:**
  - `rate(fills_total[5m]) == 0 AND open_orders > 0` for 2m → page
  - `account_drawdown_pct > maxDrawdown` → page + auto-trip global HALT
  - `up{job="ib-gateway"} == 0` → page
  - `time() - ibkr_last_heartbeat_seconds > 30` → page (TCP up, API silent)
  - `reconciliation_drift_total > 0` for 1m → page
  - Risk Gateway and Risk Monitor both unhealthy → critical page

### Auth

- **Homelab:** Tailscale Kubernetes Operator. Tailnet identity is the auth.
  No login screen.
- **Small team:** Authelia OIDC behind nginx-ingress.

### Secrets

- **Homelab:** SOPS + age, encrypted YAML in-repo.
- **Small team:** External Secrets Operator → AWS Secrets Manager / 1Password.
- **Vault is overkill** unless there's a dedicated platform person.

## Helm chart layout

One umbrella chart, strategies generated from a values list:

```
helm/ibkrtrader/
├── Chart.yaml                    # deps: nats, cloudnative-pg
├── values.yaml                   # full default surface
├── values.paper.yaml             # paper-mode overrides
├── values.live.yaml              # live-mode overrides
├── values.schema.json            # type-validate values
├── templates/
│   ├── _helpers.tpl              # naming, labels, clientId uniqueness check
│   ├── NOTES.txt
│   ├── ibgateway-statefulset.yaml
│   ├── ibgateway-service.yaml
│   ├── ibgateway-secret.yaml
│   ├── strategy-deployment.yaml  # range over .Values.strategies
│   ├── strategy-configmap.yaml
│   ├── risk-gateway-*.yaml
│   ├── risk-monitor-*.yaml       # + RBAC for SIGKILL
│   ├── api-*.yaml
│   ├── dashboard-*.yaml
│   ├── timescale-cluster.yaml    # CNPG Cluster CR
│   ├── nats-streams.yaml         # JetStream Stream CRs
│   └── servicemonitors.yaml
└── charts/                       # populated by `helm dep update`
```

Adding a strategy = a PR to `values.yaml`. No new chart, no new template.

## Roadmap

- **v0 (this commit):** Helm chart skeleton — IBGW STS, Postgres+Timescale,
  NATS, placeholder images for strategies / risk-gateway / risk-monitor /
  api / dashboard. Goal: `helm install` brings up the topology in kind.
- **v1:** Embed Nautilus in the strategy base image. Risk Gateway implementing
  the 8 table-stakes pre-trade checks. Basic SSE PnL dashboard.
- **v2:** Risk Monitor with leader election + SIGKILL. Full reconciliation
  loop with drift handling. Tailscale exposure. NetworkPolicies.
- **v3:** IBKR Web API + OAuth migration. ClickHouse for backtest analytics.
  Multi-account isolation if you outgrow the shadow book.

## What this design explicitly is not

- **Not HFT.** Latency budget is set by IBKR's 5–50ms broker RTT, not by us.
  Aeron / LMAX Disruptor / kernel-bypass are wrong tools for this scale.
- **Not multi-broker.** A `BrokerAdapter` interface is the right abstraction
  for a future Alpaca/Tradier/CCXT addition, but v0 is IBKR-only.
- **Not horizontally scalable past one account per Gateway.** The IBKR
  connection model is the bottleneck and that's fine — when you need more
  isolation than the shadow book provides, the answer is more accounts +
  more Gateways, not more replicas.
