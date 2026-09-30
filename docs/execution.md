# Execution

Run `make check` from the repository root. It includes a warning-free build,
formatting, application tests, copied linter tests, house rules, source
boundaries and documentation mirrors. `make fmt` formats both packages.
Capture a command's own exit status before reading its log; the exit status
of a later log reader says nothing about the gate.

`make native-test` exercises actual OTP stdin/stdout pipes and independent
HTTP/TLS peers. A callback must be owned before admission; joining a wrapper
is insufficient if its nested scope still owns live work. EOF drains admitted
stdio requests under their original deadlines. HTTP tests witness actual
socket close before client return while the VM remains alive, disconnect
retirement of a blocked handler, and certificate rejection before a POST.
A transport losing its final response must not replay a tool effect.

The ordinary Gleam test suite includes every required vector in the pinned
Draft 2020-12 corpus. Run `gleam run -m gleam_mcp/schema_optional` separately
for the optional census; its recorded failures describe refused or unsupported
semantics rather than required-suite skips. See the corpus `UPSTREAM.md`.

Use separate checkouts for independent builds. Give parallel workers explicit
file ownership and preserve one another's edits. Review source plus tests,
verify each reported failure against reachable callers, and run the relevant
gate on the resulting tree before committing. Commit dependency manifests
separately from source and refresh the handoff after each body of work.

Native protocol tests read through a complete newline under one absolute
deadline. Readability alone does not establish that a frame is complete.
Compile before connecting an MCP client, because build output cannot enter
protocol stdout. Keep diagnostics on stderr.
