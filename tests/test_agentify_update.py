import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENTIFY_BIN = ROOT / "bin" / "agentify"


class AgentifyUpdateTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tempdir.name)
        self.remote = self.base / "remote.git"
        self.source = self.base / "source"
        self.install = self.base / "install"
        self._run(["git", "init", "--bare", str(self.remote)])
        self._run(["git", "init", "-b", "main", str(self.source)])
        self._run(["git", "-C", str(self.source), "config", "user.name", "Test User"])
        self._run(["git", "-C", str(self.source), "config", "user.email", "test@example.com"])

        self._write_source("VERSION", "v1\n")
        self._run(["git", "-C", str(self.source), "add", "VERSION"])
        self._run(["git", "-C", str(self.source), "commit", "-m", "initial"])
        self._run(["git", "-C", str(self.source), "remote", "add", "origin", str(self.remote)])
        self._run(["git", "-C", str(self.source), "push", "-u", "origin", "main"])
        self._run(["git", "-C", str(self.remote), "symbolic-ref", "HEAD", "refs/heads/main"])
        self._run(["git", "clone", str(self.remote), str(self.install)])

    def tearDown(self):
        self.tempdir.cleanup()

    def test_update_fast_forwards_install_checkout(self):
        self._commit_and_push("VERSION", "v2\n", "bump")

        result = self._run_update()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.install / "VERSION").read_text(), "v2\n")
        self.assertIn("agentify updated:", result.stdout)

    def test_update_refuses_dirty_checkout(self):
        (self.install / "LOCAL_ONLY").write_text("dirty\n")

        result = self._run_update(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to update because the agentify checkout has local changes", result.stdout)

    def test_update_switches_install_checkout_back_to_default_branch(self):
        self._run(["git", "-C", str(self.install), "checkout", "-b", "old-release"])
        self._commit_and_push("VERSION", "v3\n", "ship")

        result = self._run_update()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._capture(["git", "-C", str(self.install), "branch", "--show-current"]).strip(), "main")
        self.assertEqual((self.install / "VERSION").read_text(), "v3\n")
        self.assertIn("Switching installed checkout from old-release to main", result.stdout)

    def _commit_and_push(self, name: str, contents: str, message: str):
        self._write_source(name, contents)
        self._run(["git", "-C", str(self.source), "add", name])
        self._run(["git", "-C", str(self.source), "commit", "-m", message])
        self._run(["git", "-C", str(self.source), "push", "origin", "main"])

    def _write_source(self, name: str, contents: str):
        (self.source / name).write_text(contents)

    def _run_update(self, check: bool = True):
        env = os.environ.copy()
        env["AGENTIFY_INSTALL_ROOT"] = str(self.install)
        result = subprocess.run(
            [str(AGENTIFY_BIN), "update"],
            cwd=self.base,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(f"agentify update failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result

    def _run(self, args):
        subprocess.run(args, cwd=self.base, text=True, check=True, capture_output=True)

    def _capture(self, args) -> str:
        return subprocess.run(args, cwd=self.base, text=True, check=True, capture_output=True).stdout


if __name__ == "__main__":
    unittest.main()
