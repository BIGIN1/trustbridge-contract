# Event Indexing Guide

This document describes how to reliably consume TrustBridge contract events for dashboards, indexers, and analytics pipelines. It covers event structure, domain separation, idempotency, replay handling, and operational patterns.

---

## Event Reference

All contract events are defined in [`src/events.rs`](../src/events.rs) with `#[contractevent]` attributes. Each event includes:

- A **topic** (the first field marked `#[topic]`) for filtering via RPC `getEvents`
- Event-specific **data fields**
- An **`EventDomain`** envelope (most events) for deployment identification

### Events Emitted by the Contract

| Event | Topic Symbol | Key Data Fields | Domain? |
|---|---|---|---|
| `RegisteredEvent` | `registered_event` | `github_username`, `stellar_address`, `timestamp`, `sponsor` | ❌ |
| `RemovedEvent` | `removed_event` | `github_username`, `stellar_address`, `timestamp` | ✅ |
| `VerifiedEvent` | `verified_event` | `github_username`, `stellar_address`, `timestamp` | ✅ |
| `VerificationRevokedEvent` | `verification_revoked_event` | `github_username`, `stellar_address`, `timestamp`, `reason_code` | ✅ |
| `UpgradedEvent` | `upgraded_event` | `new_wasm_hash`, `version`, `timestamp` | ✅ |
| `PausedEvent` | `paused_event` | `admin`, `timestamp`, `reason_code` | ✅ |
| `UnpausedEvent` | `unpaused_event` | `admin`, `timestamp`, `reason_code` | ✅ |
| `RoleGrantedEvent` | `role_granted_event` | `address`, `role`, `admin`, `timestamp` | ✅ |
| `RoleRevokedEvent` | `role_revoked_event` | `address`, `admin`, `timestamp` | ✅ |
| `BatchRemoveProposedEvent` | `batch_remove_proposed_event` | `proposed_by`, `count`, `timestamp` | ✅ |
| `BatchRemoveExecutedEvent` | `batch_remove_executed_event` | `executed_by`, `proposed_by`, `count`, `successful`, `timestamp` | ✅ |
| `BatchRemoveCancelledEvent` | `batch_remove_cancelled_event` | `cancelled_by`, `proposed_by`, `timestamp` | ✅ |
| `ChallengeStartedEvent` | `challenge_started_event` | `github_username`, `challenged_by`, `resolve_after`, `timestamp` | ✅ |
| `ChallengeCancelledEvent` | `challenge_cancelled_event` | `github_username`, `cancelled_by`, `timestamp` | ✅ |
| `ChallengeCompletedEvent` | `challenge_completed_event` | `github_username`, `completed_by`, `timestamp` | ✅ |
| `EmergencyPausedEvent` | `emergency_paused_event` | `triggered_by`, `timestamp` | ❌ |
| `EmergencyClearedEvent` | `emergency_cleared_event` | `admin`, `timestamp` | ❌ |
| `UpgradeAttestedEvent` | `upgrade_attested_event` | `wasm_hash`, `expires_at`, `timestamp` | ❌ |
| `AttestationClearedEvent` | `attestation_cleared_event` | `wasm_hash`, `expires_at`, `timestamp` | ❌ |
| `RotationRequestedEvent` | `rotation_requested_event` | `github_username`, `current_address`, `new_address`, `executable_at`, `timestamp` | ❌ |
| `RotationExecutedEvent` | `rotation_executed_event` | `github_username`, `old_address`, `new_address`, `timestamp` | ❌ |
| `RotationCancelledEvent` | `rotation_cancelled_event` | `github_username`, `cancelled_by`, `timestamp` | ❌ |
| `VerificationConfiguredEvent` | `verification_configured_event` | `admin`, `attestation`, `expires_in`, `threshold`, `timestamp` | ❌ |
| `RenamedEvent` | `renamed_event` | `old_username`, `new_username`, `stellar_address`, `verification_cleared`, `timestamp` | ❌ |
| `RoleGrantPendingEvent` | `role_grant_pending_event` | `address`, `role`, `admin`, `activate_at`, `timestamp` | ❌ |
| `RoleGrantCancelledEvent` | `role_grant_cancelled_event` | `address`, `admin`, `timestamp` | ❌ |
| `GuardianChangedEvent` | `guardian_changed_event` | `guardian`, `admin`, `timestamp` | ❌ |

> **Note:** `RoleRevokedEvent` does **not** include the `role` field in its data payload. If your indexer needs to know which role was revoked, correlate the revocation with the most recent `RoleGrantedEvent` for that address.

---

## Event Domain Separation (Issue #226)

Every event that carries an `EventDomain` includes this struct:

