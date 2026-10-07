# Vendored dependencies

All dependencies are source files copied from the supplied local `/home/seat6/vendor`
mirrors. No git submodules, nested git directories, symlinks, package install,
network resolution, compiler binaries or dependency download steps are required.
Upstream sources were not modified.

| Directory | Source subset | Version reported by supplied mirror | License |
| --- | --- | --- | --- |
| `lib/openzeppelin-contracts` | ERC20 and its four transitive imports | package 5.7.0; ERC20 file last updated v5.5.0 | MIT |
| `lib/forge-std` | Solidity source tree used by tests and offline script | 1.16.2 | MIT or Apache-2.0 |
| `lib/v4-core` | PoolManager and its transitive source imports, used only by tests | 1.0.2 | Per-file MIT / BUSL-1.1; texts in `licenses/` |
| `lib/solmate` | `src/auth/Owned.sol`, used only by PoolManager in tests | Snapshot supplied inside the v4-core mirror | AGPL-3.0 license file; Owned.sol identifies AGPL-3.0-only |

License texts and available upstream package metadata are included. The SOS
production artifact imports only the five OpenZeppelin source files, not the v4
or testing libraries. `vendor-checksums.sha256` records the exact delivered
dependency bytes; verify it with `sha256sum -c vendor-checksums.sha256`.
