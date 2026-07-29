#!/usr/bin/env python3
"""prepare_ida_workspace.py 的行为测试。"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PureWindowsPath

SCRIPT = Path(__file__).resolve().with_name("prepare_ida_workspace.py")
SPEC = importlib.util.spec_from_file_location("prepare_ida_workspace", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrepareWorkspaceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "idaworkspace"
        self.source = Path(self.temporary.name) / "sample.bin"
        self.source.write_bytes(b"stable sample\n")
        self.windows_root = PureWindowsPath(r"D:\idaworkspace")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare(self, repair: bool = False):
        return MODULE.prepare(
            str(self.source),
            repair=repair,
            workspace_wsl_root=self.root,
            windows_root=self.windows_root,
        )

    def test_creates_then_reuses_one_hash_bound_object(self) -> None:
        created = self.prepare()
        reused = self.prepare()

        self.assertEqual(created["status"], "created")
        self.assertEqual(reused["status"], "reused")
        self.assertEqual(created["sha256"], reused["sha256"])
        self.assertEqual(created["windows_input_path"], reused["windows_input_path"])
        self.assertFalse(created["opened_existing_idb"])
        self.assertRegex(created["preferred_session_id"], r"^sample\.bin-[0-9a-f]{12}$")
        self.assertEqual(len(list((self.root / "objects").iterdir())), 1)

    def test_existing_i64_becomes_open_target(self) -> None:
        created = self.prepare()
        binding = json.loads(Path(created["binding_path"]).read_text(encoding="utf-8"))
        idb_path = MODULE.wsl_path_for(
            binding["windows_idb_path"], self.root, self.windows_root
        )
        idb_path.write_bytes(b"IDA database")

        reused = self.prepare()

        self.assertTrue(reused["opened_existing_idb"])
        self.assertEqual(reused["idb_open_path"], reused["windows_idb_path"])

    def test_corrupt_binding_fails_fast_then_repairs_same_directory(self) -> None:
        created = self.prepare()
        binding_path = Path(created["binding_path"])
        binding_path.write_text("not json\n", encoding="utf-8")

        with self.assertRaisesRegex(MODULE.PreparationError, "绑定校验失败"):
            self.prepare()
        repaired = self.prepare(repair=True)

        self.assertEqual(repaired["status"], "repaired")
        self.assertEqual(repaired["sha256"], created["sha256"])
        self.assertEqual(Path(repaired["binding_path"]), binding_path)

    def test_hash_mismatch_preserves_bad_copy_during_repair(self) -> None:
        created = self.prepare()
        binding = json.loads(Path(created["binding_path"]).read_text(encoding="utf-8"))
        input_path = MODULE.wsl_path_for(
            binding["windows_input_path"], self.root, self.windows_root
        )
        input_path.write_bytes(b"tampered")

        with self.assertRaisesRegex(MODULE.PreparationError, "SHA-256 不匹配"):
            self.prepare()
        repaired = self.prepare(repair=True)

        self.assertEqual(repaired["status"], "repaired")
        self.assertEqual(input_path.read_bytes(), self.source.read_bytes())
        self.assertEqual(len(list(input_path.parent.glob("sample.bin.invalid-*"))), 1)

    def test_cli_starts_from_unrelated_working_directory(self) -> None:
        unrelated_directory = Path(self.temporary.name) / "unrelated" / "directory"
        unrelated_directory.mkdir(parents=True)

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"],
            cwd=unrelated_directory,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("D:\\idaworkspace", result.stdout)


if __name__ == "__main__":
    unittest.main()