```rust
pub struct EventDomain {
    pub contract_id: Address,      // Contract instance address (C...)
    pub network_id: BytesN<32>,    // SHA-256 of network passphrase
    pub contract_version: (u32, u32, u32),  // Semantic version at emit time
    pub domain_version: u32,       // Envelope schema version (currently 1)
}
```

### Why Domain Separation Matters

1. **Redeploy collisions**: Without `contract_id`, an indexer cannot distinguish events from a fresh deployment vs. a re-read of historical events from the same contract address on a different network.

2. **Cross-network mixing**: The same Stellar keypair works on testnet, futurenet, and public network. The `network_id` (SHA-256 of the passphrase) disambiguates which network an event belongs to.

3. **Upgrade attribution**: `contract_version` lets consumers know which contract logic produced the event — important if an upgrade changes event semantics.

### Indexer Deduplication Key

The **primary deduplication key** for any TrustBridge event should be:

```
(contract_id, network_id, ledger_sequence, tx_hash, event_index)
```

Where:
- `contract_id` + `network_id` = `EventDomain` identity
- `ledger_sequence` + `tx_hash` = transaction that emitted the event (from RPC envelope)
- `event_index` = zero-based position within that transaction's event list (required because `batch_verify`/`batch_remove` emit multiple same-topic events in one transaction)

This composite key is stable across:
- Redeploys (different `contract_id`)
- Network migrations (different `network_id`)
- Contract upgrades (different `contract_version`)
- RPC replays and catch-up reads (same `tx_hash` + `event_index`)

### Network ID Reference

| Network | Passphrase | SHA-256 (hex) |
|---|---|---|
| Public Network | `Public Global Stellar Network ; September 2015` | `7ac33997...` |
| Testnet | `Test SDF Network ; September 2015` | `7e10462a...` |
| Futurenet | `Test SDF Future Network ; October 2022` | `6c07a43f...` |

> The contract computes `network_id` via `env.ledger().network_id()` at `initialize` and on every event emission — no operator configuration required.

---

## Consuming Events via RPC

### Recommended: `stellar rpc getEvents`

Filter by contract ID and optionally by topic:

```bash
# All events for a contract
curl -X POST https://soroban-testnet.stellar.org \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "getEvents",
    "params": {
      "filters": [{ "type": "contract", "contractIds": ["C..."], "topics": [] }],
      "pagination": { "limit": 100 }
    }
  }'

# Only verification events
curl -X POST https://soroban-testnet.stellar.org \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "getEvents",
    "params": {
      "filters": [{ "type": "contract", "contractIds": ["C..."], "topics": [["verified_event"]] }],
      "pagination": { "limit": 100 }
    }
  }'
```

### Response Shape

Each event in the RPC response contains:

```json
{
  "id": "0001000042-0000000001",
  "ledger": 1000042,
  "ledgerClosedAt": "2026-01-15T12:00:05Z",
  "contractId": "CAAA...",
  "txHash": "a1b2c3...",
  "type": "contract",
  "topic": ["d213...", "..."],  // base64 XDR of topic symbols
  "value": "AQAA...",           // base64 XDR of event data
  "inSuccessfulContractCall": true
}
```

### Decoding Topic & Value

The `topic` and `value` fields are base64-encoded XDR. Decode with:

```bash
# Decode topic (symbol array)
stellar xdr decode --type scVec <base64_topic>

# Decode value (event struct)
stellar xdr decode --type <EventType> <base64_value>
```

Or use the Soroban SDK in your language of choice — the `contractevent` macro generates XDR definitions.

---

## Reference Indexer Implementation

The repo includes a production-ready reference indexer at [`scripts/event_indexer.sh`](../scripts/event_indexer.sh). It:

1. Polls `getEvents` on a loop (configurable interval)
2. Appends events as JSONL to `.indexer/events-<network>.jsonl`
3. Persists the RPC cursor to `.indexer/cursor-<network>.json` after every batch
4. Deduplicates on RPC event `id` using `.indexer/seen-<network>.txt`
5. Handles empty windows, RPC errors (linear backoff), and pruned cursors (cold re-scan fallback)

### Running the Indexer

```bash
# Follow testnet from ~1 day back, forever
CONTRACT_ID=C... ./scripts/event_indexer.sh

# Drain to head once and exit (cron / CI)
CONTRACT_ID=C... ONESHOT=1 ./scripts/event_indexer.sh

# Local / futurenet RPC, explicit start ledger
CONTRACT_ID=C... RPC_URL=http://localhost:8000/soroban/rpc \
  START_LEDGER=1 ONESHOT=1 ./scripts/event_indexer.sh

# Offline: replay a canned RPC response
MOCK_RESPONSE=./scripts/testdata/getEvents.sample.json \
  CONTRACT_ID=C_MOCK ONESHOT=1 ./scripts/event_indexer.sh
```

