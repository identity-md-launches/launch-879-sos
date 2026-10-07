# SOS (SOS)

SOS is an immutable ERC-20 with 18 decimals. Its constructor mints exactly
**1,000,000,000 SOS** (`1000000000000000000000000000` minor units) to
`msg.sender`. On an IMD launch that sender is the ProjectFactory, not Dev.
There is no later mint, owner, upgrade, pause, blacklist, seizure, public burn,
or ability to change fees or the Dev recipient.

## Transfer rules

For an ordinary transfer of gross amount `a`, measured in minor units:

| Effect | Amount |
| --- | --- |
| Burned, reducing `totalSupply()` | `floor(a / 100)` |
| Credited to the immutable Dev address | `floor(a / 100)` |
| Credited to the recipient | `a - 2 * floor(a / 100)` |

Sending 100 SOS ordinarily delivers 98 SOS, pays 1 SOS to Dev, and burns 1 SOS.
Fees are taken out of the requested amount, not added on top. The tax is paid
in SOS immediately; there is no conversion to ETH, collection function, or
external call to Dev. Fee legs do not incur another fee.

Both `transfer` and `transferFrom` use these rules. `transferFrom` requires
allowance for the gross amount and decrements it by that amount. The standard
OpenZeppelin unlimited allowance (`uint256.max`) is preserved. Approval alone
does not charge a fee. Failed transfers revert all balance, supply, event, and
allowance changes.

Amounts below 100 minor units charge zero fees. Each fee rounds down separately;
all rounding residue goes to the recipient. Zero transfers succeed and emit a
zero `Transfer` event. Splitting amounts into tiny transfers can reduce fees.
Transfers to the zero address fail, including zero-amount transfers.

Self-transfers still incur fees and require the full gross balance. A normal
self-transfer loses 2%; a Dev self-transfer loses only the burned 1%, since the
tax returns to Dev. When Dev is the sender or recipient, balance credits combine
naturally; Dev has no blanket exemption. Burn, tax, and net legs emit standard
`Transfer` events, in that order, when fees are nonzero. The constructor emits
one mint event for the full supply.

## IMD launch compatibility

The supplied protected floor requires exact factory distribution and distributor
claims, pool seeding, and successful buys/sells. The launch reference additionally
requires buys to deliver their quoted output exactly. Taxing sell settlement
causes a shortfall; taxing PoolManager payouts reduces a buyer's receipt. When
launch configuration is enabled, a transfer is exempt
if **any** of these conditions holds:

1. The immediate token caller is the configured factory.
2. The immediate token caller is the configured PoolManager.
3. The recipient is the configured PoolManager, including a router's
   `transferFrom` during sell settlement.
4. The immediate token caller equals the nonzero address currently returned by
   `factory.distributorOf(launchNumber)`.

Exempt transfers move the entire gross amount without burning or paying Dev.
They still require a sufficient balance, valid recipient, and, when applicable,
allowance. An ordinary caller transferring **to** the factory or distributor is
taxed. An ordinary spender pulling **from** either one is also taxed. Receiving
tokens through a claim does not exempt the claimant's later ordinary transfers.

This means the requested "every transfer" fee applies to ordinary transfers;
IMD launch mode excludes these protocol flows. **Both buys and sells through the
configured PoolManager pay zero SOS burn and zero Dev tax.** Any holder can also
route a payment through `unlock -> sync -> transferFrom -> settle -> take`, with
no pool or swap, to deliver 100 SOS for a 100 SOS debit, zero tax and zero burn.
Settling into ERC-6909 claims and later burning those claims to `take` SOS has
the same result. Claims can change hands without an SOS transfer. These routes
are permissionless and cost gas; they are not limited to the launch itself.

The supplied revision proof reproduces this limitation. It remains unresolved
as an economics requirement: preserving the existing exact settlement design
does not satisfy a literal fee on every transfer. Removing only the PoolManager
caller exemption would tax relay withdrawals and buys, delivering 98% of quoted
output (subject to rounding); it would still leave sells untaxed. There is no
claim here that the supplied floor's buy test checks exact output. The requester
and launch integrator must resolve this scope conflict before release. A fee
design covering pool volume requires a separately reviewed integration change.
Other exchanges are not exempt and must support fee-on-transfer assets.

The distributor cannot be a constructor argument because its address depends on
the token address. Lookup occurs dynamically, uses `STATICCALL`, forwards at most
30,000 gas and copies at most 32 return bytes. A revert, invalid address encoding,
wrong-length result, missing factory code, or exhausted lookup gas defaults to
normal taxation, preserving ordinary holders' ability to transfer. Such a failure
would also tax distributor claims, so the operator must verify the real registry
before launching. The registry must return a standard ABI address within that
gas budget. Whoever controls its answer controls which distributor caller is
exempt; SOS itself has no registry or exemption setter.
Changing that answer can exempt an arbitrary new operator and remove the real
distributor's exemption, causing its claims to arrive short. The operator must
confirm that the production factory fixes this mapping after launch; the local
fixture intentionally allows mutation to test this trust assumption.

