# SOS test revision: constructor reverts and zero allowance owner

Finding: `709ded7fa463ef42e005c95d559c4b1ba1ff822b7d23c126c4bbeae11c80ad63`

Both test defects reproduced locally with Foundry 1.8.3
(`cae51ad458f6abb64852b7709eb784352429825d`) and solc 0.8.26.
This is a local validation record. The root `REVIEW.md` is outside this
assignment's editable paths, so the current results are recorded here.

## Reproduction and correction

1. Before editing, `forge test --offline --match-test
   test_invalidAddressesAndConfiguration -vvvv` reported PASS, but its trace
   ended with `InvalidDev()` from `VM::deployCode` after the first constructor
   attempt. No later constructor or ERC20 assertions ran.
2. Replacing only the five constructor assertions with raw `CREATE` and checks
   of the returned address and complete revert data exposed the second defect.
   The same command failed at `transferFrom(address(0), ALICE, 0)`:
   actual `ERC20InvalidApprover(address(0))`, expected
   `ERC20InvalidSender(address(0))`. The vendored ERC20 spends allowance before
   checking the transfer sender; approving its zero owner rejects this call.
3. Corrected the expected error to `ERC20InvalidApprover(address(0))` and added
   final checks that supply, holder/Dev/zero balances and the affected allowances
   remain unchanged. The trace now executes all five constructor failures,
   all four existing ERC20 rejection cases and the final state reads, then
   completes normally with `[Stop]`.

The helper checks both deployment failure and the exact error payload, without
arming `expectRevert` around a preprocessed constructor call. Existing fuzz,
launch and invariant tests are retained. This finding identifies test defects;
it does not require a token implementation change.

## Validation

- `forge build --offline`: passed.
- `forge test --offline --match-test test_invalidAddressesAndConfiguration -vvvv`:
  passed with the complete trace described above.
- `forge test --offline`: 61 passed, zero failed or skipped across eight suites.
  The supply invariant executed 128 sequences of depth 64 (8,192 calls), and
  each ledger invariant executed 256 sequences of depth 96 (24,576 calls each).
  All three invariant campaigns reported zero handler reverts.
- `forge test --offline --threads 4 --fuzz-seed 0x534f53524556 --fuzz-runs 2048`:
  61 passed, zero failed or skipped. Four fuzz properties ran 2,048 cases each;
  the five properties with inline configuration retained 1,000 cases each.
  The three invariants again ran 8,192 / 24,576 / 24,576 calls with zero reverts.
- `forge fmt test/SOS.t.sol`, `forge fmt --check` and `git diff --check`: passed.
- `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline`: passed
  as a local simulation. Foundry warned about missing generated
  `foundry-pp/DeployHelper54.sol` and `DeployHelper87.sol` sources; the rehearsal
  completed successfully. No broadcast was performed.

Foundry 1.8.5 was not run; both defects were reproduced and the correction
verified on the pinned 1.8.3 toolchain.
