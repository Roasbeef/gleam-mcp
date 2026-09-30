"""Enforce pure wire modules and the custom-FFI boundary."""
from pathlib import Path
import re
import sys

PURE = {
    "json", "corruption", "jsonrpc", "protocol", "stdio", "server",
    "schema", "codec", "tool", "version", "metadata", "discovery",
    "request", "mrtr", "subscription", "http", "http_headers", "sse",
}


def pure_module(module: str) -> bool:
    return module in {"gleam_mcp/" + name for name in PURE} or module.startswith(
        "gleam_mcp/internal/schema/"
    )


def pure_import(module: str) -> bool:
    if module.startswith("gleam_mcp/"):
        return pure_module(module)
    if module.startswith("gleam/"):
        return not (
            module in {"gleam/io", "gleam/httpc", "gleam/crypto"}
            or module.startswith(("gleam/erlang", "gleam/otp"))
        )
    return False


def check(root: Path) -> list[str]:
    errors = []
    for path in sorted((root / "src").rglob("*.gleam")):
        text = path.read_text()
        relative = path.relative_to(root).as_posix()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
        external = re.search(r"@external\s*\(", code)
        if external and not (path.parent.name == "internal" and path.name.startswith("ffi_")):
            errors.append(f"{relative}: custom FFI must live in internal/ffi_*.gleam")
        module = path.relative_to(root / "src").with_suffix("").as_posix()
        if pure_module(module):
            imports = re.findall(r"^\s*import\s+([a-zA-Z0-9_/]+)", code, re.M)
            if external or any(not pure_import(name) for name in imports):
                errors.append(f"{relative}: pure wire module contains an effect dependency")
    return errors


if __name__ == "__main__":
    errors = check(Path(__file__).resolve().parents[1])
    print("\n".join(errors) if errors else "source-check: pure wire and FFI boundaries hold")
    sys.exit(bool(errors))
