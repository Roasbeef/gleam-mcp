# Execution

Run `make check` from the repository root. It includes a warning-free build,
formatting, application tests, copied linter tests, house rules, source
boundaries and documentation mirrors. `make fmt` formats both packages.
Capture a command's own exit status before reading its log; the exit status
of a later log reader says nothing about the gate.

`make native-test` exercises actual OTP stdin/stdout pipes. A callback must
be owned before admission; joining a wrapper is insufficient if its nested
scope still owns live work. EOF drains the admitted request under its
original deadline.

Use separate checkouts for independent builds. Give parallel workers explicit
file ownership and preserve one another's edits. Review source plus tests,
verify each reported failure against reachable callers, and run the relevant
gate on the resulting tree before committing. Commit dependency manifests
separately from source and refresh the handoff after each body of work.

Native protocol tests read through a complete newline under one absolute
deadline. Readability alone does not establish that a frame is complete.
Compile before connecting an MCP client, because build output cannot enter
protocol stdout. Keep diagnostics on stderr.
