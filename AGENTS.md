# Gleam MCP

Read `docs/next.md` before planning work and `docs/gleam-style.md` before
writing code. This repository inherits Loom's literate Gleam style, total
decoders, caller-owned effects, and house-rule linter.

## Working here

Use Gleam >= 1.18 and Erlang/OTP >= 29. `make check` runs formatting, a
warning-free build, tests, the copied custom linter, and documentation checks.
`make fmt` formats the application and linter. Verify commands by their own
exit status. Public functions include examples; module documentation explains
ownership, transitions and failure behavior. Comments are complete sentences
with a blank line above them. Chain fallible steps with `use` and `result.try`.
Use opaque smart constructors for invariants, and domain variants for flags.

The application is an Erlang runtime package. Loom-specific rules in the
copied style guide about its broker, capabilities and frozen interfaces do
not create dependencies here. The pure wire modules remain free of effects;
`scripts/check_source.py` enforces their boundary. Custom Erlang FFI stays in
`internal/ffi_*.gleam` with the reason no maintained Gleam library suffices.
Process ownership and deadline machinery use weft when needed.

The copied linter retains Loom's R0 through R11 rules and promotion levels.
R0, R2, R4 and R10 apply to root source. R6 recognizes Loom's
`packages/core`, `packages/machine` and `packages/prompt` layout; the explicit
source gate owns pure-module enforcement in this standalone package.

## Changes and verification

Preserve unrelated work. Brief parallel workers with disjoint file ownership.
Make incremental commits with the repository owner's Git identity and no AI
attribution. Commit messages use `subsystem: imperative summary`, followed by
prose explaining why. Keep dependency locks and copied tooling separate from
application commits. Update `docs/next.md` and these mirrored package docs
when types, messages or dependencies change. Run one independent adversarial
review before declaring substantive work complete.

## Package boundary

`gleam_mcp/json` and `corruption` own strict values and bounded decoding
reports. `jsonrpc`, `protocol` and `stdio` own wire messages and framing.
`client` and `transport` own client actors, pending requests and native exit
evidence. `server` owns the immutable tool registry and initialization
phase; `server_stdio` owns its scoped request and input workers. Native
functions live in `internal/ffi_port` and `internal/ffi_stdio`.

Nothing depends on Loom core or capabilities. A tool handler owns argument
validation and its external effects. Callback cancellation proves worker
termination, not rollback of a remote effect. Raw non-text content remains
in the generic protocol value so consumers own any reduction policy.
