"""Check package documentation mirrors without invoking the compiler."""
from pathlib import Path
import sys


def check(root: Path) -> list[str]:
    errors = []
    packages = [root, *sorted((root / "packages").glob("*"))]
    for package in packages:
        if not (package / "src").is_dir():
            continue
        original = package / "CLAUDE.md"
        mirror = package / "AGENTS.md"
        if not original.is_file() or not mirror.is_file():
            errors.append(f"{package}: missing CLAUDE.md or AGENTS.md")
        elif original.read_bytes() != mirror.read_bytes():
            errors.append(f"{package}: documentation mirrors differ")
    return errors


if __name__ == "__main__":
    errors = check(Path(__file__).resolve().parents[1])
    print("\n".join(errors) if errors else "doc-check: all package mirrors match")
    sys.exit(bool(errors))
