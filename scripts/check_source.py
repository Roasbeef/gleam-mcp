"""Enforce pure wire modules and the custom-FFI boundary."""
from pathlib import Path
import re
import sys

PURE = {"json", "corruption", "jsonrpc", "protocol", "stdio", "server"}


def check(root: Path) -> list[str]:
    errors = []
    for path in sorted((root / "src").rglob("*.gleam")):
        text = path.read_text()
        relative = path.relative_to(root).as_posix()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
        external = re.search(r"@external\s*\(", code)
        if external and not (path.parent.name == "internal" and path.name.startswith("ffi_")):
            errors.append(f"{relative}: custom FFI must live in internal/ffi_*.gleam")
        if path.parent.name == "gleam_mcp" and path.stem in PURE:
            effects = re.search(r"^import (?:gleam/erlang|gleam/otp|weft|gleam_httpc|simplifile|gleam_mcp/internal|gleam_mcp/server_stdio)(?:[/\s]|$)", code, re.M)
            if external or effects:
                errors.append(f"{relative}: pure wire module contains an effect dependency")
    return errors


if __name__ == "__main__":
    errors = check(Path(__file__).resolve().parents[1])
    print("\n".join(errors) if errors else "source-check: pure wire and FFI boundaries hold")
    sys.exit(bool(errors))
