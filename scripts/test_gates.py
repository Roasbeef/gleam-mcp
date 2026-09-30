"""Prove that standalone source, mirror and lint gates fail closed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from check_source import check as check_source
from doc_check import check as check_docs


class GateTests(unittest.TestCase):
    def test_pure_modules_reject_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / "src/gleam_mcp/json.gleam"
            module.parent.mkdir(parents=True)
            module.write_text("//// import gleam/otp/actor\nimport gleam/list\n")
            self.assertEqual(check_source(root), [])
            module.write_text("import gleam/otp/actor\n")
            self.assertTrue(check_source(root))
            module.write_text('@external(erlang, "io", "write")\npub fn write() -> Nil\n')
            self.assertEqual(len(check_source(root)), 2)

    def test_schema_internal_modules_cannot_hide_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / "src/gleam_mcp/internal/schema/evaluate.gleam"
            module.parent.mkdir(parents=True)
            module.write_text("import gleam/regexp\nimport gleam_mcp/json\n")
            self.assertEqual(check_source(root), [])
            for dependency in ("weft", "gleam/io", "gun", "mist", "gleam_mcp/internal/ffi_native"):
                module.write_text("import " + dependency + "\n")
                self.assertTrue(check_source(root), dependency)

    def test_typed_wire_modules_cannot_import_runtime_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / "src/gleam_mcp/codec.gleam"
            module.parent.mkdir(parents=True)
            module.write_text("import gleam_mcp/internal/schema/evaluate\n")
            self.assertEqual(check_source(root), [])
            module.write_text("import gleam_mcp/client_http\n")
            self.assertTrue(check_source(root))

    def test_documentation_mirrors_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            self.assertTrue(check_docs(root))
            (root / "CLAUDE.md").write_text("package\n")
            (root / "AGENTS.md").write_text("different\n")
            self.assertTrue(check_docs(root))
            shutil.copyfile(root / "CLAUDE.md", root / "AGENTS.md")
            self.assertEqual(check_docs(root), [])

    def test_lint_wrapper_requires_valid_summary(self):
        wrapper = Path(__file__).with_name("lint.sh")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "packages/lint").mkdir(parents=True)
            (root / "src").mkdir()
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            shutil.copyfile(wrapper, root / "scripts/lint.sh")
            gleam = root / "bin/gleam"
            environment = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"])
            for summary, expected in [("missing summary", 1), ("# invalid 0", 1), ("# 1 0", 1), ("# 0 8", 0)]:
                gleam.write_text("#!/bin/sh\nprintf '%s\\n' '" + summary + "'\n")
                gleam.chmod(0o755)
                result = subprocess.run(["bash", str(root / "scripts/lint.sh")], env=environment, capture_output=True)
                self.assertEqual(result.returncode, expected, summary)


if __name__ == "__main__":
    unittest.main()
