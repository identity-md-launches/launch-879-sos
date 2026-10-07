# SOS implementation review

This is the implementer's local review, not an independent audit. The revision
below responds to the supplied independent review findings; it does not attest
that those reviewers approved release. The supplied security and L2 references
were read as background; no deployment, network lookup, key access, or signing
was performed.

## Findings and disposition

| Concern | Disposition |
| --- | --- |
| Taxing launch funding, claims or sells causes a shortfall | Added immutable launch configuration, caller exemptions for factory/manager/distributor, and recipient exemption for the PoolManager. Real v4 settlement tests cover both direct and router transfers. |
| Dev recipient not specified | Explicit immutable constructor argument; no assumption that factory/deployer is Dev. Operator must resolve the intended wallet. |
| A self-transfer or transfer from Dev could reuse fee credits to exceed the holder's balance | Gross amount checked before any balance update. Regression tests cover Dev, recipient aliasing, and amounts exceeding supply. |
| Gross allowance could be confused with the net payout | Inherited OpenZeppelin allowance checks run on the original amount; tested failure rollback, finite allowances, unlimited allowances, and revocation. Exempt callers never bypass approval. |
| Fee recursion, supply growth, or privileged seizure | Fee legs use base ERC20 updates. Only the constructor mints. No admin setters, external mint/burn, proxy, pause, blacklist or seizure entry points exist. |
| Registry failure could freeze token transfers | Bounded-gas static lookup with fixed-size return copy; invalid responses default to taxed transfers. Tested revert, no code, empty/malformed/oversized data and gas exhaustion. A broken registry would tax claims and must be corrected by the network before launch. |
| Fee evasion via rounding or exempt routing | Explicit design limitation. Integer rounding and required launch exemptions mean fees are not universal across economic routes. Documented in README. |
| Deployment metadata needs reproducibility | Compiler pinned to 0.8.26, optimizer 200, metadata hash disabled. Dependencies vendored as ordinary sources. No external linking or runtime network dependency for builds/tests. |

The `_distributor()` assembly copies only one word into temporary free memory,
checks successful call status and exact return size, and bounds the word to a
160-bit address. It uses STATICCALL; the registry cannot mutate the token or
spend allowances during lookup. The 30,000 gas budget needs confirmation against
the production factory's implementation. ERC20 operations have no recipient
callbacks. The configured registry remains an external trust dependency only for
distributor fee exemption, not for custody or arbitrary balance changes.

## Previous-round local validation

Results are recorded after running the commands in README with Foundry 1.8.3
and solc 0.8.26. The delivered tests use independent setup and no environment
variables, forked state, gas-bound assertions, or precomputed CREATE addresses.

- Initial `forge build --offline`: passed.
- Initial `forge test --offline`: 37 tests passed across four suites; no failures
  or skipped tests. Four fuzz tests ran 256 cases each. The invariant ran 128
  sequences at depth 64, totaling 8,192 calls with zero reverts.
- Final `forge build` and `forge test`: passed with no compiler warnings;
  37 tests passed, zero failed or skipped.
- `env -i PATH="$PATH" HOME="$HOME" forge test --offline --threads 4
  --fuzz-seed 0x534f53 --fuzz-runs 1024`: passed all 37 tests in parallel with
  only tool-discovery environment variables retained. Four fuzz tests each ran
  1,024 cases; the invariant again ran 8,192 calls with zero reverts.
- `forge fmt --check`: passed.
- The previous report stated that `sha256sum -c vendor-checksums.sha256 --quiet`
  passed for all 91 files. That statement did not describe the delivered tree:
  this revision reproduced eight stale v4-core hashes after formatting. See
  the corrected provenance and verification below.
- `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline`:
  passed as a local simulation with exactly one SOS deployment and no broadcast.
- A final `forge clean` followed by `forge build --offline` and the rehearsal
  also passed. Foundry's script discovery reported a missing-source warning for
  its generated `foundry-pp/DeployHelper85.sol` artifact, even after the clean
  build; compilation and simulation completed successfully. All authored and
  vendored sources are present.

The pinned `Token.protected.t.sol` was read in full. Its exact environment-driven
admission harness was not executed: the task did not provide resolved creation
code, network factory metadata, pool economics or the network's launch helper
contracts. `test/SOSLaunch.t.sol` instead executes the relevant token flows
offline against the vendored real Uniswap v4 PoolManager with synthetic local
parameters. The production admission harness and independent review remain the
network's release checks. Slither and Mythril were not run.

