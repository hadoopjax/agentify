import tempfile
import unittest
from unittest.mock import patch

from lib import control_plane
from lib import state_store


class ControlPlaneTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.agentify_dir = self.tempdir.name
        state_store.init_db(self.agentify_dir)
        self._orig_get_epic = control_plane.get_epic
        self._orig_save_epic = control_plane.save_epic
        self._orig_emit_event = control_plane.emit_event
        control_plane.get_epic = lambda epic_id: state_store.get_epic(epic_id, self.agentify_dir)
        control_plane.save_epic = lambda payload: state_store.save_epic(payload, self.agentify_dir)
        control_plane.emit_event = lambda event_type, msg: state_store.emit_event(event_type, msg, self.agentify_dir)

    def tearDown(self):
        control_plane.get_epic = self._orig_get_epic
        control_plane.save_epic = self._orig_save_epic
        control_plane.emit_event = self._orig_emit_event
        self.tempdir.cleanup()

    def test_approve_epic_action_includes_agentify_metadata(self):
        epic = {
            "id": "123",
            "title": "Validation Epic",
            "status": "planning",
            "proposals": [
                {
                    "title": "Implement thing",
                    "body": "Do the work",
                    "status": "pending",
                    "validation_commands": ["python3 -m unittest"],
                    "required_checks": ["ci / test"],
                    "files_of_interest": ["lib/foo.py"],
                }
            ],
        }
        state_store.save_epic(epic, self.agentify_dir)

        captured = {}

        def fake_gh(args, cwd=None, timeout=30):
            captured["args"] = args

            class Result:
                returncode = 0
                stdout = "https://github.com/example/repo/issues/77"
                stderr = ""

            return Result()

        with patch.object(control_plane, "_gh", side_effect=fake_gh):
            result = control_plane.approve_epic_action("123", 0, "/tmp/repo")

        self.assertEqual(result["issue_number"], 77)
        created_body = captured["args"][captured["args"].index("--body") + 1]
        self.assertIn("```agentify", created_body)
        self.assertIn("validation_commands", created_body)
        persisted = state_store.get_epic("123", self.agentify_dir)
        self.assertEqual(persisted["proposals"][0]["status"], "approved")
        self.assertEqual(persisted["proposals"][0]["issue_number"], 77)


if __name__ == "__main__":
    unittest.main()
