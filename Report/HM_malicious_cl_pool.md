# Medium Severity Finding — Malicious CL Pool Drains Gauge Emissions

## Summary
`GaugeManager.createGauge()` accepts any address as a concentrated-liquidity (CL) pool when `_gaugeType == 1`. The function verifies only that the pool’s tokens are whitelisted/connector-approved, then blindly calls `ICLPool(_pool).setGaugeAndPositionManager(...)`. A hostile actor can deploy a malicious pool contract that returns arbitrary data from `claimFees()` and routes every HYBR token emitted to the gauge into their own bribe. Honest LPs (and any voters backing the gauge) receive zero emissions while votes continue pointing at the compromised gauge.

## Impact
- All HYBR emissions destined for the malicious gauge are siphoned to the attacker each epoch.
- Liquidity providers and voters for that market never receive rewards, yet vote weights remain unchanged, so losses persist until governance intervenes.
- Theft is unbounded over time because the attacker can leave their malicious gauge active across epochs, continually capturing weekly HYBR distributions.
- The latest Code4rena PoC (`ve33/test/C4PoC.t.sol::test_submissionValidity`) simulates three honest voters expecting 16,666.67 HYBR from a 50,000 HYBR epoch emission. Every victim claims 0 HYBR while the attacker withdraws the full 50,000 HYBR from the internal bribe.

## Technical Root Cause
The `_createGauge()` helper in `GaugeManager.sol` lacks authenticity checks for CL pools:
- For `_gaugeType == 1`, it does not query any factory to ensure the pool was deployed by Hybra’s CL factory or that token ordering/liquidity invariants hold.
- After the weak whitelist check, it sets `isPair = true` and proceeds to deploy a CL gauge, then immediately trusts the pool via `ICLPool(_pool).setGaugeAndPositionManager(_gauge, nfpm);`.
- `GaugeCL.claimFees()` assumes the pool implements the expected fee-reporting interface. A malicious pool can report the gauge’s balance as “fees”, causing the gauge to forward its entire HYBR balance into the internal bribe contract.

## Attack Scenario
1. **Protocol preparation (legitimate governance/team actions):** HYBR and a secondary ERC20 are whitelisted in `TokenHandler`, and the secondary token is marked as a connector. Governance/Genesis roles are delegated to the team multisig so these actions mirror production permissions.
2. **Attacker:**
   - Deploys `MaliciousCLPoolHarness`, declaring HYBR and the whitelisted connector token as its asset pair.
   - Calls `gaugeManager.createGauge(address(maliciousPool), 1)`; the function succeeds because the minimal interface returns addresses matching the whitelist.
   - Locks HYBR to obtain voting power and directs votes to the malicious pool via `voter.vote()` once the epoch and voting window advance.
   - After the epoch roll, triggers `gaugeManager.distributeFees()` so HYBR emissions fund the gauge, then lets `GaugeCL.claimFees()` interact with the malicious pool. The pool reports the gauge’s HYBR balance as fees, forcing the gauge to transfer the entire emission stream into its internal bribe contract.
   - After the next epoch boundary, calls `gaugeManager.claimBribes()` to withdraw the stolen HYBR from the internal bribe.
3. **Result:** Every HYBR token emitted to that gauge is delivered to the attacker, while LPs and the protocol receive nothing. The victims’ claim attempts return zero payout because the bribe contract holds no rewards for their positions.

## Proof of Concept

The behavior is reproduced in the official submission harness `ve33/test/C4PoC.t.sol::test_submissionValidity`:

- A malicious pool passes the whitelist checks and registers a CL gauge.
- Three honest voters lock HYBR, vote for the gauge, and rightfully expect to share epoch emissions equally.
- `gaugeManager.distributeFees()` sends 50,000 HYBR emissions to the gauge. When the gauge executes `claimFees()`, the malicious pool tricks it into forwarding the full balance to the internal bribe.
- After the reward window, the attacker claims 50,000 HYBR while each victim’s `claimBribes()` call returns 0 HYBR. The test logs their expected payout versus the zero actual payout, asserting the aggregate loss equals the full emission amount.

```bash
forge test --match-test submissionValidity -vvv
```

Key log excerpts:

- `Victim 1 expected HYBR: 16666.666666666666666666`
- `Victim 1 actual HYBR: 0.000000000000000000`
- … (repeated for victims 2 and 3) …
- Attacker balance increase after claiming equals the entire 50,000 HYBR emission.

## Solution

Restrict CL gauges to pools deployed by the canonical CL factory so that arbitrary contracts cannot masquerade as pools.