## Deployment parameters

The production artifact is **`src/SOS.sol:SOS`** with constructor:

```solidity
constructor(address dev_, address factory_, address poolManager_, uint64 launchNumber_)
```

| Argument | IMD custom launch value |
| --- | --- |
| `dev_` | Requester's intended Dev wallet; use `$requester` only after confirming that it is the intended tax recipient |
| `factory_` | `$factory` |
| `poolManager_` | `$poolManager` |
| `launchNumber_` | `$launchNumber` |

No Dev wallet or network deployment addresses were provided in the assignment.
None is invented or hardcoded into the production contract. The network deployer
must resolve and verify them. Dev must not be zero, the token itself, the
configured factory, or the configured PoolManager; invalid Dev aliases revert
with `InvalidDev()`. The standalone deployer may still be Dev. Factory and
PoolManager must either both be nonzero and distinct, or both be zero. Code
existence is an operator check, not a constructor check.

For a **standalone token with no launch exemptions**, use
`SOS(dev, address(0), address(0), 0)`. This mode taxes every ordinary transfer,
including the deployer's transfers, and is unsuitable for the IMD protected
launch floor. A nonzero launch number is rejected in this mode.

For IMD, deploy the creation code with these four static arguments through the
network's `ProjectFactory.launchCustom`. The factory must receive the whole
initial supply. No application contracts or initialization calls are needed.
The eventual manifest should declare name/symbol `SOS`, decimals `18`, and the
exact initial supply above, with no application contracts. The factory handles
the swarm share and pool allocation. Economics, paired currency, live addresses,
and launch metadata were not supplied; a fabricated `launch.json` is not included.
No `launch.json` is present in this revision workspace. If the requester accepts
the exemptions, the integration step must include the following explicit note
in its manifest: "SOS pool buys, pool sells, arbitrary PoolManager-routed
payments, and ERC-6909 wrapping/redemption incur no SOS burn or Dev tax. Ordinary
non-exempt transfers burn 1% and pay 1% to Dev, rounded down in minor units."

`script/Deploy.s.sol` is an **offline rehearsal only**. Its no-argument `run()`
uses a clearly marked local Dev fixture and only runs on chain 31337. Its
`deploy(address)` helper accepts an explicit Dev and permits local chain 31337
or Sepolia 11155111. It deploys the standalone configuration and the rehearsal
script receives the supply as constructor caller. It reads no environment,
keys, or RPC settings and contains no broadcast markers. Do not deploy this
helper as a production factory or send funds to it. Production deployment is
the network deployer's responsibility after independent review.

## Offline build and verification

Foundry 1.8.3 and a locally installed Solidity **0.8.26** are required. All source
dependencies are regular files under `lib/`; no downloads, npm install, FFI,
filesystem cheatcode permission, forks, or external services are needed.
Compiler settings include optimization at 200 runs, `bytecode_hash = "none"`,
and Cancun EVM support. Cancun is necessary for the real v4 PoolManager's
transient storage in the launch tests. Use a Cancun-compatible target chain;
Sepolia is the default network target in this assignment.

```sh
forge build --offline
forge test --offline
forge test --offline --fuzz-seed 0x534f53 --fuzz-runs 1024
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`EXPECTED_CHAIN_ID` is accepted in that standard verifier invocation but is not
read by the rehearsal script; chain gating uses `block.chainid`. Tests neither
read nor write environment variables. Unit and launch tests cover successful and
failed transfers, gross allowances, fee rounding, Dev/self-transfer aliases,
absent administrative methods, exact launch flows, faulty registry responses,
and a real v4 single-sided seed with buys and direct/router sells. Stateful
invariant tests check balance conservation and total supply against accumulated
burns across randomized transfer sequences. See `REVIEW.md` for recorded results
and limits; passing tests are not an independent security audit.

## Operator responsibilities

Before release, obtain an independent adversarial review, confirm the Dev wallet
and all network parameters, and validate the registry's lookup and distributor
claims against the actual factory. Confirm the deployed constructor arguments,
metadata, supply, runtime bytecode, and ownership of the initial supply. Configure
the pool and economics in the separate manifest/integration step and execute
the protected admission checks against the exact creation code. Only the network
deployer signs and broadcasts; no transaction was sent for this task.

The immutable Dev wallet should remain under the requester's control. A wrong or
lost Dev address cannot be repaired in SOS. Wallets and integrations must display
gross versus net amounts and account for shrinking supply. Accidental tokens or
ETH sent to unsupported contracts have no SOS administrator rescue path.
