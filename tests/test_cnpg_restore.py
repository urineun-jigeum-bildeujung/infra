"""Offline branch checks for the restore-before-GitOps flow."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/restore-cnpg-before-gitops.sh"


class RestoreFlowTests(unittest.TestCase):
    def run_flow(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            captured = root / "cluster.json"
            store_capture = root / "objectstore.json"
            marker = root / "marker.json"
            marker.write_text(json.dumps({
                "schemaVersion": 1,
                "destinationPath": "s3://petflow-dev-db-backups/cnpg/previous",
                "serverName": "petflow-db",
                "backupName": "backup-previous",
                "completedAt": "2026-09-20T00:00:00Z",
            }))
            (bin_dir / "aws").write_text("""#!/usr/bin/env python3
import os, sys, shutil
a = sys.argv[1:]
if a[:2] == ['s3api', 'get-object']:
    shutil.copyfile(os.environ['TEST_MARKER'], a[-1]); sys.exit(0)
if a[:2] != ['s3api', 'list-objects-v2']:
    sys.exit(2)
prefix = a[a.index('--prefix') + 1]
mode = os.environ['TEST_MODE']
if prefix == 'cnpg/recovery/latest.json':
    print(prefix if mode not in ('initdb', 'orphan') else 'None')
elif prefix.startswith('cnpg/generations/'):
    print('1' if mode == 'orphan' else '0')
elif prefix == 'cnpg/petflow-db/base/':
    print('0')
elif prefix.startswith('cnpg/previous/petflow-db/'):
    print('0' if mode == 'broken' and '/base/' in prefix else '1')
else:
    sys.exit(3)
""")
            (bin_dir / "kubectl").write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
if 'get' in a and 'cluster' in a:
    sys.exit(1)
if 'create' in a:
    print('{"kind":"Namespace"}'); sys.exit(0)
if 'apply' in a:
    source = a[a.index('-f') + 1]
    raw = sys.stdin.read() if source == '-' else pathlib.Path(source).read_text()
    try:
        document = json.loads(raw)
        if document.get('kind') == 'Cluster':
            pathlib.Path(os.environ['TEST_CAPTURE']).write_text(raw)
        if document.get('kind') == 'ObjectStore' and document['metadata']['name'] == 'petflow-db-backups':
            pathlib.Path(os.environ['TEST_STORE_CAPTURE']).write_text(raw)
    except ValueError:
        pass
    sys.exit(0)
if 'wait' in a:
    sys.exit(0)
sys.exit(4)
""")
            (bin_dir / "helm").write_text("#!/bin/sh\nexit 0\n")
            backup = bin_dir / "backup"
            backup.write_text("#!/bin/sh\nexit 0\n")
            for binary in bin_dir.iterdir():
                binary.chmod(0o755)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                       TEST_MODE=mode, TEST_MARKER=str(marker),
                       TEST_CAPTURE=str(captured), CNPG_BACKUP_SCRIPT=str(backup),
                       TEST_STORE_CAPTURE=str(store_capture),
                       KUBECONFIG=str(root / "kubeconfig"))
            result = subprocess.run([str(SCRIPT)], env=env, universal_newlines=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    check=False)
            document = json.loads(captured.read_text()) if captured.exists() else None
            store = json.loads(store_capture.read_text()) if store_capture.exists() else None
            return result, document, store

    def test_no_backup_initializes_new_database(self):
        result, document, store = self.run_flow("initdb")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(document["spec"]["bootstrap"],
                         {"initdb": {"database": "app", "owner": "app"}})
        self.assertEqual(document["spec"]["externalClusters"], [])
        self.assertTrue(store["spec"]["configuration"]["destinationPath"].startswith(
            "s3://petflow-dev-db-backups/cnpg/generations/"))

    def test_backup_restores_from_previous_generation(self):
        result, document, store = self.run_flow("restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(document["spec"]["bootstrap"],
                         {"recovery": {"source": "previous-generation"}})
        self.assertEqual(document["spec"]["externalClusters"][0]["plugin"]["parameters"],
                         {"barmanObjectName": "petflow-db-restore-source",
                          "serverName": "petflow-db"})
        self.assertNotEqual(store["spec"]["configuration"]["destinationPath"],
                            "s3://petflow-dev-db-backups/cnpg/previous")

    def test_missing_base_does_not_fall_back_to_initdb(self):
        result, document, store = self.run_flow("broken")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(document)
        self.assertIsNone(store)
        self.assertIn("initdb로 넘어가지 않습니다", result.stderr)

    def test_orphaned_generation_does_not_initialize(self):
        result, document, store = self.run_flow("orphan")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(document)
        self.assertIsNone(store)
        self.assertIn("marker 없이 이전 세대 데이터", result.stderr)


if __name__ == "__main__":
    unittest.main()
