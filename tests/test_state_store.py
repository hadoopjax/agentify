import os
import tempfile
import unittest

from lib import state_store


class StateStoreTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.agentify_dir = self.tempdir.name
        state_store.init_db(self.agentify_dir)

    def tearDown(self):
        self.tempdir.cleanup()

    def test_kv_worker_and_event_roundtrip(self):
        state_store.set_kv("completed", 2, self.agentify_dir)
        self.assertEqual(state_store.get_kv("completed", self.agentify_dir), "2")
        self.assertEqual(state_store.increment_kv("completed", self.agentify_dir), 3)

        state_store.worker_set("42", "phase", "coding", self.agentify_dir)
        state_store.worker_set("42", "title", "Example", self.agentify_dir)
        self.assertEqual(state_store.worker_get("42", self.agentify_dir)["phase"], "coding")
        self.assertIn("42", state_store.list_workers(self.agentify_dir))

        event_id = state_store.emit_event("coding_start", "[#42] started", self.agentify_dir)
        events = state_store.list_events(0, self.agentify_dir)
        self.assertEqual(event_id, events[0]["id"])
        self.assertEqual(events[0]["type"], "coding_start")

    def test_documents_are_persisted_in_snapshot(self):
        state_store.save_epic({"id": "1", "title": "Epic", "status": "planning", "proposals": []}, self.agentify_dir)
        state_store.save_proposal({"id": "2", "status": "pending", "features": []}, self.agentify_dir)
        state_store.save_interview({"id": "3", "status": "interviewing", "questions": []}, self.agentify_dir)

        snapshot = state_store.load_snapshot(self.agentify_dir)
        self.assertEqual(snapshot.epics[0]["title"], "Epic")
        self.assertEqual(snapshot.proposals[0]["id"], "2")
        self.assertEqual(snapshot.interviews[0]["id"], "3")


if __name__ == "__main__":
    unittest.main()