## Revision findings (2026-10-07)

- `015651a76ea9bd886c18bdc9a87b1c0989aa0c6b8349b470f845f75d85c7f1fc`:
  reproduced, with the requested resolution disputed. Copied the pinned proof
  unchanged into `test/scratch/Proof_015651a76ea9.t.sol` and ran
  `forge test --offline --match-path test/scratch/Proof_015651a76ea9.t.sol -vv`
  before and after this revision. Both tests fail: Bob/Carol receive 100 SOS,
  Dev receives zero, supply stays unchanged, and the manager retains zero SOS.
  The bypass is real. The proof requires taxation of transfers executed by the
  PoolManager, while the specified launch exemptions and existing exact-output
  launch tests require these transfers to be exempt. Taxing manager inputs
  breaks exact sell settlement. Taxing only outputs would pass the relay proof
  but reduce buy receipts and leave sells exempt. The protected buy/sell floor
  checks success, not exact buy output; the launch reference and existing local
  exact-settlement test require the latter. No fee policy was changed or accepted
  on the requester's behalf. This economics conflict remains for scope resolution
  before release. README now documents both relay routes, untaxed pool buys and
  sells, and explicit wording for the integrator's manifest. `launch.json` is
  absent from the supplied workspace, so no economics or addresses were invented.
  The disposable proof copy was removed after recording its failures; the pinned
  input was not edited and is not included in the delivered test suite.
- `be47f57fb2dd867f317ece2ee4664d3cfc9801cd9879ba3b192f0e27d90c9408`:
  reproduced and fixed. Both new constructor rejection tests failed on the
  starting code because deployment succeeded. `InvalidDev()` now rejects the
  configured factory and PoolManager as Dev. Both tests pass after the fix, as
  does a success regression proving a standalone deployer can still be Dev and
  pays the ordinary burn. No fee or exemption logic changed.
- `e4a2f780193f49c339c8f8aa516ab6122db221df604303fde83c619b581927b3`:
  reproduced and fixed. The original checksum command failed for PoolManager,
  Hooks, Pool, SqrtPriceMath, SwapMath, TickBitmap, Currency and Slot0. Regenerated
  the manifest after `forge fmt`, changing exactly those eight entries, and
  corrected DEPENDENCIES.md to identify the formatted v4-core copies. No vendored
  source was changed for this repair. This verifies delivered bytes; it is not a
  fresh audit or independent upstream package comparison.
- `f9d5ff204371db4d6f70f1b6bd1cbc31ba7cf20826cfd6f8fbea903257cdb9d6`:
  confirmed as a trust assumption, disputed as a code defect. The existing
  `test_distributorLookupUsesExactLaunchAndDoesNotCacheZero` passes: a caller's
  transfers deliver 98, then 100, then 98 SOS as its exemption is granted and
  revoked. The dynamic lookup is part of the specified integration and remains
  unchanged. README explicitly requires the production factory to fix the
  mapping after launch and return a plain ABI address within 30,000 gas; the
  production factory was not provided or verified here.

## Revision validation

- `forge build --offline` passed with solc 0.8.26, including a clean rebuild of
  76 source files after removing stale generated artifacts.
- `forge test --offline` passed all 40 delivered tests across four suites.
  Four fuzz tests ran 256 cases each; the invariant ran 8,192 calls without
  reverts. This count excludes the two separately reproduced disputed proofs.
- `forge test --offline --threads 4 --fuzz-seed 0x534f53 --fuzz-runs 1024`
  passed all 40 tests, with 1,024 cases per fuzz test and 8,192 invariant calls
  without reverts.
- `forge fmt --check` and `sha256sum -c vendor-checksums.sha256 --quiet` passed;
  all 91 delivered dependency hashes now match.
- `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline`
  succeeded, including after the clean build. Foundry still reports its
  generated `foundry-pp/DeployHelper85.sol` as a missing source during script
  discovery; this did not prevent compilation or simulation. No broadcast ran.
- `.imd-responses.json` parses and includes exactly one verdict for each of the
  four supplied finding IDs. No production admission harness, live factory
  verification, Slither or Mythril was run during this revision.
