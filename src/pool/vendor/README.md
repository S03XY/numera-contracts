# Vendored dependencies

Three files copied verbatim from npm, unmodified except for their import paths:

- `InternalLeanIMT.sol`, `Constants.sol` — `@zk-kit/lean-imt.sol@2.0.0`
- `PoseidonT2.sol`, `PoseidonT3.sol`, `PoseidonT4.sol` — `poseidon-solidity@0.0.5`

Vendored rather than remapped because both publish as npm packages whose directory name ends in
`.sol`, and a foundry remapping whose value ends `.sol/` loses its trailing slash — producing
`@zk-kit/lean-imt.solInternalLeanIMT.sol` and a parse error. Five files is a smaller price than a
build that only works on machines where `npm install` has been run inside `contracts/`.

Do not edit them. To update, re-copy from npm and re-point the imports.
