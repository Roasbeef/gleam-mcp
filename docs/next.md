# Current handoff

Audited on 2026-09-30 against application and lock baseline `acb4d70`.
The implementation comes from Loom `f399a07cf`; this handoff records the
standalone extraction, rather than carrying the previous in-progress stub.

## Where the tree is

The package exposes strict JSON and JSON-RPC decoding, MCP framing,
client actors and transports, an immutable tools registry, and a foreground
stdio server. It supports `2025-06-18` and `2024-11-05`. The client has no
Loom dependency; callers choose identity, isolation and result reduction.
Loom keeps its generator, schema planner and MessagePack adapter.

`make check` passed with 183 Gleam tests, 139 copied-linter tests, three
negative tooling tests and six native pipe/frame-reader tests. The native
client connects to an actual server process. Independent review found a
nested request-custody race and an incomplete test-frame deadline; both
were corrected and rechecked. The synchronized liveness assertions pass,
but restoring the old custody code did not fail under the ordinary
scheduler, so that mutation is not evidence against the old race.
Hosted CI has not yet completed for the initial publication.

## Rulings already made

The callback stays parked until its scope is adopted by the outer managed
task. Input failure must join that owner before return. EOF stops admission
and drains admitted work under the original request deadline. These
contracts live in `server_stdio` and its tests. Worker exit proves local
termination, not rollback of a remote effect.

The strict JSON parser preserves integer precision, rejects duplicate keys
and validates Unicode. Non-text content keeps its original JSON in
`protocol.Other`; consumers own any reduction.

## What to do next

1. After both consumer repositories and the Loom extraction PR are published,
   pin the latest official MCP specification and implement its required
   protocol plus HTTP transport. Exit: exact revision documented and
   independent peer/failure-path tests pass.
2. Couple tool schemas, argument encoders/decoders and result decoding through
   opaque typed definitions shared by client and server. Exit: ordinary
   typed callers cannot pass arguments for a different tool or decoder.
3. Verify published Git dependencies from clean consumer checkouts and record
   the exact hosted CI results. Exit: no local path dependency is required.

Optional capabilities remain unadvertised until their behavior exists.
Run `make check`; see [execution](execution.md) for verification hazards and
[the inherited style guide](gleam-style.md) before editing source.
