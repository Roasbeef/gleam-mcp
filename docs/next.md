# Current handoff

Audited on 2026-09-30 against source and dependency baseline
`6db0e3a9fc2fe74bc5980517a0fc5924edb62b48`. The full local gate passed using
the published Glisten and Mist pins. Runtime publication `686955fc` passed
Linux and macOS CI in
[run 36765278006](https://github.com/Roasbeef/gleam-mcp/actions/runs/36765278006).
A fresh public Linux clone of that commit also passed the complete gate
without local dependency overrides.

## Where the tree is

The modern profile follows released MCP `2026-07-28`, pinned to official
specification commit `046fa30efd374370afb87ef830bd788eac5f217e` after initial
publication. Typed definitions couple schemas, encoders and decoders for
both client and server. Stdio and HTTP use the required request/response,
explicit multi-round-trip and subscription envelopes. The initialized
`2025-06-18` and `2024-11-05` stdio profiles remain available to Loom.
Resources and prompts are tracked in [issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1);
optional providers, tasks and OAuth flows remain unadvertised.

The schema gate includes all 1,301 required Draft 2020-12 vectors at the
recorded upstream revision, with zero skips. The optional corpus measures
546/1,036 passing vectors; the remaining 490 refusals or mismatches are
reported explicitly. See the corpus record for regex admission, unsupported
vocabularies, licenses and logical work bounds. Do not infer arbitrary
ECMAScript equivalence or native regex wall-clock bounds from that census.

The complete `make check` gate passed at `6db0e3a` with 232 unit tests
(including all required schema vectors), 139 linter tests, five negative
tooling checks, nine native stdio checks and 30 native HTTP/TLS checks. Its
own exit status was zero. The gate used the public Git dependencies recorded
in the manifest and lock; no local dependency override was needed.

Glisten is pinned to `3eb785919be0736da0a20732a56275dce0132327` and Mist to
`28b43178ff57bfb619c64b8c3544831646d5fdb9`. Both register factories before
admitting the work those factories own. Mist's
[startup PR #3](https://github.com/Roasbeef/mist/pull/3) retains the earlier
framing fix and passed unit and native CI in
[run 36764236673](https://github.com/Roasbeef/mist/actions/runs/36764236673).
[Glisten PR #1](https://github.com/Roasbeef/glisten/pull/1) passed its inherited
Gleam 1.14 / OTP 28 CI in
[run 36764762464](https://github.com/Roasbeef/glisten/actions/runs/36764762464).
It was merged into the fork's `compat/v9.0.1` branch as `1e53a4d`; the SDK
retains the exact tested commit above. The upstream report is
[rawhat/glisten#55](https://github.com/rawhat/glisten/issues/55).

Earlier review fixes for malformed argument classification, subscription
completion admission and a false-pass regression fixture remain in the
tree. Native HTTP checks verify status delivery, actual socket reuse, and
framing refusal before callbacks. The Mist parser regression fails against
the original code and passes with the framing fix. The previous handoff's
Mist pin `1a81d90` is superseded by the startup fix above.

Jevelin MCP publication `fb5b434` consumes SDK `686955fc` and passed Linux
and macOS in [run 36766066616](https://github.com/Roasbeef/jevelin-mcp/actions/runs/36766066616).
Its fresh public Linux clone passed the full gate and fifty unchanged HTTP
startup suites, including 150 expected authentication refusals. No live
Jevelin inference has been exercised.

Loom extraction `6de0188` pinned SDK `686955fc`. Its later published head
`a102a35232436cde70e0f3ea99c8c810daa7f156`, rebased on `7b1c662`, passed
exact-head hosted CI in
[run 36795638550](https://github.com/Roasbeef/loom/actions/runs/36795638550)
and all six Linux signoff lanes. That evidence is historical: the newer
`5aad549bd17a34dd07f6549695ef1430b0efff5f` rebase on `275efc42` has its own
CI and signoff pending. Consumer release verification remains separate.
The earlier `589a2cd` passed its required Linux gate and advisory macOS package
check, while macOS e2e failed at `worktree_diff_test.gleam:95`. That assertion
and GitFailed(128) also failed on its exact base main `01f14ef8`; this records
the earlier comparison rather than a current failure claim.

## Source reading guide

The literate source pass is based on `0146dd057816433f6a02c156a7cce3ecc0206661`.
[Architecture](architecture.md) follows typed calls, transport custody and
offline schema evaluation with explicit bounds and limitations.
[Principles](principles.md) records the standalone package's comment and
navigation conventions. Every application Gleam module has a `Flow` section;
client, stdio coordinator, HTTP stream and subscription admission include
transition tables. Typed opaque boundaries document their retained fields.
The native client's three option builders now follow its State/Msg/Phase
contracts; other grouped implementation sections retain their own types.

The source reading pass passed the complete local `make check` gate using
Gleam 1.18.1 and Erlang/OTP 29. Its own exit status was zero: 232 unit tests,
139 linter tests, five tooling checks, nine native stdio tests and 30 native
HTTP/TLS tests. The linter reported zero errors and 112 warnings. Documentation
HTML also rendered successfully with `gleam docs build`; its dependency checks
reported existing deprecated Header aliases in Gramps and Mist.

An earlier sandboxed run refused local socket binding. The first run with
listener access passed stdio but reported eleven HTTP fixture READY timeouts
and one TLS subprocess startup timeout. An isolated unchanged HTTP test and
the fresh full gate then passed. The startup-timeout cause remains unconfirmed;
no assertion, deadline, runtime code or dependency was changed to obtain the
passing run. Executable-token comparison preserves all 34 application Gleam
modules after reversing the three recorded declaration moves and normalizing
formatter trailing commas. The three Erlang adapters preserve every executable
line; their changes are comments only.

## Rulings already made

A typed codec checks custom encoders as well as decoders. Request-bound
result decoding closes over the original arguments. An opaque continuation
retains those arguments, the exact endpoint, revision and result decoder;
resumption is a new explicit attempt. Untrusted server continuation state
still needs application integrity validation when it represents authority.
Transport failure never triggers automatic effect replay.

The stdio reader, writer and admitted handlers have explicit custody. A
callback stays parked until its scope is adopted. EOF stops admission and
drains admitted work under its original deadline. Worker retirement proves
local termination, not rollback of a remote effect. A live subscription
must coexist with ordinary requests and map its allocated wire identifier
back to the caller's handle consistently.

HTTP binds loopback and requires an explicit admission policy. Present
Origins and mirrored headers validate before effects. Gun verifies HTTPS
peers and hostnames, disables retries and joins the actual connection owner
before return.

Mist's SSE factory registers before Glisten starts; Glisten's
connection factory registers before its listener and acceptors start.
Reverse shutdown ends admission before retiring either factory. Mist owns
parsing and supervision; the narrow close-event adapter exists because its
public SSE interface omits socket-close delivery.

Server uploads require unambiguous `Content-Length` framing within eight MiB;
unsupported chunked uploads close before body collection. Bounded refusal
drains use a shared fifteen-second budget plus at most one native read;
this is not a claim of an aggregate deadline for every admitted body read.

The initial custody regression has positive synchronized liveness witnesses,
but restoring the old custody code passed under the ordinary scheduler.
That mutation does not prove the old race was detected. Independent native
HTTP tests keep the client VM alive after return to avoid masking a leaked
connection with VM exit.

## What to do next

1. Keep consumer dependency updates exact and reproducible. Exit: clean
   Jevelin/Loom builds and hosted Linux/macOS checks pass the named published
   commits, including real Loom MCP and jailed code-mode exchanges.
2. Implement resources and prompts under issue #1 as a separate body of work.
   Exit: typed APIs, capability negotiation and independent exchanges prove
   the advertised behavior. See [optional features](extensions.md).

Run `make check`; [execution](execution.md) explains verification hazards,
and [protocol contracts](protocol.md) record the current wire and ownership
boundaries. The inherited style guide and custom linter remain the gates.