### Output Format

Each line of `events-<network>.jsonl`:

```json
{
  "id": "0001000042-0000000001",
  "ledger_sequence": 1000042,
  "ledger_closed_at": "2026-01-15T12:00:05Z",
  "contract_id": "CAAA...",
  "tx_hash": "a1b2c3...",
  "type": "contract",
  "topic": ["<base64 xdr>", "..."],
  "value": "<base64 xdr>",
  "in_successful_contract_call": true,
  "indexed_at": "2026-08-29T00:00:00Z"
}
```

The script is deliberately **decode-agnostic** — it stores raw XDR so consumers can decode with their preferred tooling.

---

## Idempotency & Replay Handling

Horizon/RPC replays and worker retries are **normal operating conditions**, not failure modes. An indexer that treats every delivery as new will double-count registrations or resurrect a contributor after they were removed.

### Idempotency Key

Key every stored event on:

```
(github_username, event_type, ledger_sequence, tx_hash)
```

- `event_type` — the event's topic symbol (`registered_event`, `verified_event`, etc.)
- `ledger_sequence` — the ledger the event was emitted in (ordering key)
- `tx_hash` — the transaction hash that emitted it (distinguishes same-type events in same ledger)

`(ledger_sequence, tx_hash)` alone is sufficient to deduplicate a single delivery; `github_username` and `event_type` are included so a lookup by contributor doesn't require a join.

### Event → Action → Duplicate Handling

| Event | Expected Indexer Action | Duplicate Delivery |
|-------|------------------------|---------------------|
| `RegisteredEvent` | Upsert `(github_username → stellar_address)`; reset local `verified` to `false` | No-op — same key already applied |
| `VerifiedEvent` | Set local `verified = true` for `github_username` | No-op if key already applied |
| `VerificationRevokedEvent` | Set local `verified = false` for `github_username` | Same — idempotent overwrite |
| `RemovedEvent` | Delete (or tombstone) the local record for `github_username` | No-op if already deleted |

**Critical**: Never implement indexer-side counters (e.g. "times verified") by counting event occurrences. Use `get_stats()` / `get_public_paginated` reads against the contract as the source of truth for aggregate counts.

### Out-of-Order Handling

Horizon delivery order is not guaranteed to match ledger order under replay or catch-up conditions. Two rules keep out-of-order delivery from producing the wrong final state:

1. **Order by `(ledger_sequence, tx_hash-relative-order)` before applying**, not by delivery order. If a `RemovedEvent` and a later `RegisteredEvent` for the same username arrive out of order, applying them in delivery order instead of ledger order can leave the record deleted when it should exist (or vice versa).

2. **Track the last-applied `ledger_sequence` per `github_username`.** Before applying an event, compare its `ledger_sequence` to the last one recorded for that username. If the incoming event is older, it is a gap-fill or a late replay of something already superseded — record it for audit purposes but do not let it overwrite newer state.

For gaps (a missing ledger range in the delivery stream), reconcile against on-chain state directly rather than waiting for the missing event: call `get_public_paginated` (or `get_address` for a single username) and treat its result as authoritative. The event stream is a change-notification optimization; the contract's own storage is always the ground truth.

### Stable Event ID (Issue #283)

For consumers that want a single opaque id per event, derive it deterministically from the delivery envelope:

```
event_id = "{network_id}:{contract_id}:{ledger_sequence}:{tx_hash}:{event_index}"
```

- `network_id` — lower-hex SHA-256 of the network passphrase (same value as `domain.network_id`)
- `contract_id` — the emitting contract's `C...` address (`domain.contract_id`)
- `ledger_sequence` — ledger the event was emitted in
- `tx_hash` — hex transaction hash that emitted it
- `event_index` — zero-based position of this event within that transaction's event list

**Algorithm for a consumer:**
1. On each delivery, compute `event_id`.
2. If `event_id` is already in the applied-set, drop the delivery — it is a reconnect replay, a catch-up re-read, or a worker retry. Do nothing else.
3. Otherwise apply the event (last-write-wins field/record update, never an increment), then record `event_id` in the applied-set.
4. A full re-sync of the entire stream is therefore a no-op once every id has been seen.

**Uniqueness scope**: one contract instance on one network. `network_id` and `contract_id` are baked into the id, so it never collides across a redeploy or another network.

---

## Lag Detection (Issue #282)

The contract exposes `get_last_event_ledger() -> u32` returning the ledger sequence containing the most recently emitted contract event (`0` = no events yet). The value is stored in instance storage and updated atomically with every event emission.

### Indexer Lag Detection Loop

