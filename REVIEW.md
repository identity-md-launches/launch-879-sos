# SOS implementation review

This is the implementer's local review, not an independent audit. No independent
reviewer or static analyzer has attested to this project. The supplied security
and L2 references were read as background; no deployment, network lookup, key
access, or signing was performed.

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

## Local validation

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
- `sha256sum -c vendor-checksums.sha256 --quiet`: passed for all 91 vendored files.
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
