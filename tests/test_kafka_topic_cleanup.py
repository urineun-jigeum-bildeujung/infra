"""Guarded finalization of backed-up topics whose broker has stopped."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('topic_cleanup', str(ROOT / 'scripts/release-kafka-topic-finalizers.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TopicCleanupTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.topics = [{'metadata': {'name': 'user-signed-up', 'deletionTimestamp': 'now',
            'labels': {'strimzi.io/cluster': 'pet-subscription-kafka'},
            'finalizers': ['strimzi.io/topic-operator', 'other.io/protection']}}]
        self.broker = None
        self.operator = {'spec': {'replicas': 0}, 'status': {}}
        self.volume = {'State': 'available', 'Attachments': []}
        self.state = {'podName': 'broker-0', 'clusterId': 'existing-id',
                      'volumes': [{'volumeId': 'vol-test'}], 'topics': copy.deepcopy(self.topics)}
        def get(kind, name=None, namespace=None):
            if kind == 'kafkatopics': return {'items': self.topics}
            if kind == 'deployment': return self.operator
            if kind == 'pod': return self.broker
            if kind == 'kafka': return {'status': {'clusterId': 'existing-id'}}
            raise AssertionError(kind)
        replacements = [
            (module.common, 'get', get),
            (module.common, 'load', lambda p: {'status': 'deleting'} if str(p).endswith('maintenance.json') else {'runId': 'run', 'kafka': {}}),
            (module.common, 'download', lambda r: self.state),
            (module.common, 'aws', lambda *a: {'Volumes': [self.volume]}),
            (module.control, 'evidence_directory', lambda: Path(self.folder.name)),
        ]
        for owner, name, value in replacements:
            p = patch.object(owner, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(module.common, 'kube')
        self.kube = p.start()
        self.addCleanup(p.stop)
        p = patch.object(module.control, 'verify_manifest')
        self.guard = p.start()
        self.addCleanup(p.stop)

    def test_preserves_other_finalizers_and_records_evidence(self):
        self.assertEqual(module.release('manifest'), ['user-signed-up'])
        data = json.loads(self.kube.call_args[0][-1])
        self.assertEqual(data['metadata']['finalizers'], ['other.io/protection'])
        self.guard.assert_called_once()
        self.assertTrue((Path(self.folder.name) / 'run-topic-cleanup.json').exists())

    def test_failed_backup_guard_prevents_changes(self):
        self.guard.side_effect = RuntimeError('backup incomplete')
        with self.assertRaises(RuntimeError): module.release('manifest')
        self.kube.assert_not_called()

    def test_running_broker_prevents_changes(self):
        self.broker = {'metadata': {'name': 'broker-0'}}
        with self.assertRaises(RuntimeError): module.release('manifest')
        self.kube.assert_not_called()

    def test_attached_disk_prevents_changes(self):
        self.volume = {'State': 'in-use', 'Attachments': [{}]}
        with self.assertRaises(RuntimeError): module.release('manifest')
        self.kube.assert_not_called()

    def test_unbacked_topic_prevents_all_changes(self):
        self.topics.append({'metadata': {'name': 'not-in-backup'}})
        with self.assertRaises(RuntimeError): module.release('manifest')
        self.kube.assert_not_called()

    def test_empty_topic_set_is_idempotent(self):
        self.topics = []
        self.assertEqual(module.release('manifest'), [])
        self.guard.assert_not_called()
        self.kube.assert_not_called()


if __name__ == '__main__':
    unittest.main()