```python
watermark = highest ledger fully applied in the indexer's database

while True:
    last = contract.get_last_event_ledger()  # one cheap instance-storage read
    if watermark < last:
        events = rpc.getEvents(startLedger=watermark+1, endLedger=last, filters=[...])
        apply_events_in_order(events)
        watermark = last
        commit_database_transaction()
    else:
        # no known lag; indexer is current
        sleep(poll_interval)
```

**Rules:**
1. Advance `watermark` only **after** the database transaction commits. A crash between fetching and committing is safe to replay because applying an already-applied event is idempotent.
2. If `watermark >= last_event_ledger`, the indexer has no known contract lag. Network-level latest-ledger is a separate Horizon/RPC concept; this signal is contract-local only.
3. The signal is readable **while paused**, so a paused registry can still be reconciled without first unpausing.

**Constraints:**
- The value is a ledger **sequence**, not a timestamp. Compare it against the `ledgerSeq` field in Horizon event envelopes, not the `timestamp` in event payloads.
- The contract cannot read its own Horizon latest-ledger. A gap of `latest_horizon_ledger - last_event_ledger` ledgers means no contract event was emitted in that range — not necessarily that the indexer is current with the chain tip.
- For high-throughput periods, one Horizon `getEvents` call may not return all events between `watermark` and `last`; paginate using the Horizon cursor as usual.

---

## Public Pagination for Dashboards (Issue #1, #3, #294)

For dashboard/indexer reads that don't need admin auth, use `get_public_paginated`:

- **Unauthenticated** — no auth required
- **Available while paused** — the pause circuit breaker stops state mutations only
- **Bounded limits** — `MAX_PAGE_LIMIT = 100`, `DEFAULT_PAGE_LIMIT = 20`
- **Chunk-backed** — reads from persistent chunked index, not the flat instance-storage index, so cost is O(page_size) not O(registry_size)
- **Opaque cursors** — same encoding as admin `get_registered_paginated`; cursors embed index generation for invalidation on removal (Issue #215)

```bash
# Page 1
stellar contract invoke --id $CONTRACT_ID -- get_public_paginated --limit 50

# Page 2 (use cursor from previous response)
stellar contract invoke --id $CONTRACT_ID -- get_public_paginated --cursor <cursor> --limit 50
```

See [DASHBOARD_SYNC.md](DASHBOARD_SYNC.md#paginated-registry-reads-wave-41--issue-143) for details.

---

## Pending Re-verification (Issue #208)

When a verified contributor re-registers to a **different** Stellar address:
1. The contract clears their `verified` flag and decrements the verified count
2. Sets a `pending_reverify` flag for that username

### Reading Pending Re-verification State

| Endpoint | Use |
|---|---|
| `get_pending_reverify(github_username)` | Check a single username — returns `bool` |
| `get_pending_reverify_page(offset, limit)` | Paginated scan — returns `Vec<String>` of usernames with the flag set |

### Dashboard Sync Workflow

1. **On `RegisteredEvent`** where old and new `stellar_address` differ, call `get_pending_reverify(username)` to confirm the flag was set. Queue the contributor for a re-verification workflow.
2. **On `VerifiedEvent`**, the flag is cleared automatically — no additional call needed.
3. **Periodic reconciliation**: Call `get_pending_reverify_page(0, 100)` to build the full list of contributors awaiting re-check.

---

## Health & Monitoring Endpoints

| Endpoint | Auth | Paused? | Purpose |
|---|---|---|---|
| `get_last_event_ledger()` | None | ✅ | Lag detection watermark |
| `get_health()` | None | ✅ | Aggregate health snapshot (paused, version, counts, cooldown, attestation) |
| `get_stats()` | None | ✅ | `{ total, verified, ever_verified }` |
| `get_public_paginated()` | None | ✅ | Chunk-backed paginated registry read |
| `has_record(username)` | None | ✅ | O(1) existence check without deserialization |
| `get_pending_reverify(username)` | None | ✅ | Single re-verification flag check |

All are read-only, require no auth, and work while the contract is paused.

---

## Related Documentation

- [DASHBOARD_SYNC.md](DASHBOARD_SYNC.md) — Dashboard & indexer sync patterns, idempotency tables, dual-index audit
- [ABI.md](ABI.md) — Complete function, event, and error reference
- [ARCHITECTURE.md](ARCHITECTURE.md) — Storage layout, auth model, event design
- [STORAGE_RENT.md](STORAGE_RENT.md) — TTL economics, keeper checklist
- [scripts/event_indexer.sh](../scripts/event_indexer.sh) — Reference indexer implementation
- [tests/event_replay.rs](../tests/event_replay.rs) — Replay test fixture and assertions
- [tests/testdata/event_replay_fixture.json](../tests/testdata/event_replay_fixture.json) — Language-neutral replay fixture