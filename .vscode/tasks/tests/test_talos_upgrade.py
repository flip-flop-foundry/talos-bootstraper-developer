"""Offline regression tests: python3 -m unittest discover -s .vscode/tasks/tests -v."""

import json
import os
from pathlib import Path
import pty
import re
import signal
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "talos-upgrade.sh"
SOURCE = SCRIPT.read_text()
FUNCTIONS = "\n".join(
    re.findall(r"^\w+\(\) \{\n.*?^\}", SOURCE, re.MULTILINE | re.DOTALL)
)
MOCKS = r"""
set -euo pipefail
declare -A restore_argocd_automated=()
restore_longhorn_policy=''
longhorn_poll_pid=''
STORAGE_SETTLE_TIMEOUT=60
kubectl() {
  case " $* " in
    *" get crd "*)
      case "${CRD_RESULT:-present}" in
        absent) echo 'Not Found' >&2; return 1 ;;
        error) echo 'Forbidden' >&2; return 1 ;;
        transient)
          if [[ ! -f "$FIXTURES/crd-retried" ]]; then
            touch "$FIXTURES/crd-retried"
            echo 'API temporarily unavailable' >&2; return 1
          fi ;;
      esac ;;
    *" get volumes.longhorn.io "*)
      local count
      count=$(<"$FIXTURES/count")
      count=$((count + 1))
      echo "$count" >"$FIXTURES/count"
      if [[ "${VOLUME_ERROR_FIRST:-false}" == true && "$count" == 1 ]]; then
        echo 'volume query temporarily unavailable' >&2; return 1
      fi
      if [[ "${HEALTHY_AFTER:-0}" -gt 0 && "$count" -ge "$HEALTHY_AFTER" ]]; then
        cat "$FIXTURES/healthy.json"
      else
        cat "$FIXTURES/volumes.json"
      fi ;;
    *" get replicas.longhorn.io "*) cat "$FIXTURES/replicas.json" ;;
    *" get engines.longhorn.io "*)
      if [[ "${ENGINE_ERROR:-false}" == true ]]; then
        echo 'engine access denied' >&2; return 1
      fi
      local count
      count=$(<"$FIXTURES/count")
      if [[ "$count" -ge 2 && -f "$FIXTURES/engines-next.json" ]]; then
        cat "$FIXTURES/engines-next.json"
      else
        cat "$FIXTURES/engines.json"
      fi ;;
    *" get application "*) cat "$FIXTURES/application.json" ;;
    *" patch "*)
      printf '%s\n' "$*" >>"$FIXTURES/patches"
      if [[ "${RESTORE_ERROR:-false}" == true && " $* " == *" patch settings.longhorn.io "* ]]; then
        echo 'patch access denied' >&2; return 1
      fi
      if [[ "${PAUSE_ERROR:-false}" == true && "$*" == *'"automated":null'* ]]; then
        echo 'pause interrupted after patch' >&2; return 1
      fi ;;
    *) echo "Unexpected kubectl: $*" >&2; return 1 ;;
  esac
}
"""
TRAPS = "\n".join(line for line in SOURCE.splitlines() if line.startswith("trap ")) + r"""
restore_longhorn_policy='block-if-contains-last-replica'
pause_argocd_autosync longhorn-system/longhorn
"""


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fixtures = Path(self.temp.name)
        (self.fixtures / "count").write_text("0")
        self.write("volumes", {"items": [
            {"metadata": {"name": "volume-a"}, "status": {"robustness": "degraded"}},
            {"metadata": {"name": "unrelated"}, "status": {"robustness": "faulted"}},
        ]})
        self.write("healthy", {"items": [
            {"metadata": {"name": "volume-a"}, "status": {"robustness": "healthy"}},
        ]})
        self.write("replicas", {"items": [
            {"metadata": {"name": "replica-a"},
             "spec": {"volumeName": "volume-a", "nodeID": "node-a", "failedAt": ""},
             "status": {"currentState": "running"}},
            {"metadata": {"name": "replica-b"},
             "spec": {"volumeName": "volume-a", "nodeID": "node-b", "failedAt": ""},
             "status": {"currentState": "running"}},
            {"metadata": {"name": "replica-failed"},
             "spec": {"volumeName": "unrelated", "nodeID": "node-a", "failedAt": "yesterday"},
             "status": {"currentState": "stopped"}},
        ]})
        self.engine = {
            "spec": {"volumeName": "volume-a",
                     "replicaAddressMap": {"replica-b": "10.0.0.2:10000"}},
            "status": {"rebuildStatus": {
                "tcp://10.0.0.2:10000": {"progress": 25, "state": "in_progress", "error": ""},
            }},
        }
        self.write("engines", {"items": [self.engine]})
        self.automated = {"prune": True, "selfHeal": False, "allowEmpty": True}
        self.write("application", {"spec": {"syncPolicy": {"automated": self.automated}}})

    def write(self, name, value):
        (self.fixtures / f"{name}.json").write_text(json.dumps(value))

    def command(self, body):
        return ["bash", "-c", FUNCTIONS + "\n" + MOCKS + "\n" + body]

    def environment(self, **overrides):
        return dict(os.environ, FIXTURES=str(self.fixtures), **overrides)

    def run_shell(self, body, **overrides):
        return subprocess.run(
            self.command(body), env=self.environment(**overrides),
            capture_output=True, text=True, timeout=5,
        )

    def assert_restored(self):
        patches = (self.fixtures / "patches").read_text().splitlines()
        self.assertEqual(len(patches), 3)
        self.assertIn('"automated":null', patches[0])
        self.assertIn('"value":"block-if-contains-last-replica"', patches[1])
        automated = json.loads(patches[2].split(" -p ", 1)[1])
        self.assertEqual(automated["spec"]["syncPolicy"]["automated"], self.automated)

    def test_waits_with_percentage_updates_until_healthy(self):
        self.engine["status"]["rebuildStatus"]["tcp://10.0.0.2:10000"]["progress"] = 80
        self.write("engines-next", {"items": [self.engine]})
        result = self.run_shell(
            "wait_for_longhorn_poll() { :; }\n"
            "wait_for_longhorn_healthy node-a || fail 'wait failed'\necho NEXT_NODE",
            HEALTHY_AFTER="3",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("replica replica-b node=node-b", result.stdout)
        self.assertIn("rebuild replica-b: 25%", result.stdout)
        self.assertIn("rebuild replica-b: 80%", result.stdout)
        self.assertIn("all volumes with a replica on node-a are healthy", result.stdout)
        self.assertNotIn("unrelated", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("NEXT_NODE"))

    def test_cluster_scope_and_failed_replica_exclusion(self):
        scoped = self.run_shell("longhorn_unhealthy_volumes node-a")
        self.assertEqual(scoped.stdout.strip(), "volume-a degraded")
        cluster = self.run_shell("longhorn_unhealthy_volumes")
        self.assertIn("unrelated faulted", cluster.stdout)

    def test_missing_progress_is_not_fabricated(self):
        self.write("engines", {"items": []})
        result = self.run_shell("longhorn_rebuild_progress 'volume-a degraded'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("progress unavailable", result.stdout)
        self.assertNotIn("0%", result.stdout)

    def test_missing_percentage_and_unmapped_address_are_explicit(self):
        self.engine["spec"]["replicaAddressMap"] = {}
        del self.engine["status"]["rebuildStatus"]["tcp://10.0.0.2:10000"]["progress"]
        self.write("engines", {"items": [self.engine]})
        result = self.run_shell("longhorn_rebuild_progress 'volume-a degraded'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rebuild tcp://10.0.0.2:10000: progress unavailable", result.stdout)

    def test_rebuild_errors_are_displayed(self):
        self.engine["status"]["rebuildStatus"]["tcp://10.0.0.2:10000"]["error"] = "disk full"
        self.write("engines", {"items": [self.engine]})
        result = self.run_shell("longhorn_rebuild_progress 'volume-a degraded'")
        self.assertIn("error=disk full", result.stdout)

    def test_query_errors_fail_visibly(self):
        result = self.run_shell("STORAGE_SETTLE_TIMEOUT=0\n"
                                "wait_for_longhorn_healthy node-a || fail 'wait failed'",
                                ENGINE_ERROR="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("engine access denied", result.stderr)
        self.assertIn("unable to query engine rebuild progress", result.stderr)

    def test_crd_absence_skips_but_api_failure_aborts(self):
        absent = self.run_shell("wait_for_longhorn_healthy node-a", CRD_RESULT="absent")
        self.assertEqual(absent.returncode, 0, absent.stderr)
        error = self.run_shell("STORAGE_SETTLE_TIMEOUT=0\nwait_for_longhorn_healthy node-a",
                               CRD_RESULT="error")
        self.assertNotEqual(error.returncode, 0)
        self.assertIn("Forbidden", error.stderr)

    def test_transient_api_errors_are_retried_without_skipping_health_gate(self):
        for overrides in [{"VOLUME_ERROR_FIRST": "true"}, {"CRD_RESULT": "transient"}]:
            with self.subTest(overrides=overrides):
                (self.fixtures / "count").write_text("0")
                result = self.run_shell(
                    "wait_for_longhorn_poll() { :; }\n"
                    "wait_for_longhorn_healthy node-a || fail 'wait failed'\necho NEXT_NODE",
                    HEALTHY_AFTER="2", **overrides,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("temporarily unavailable", result.stderr)
                self.assertIn("retrying without upgrading any node", result.stdout)
                self.assertIn("all volumes with a replica on node-a are healthy", result.stdout)
                self.assertTrue(result.stdout.rstrip().endswith("NEXT_NODE"))

    def test_progress_query_error_does_not_prevent_health_recovery(self):
        result = self.run_shell(
            "wait_for_longhorn_poll() { :; }\nwait_for_longhorn_healthy node-a",
            ENGINE_ERROR="true", HEALTHY_AFTER="2",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("engine access denied", result.stderr)
        self.assertIn("all volumes with a replica on node-a are healthy", result.stdout)

    def test_timeout_restores_settings_and_stops_next_node(self):
        result = self.run_shell(TRAPS + "\nSTORAGE_SETTLE_TIMEOUT=0\n"
                                "wait_for_longhorn_healthy node-a || fail 'still degraded'\n"
                                "echo NEXT_NODE")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("not confirmed healthy after 0s", result.stdout)
        self.assertNotIn("NEXT_NODE", result.stdout)
        self.assert_restored()

    def test_q_cancels_terminal_wait_and_restores_settings(self):
        master, slave = pty.openpty()
        try:
            os.write(master, b"q\n")
            result = subprocess.run(
                self.command(TRAPS + "\nwait_for_longhorn_healthy node-a\necho NEXT_NODE"),
                env=self.environment(), stdin=slave, capture_output=True, text=True, timeout=5,
            )
        finally:
            os.close(master)
            os.close(slave)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertIn("operator pressed q", result.stdout)
        self.assertNotIn("NEXT_NODE", result.stdout)
        self.assert_restored()

    def test_signals_cancel_wait_and_restore_settings(self):
        for sig, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143)]:
            with self.subTest(signal=sig):
                (self.fixtures / "patches").write_text("")
                process = subprocess.Popen(
                    self.command(TRAPS + "\nwait_for_longhorn_healthy node-a\necho NEXT_NODE"),
                    env=self.environment(), stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                try:
                    prefix = ""
                    while "rebuild replica-b: 25%" not in prefix:
                        line = process.stdout.readline()
                        self.assertTrue(line, "wait exited before reporting progress")
                        prefix += line
                    process.send_signal(sig)
                    stdout, stderr = process.communicate(timeout=5)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                self.assertEqual(process.returncode, expected, stderr)
                self.assertNotIn("NEXT_NODE", stdout)
                self.assert_restored()

    def test_success_cleanup_is_idempotent(self):
        result = self.run_shell(TRAPS + "\ncleanup\ncleanup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_restored()

    def test_ambiguous_pause_failure_still_restores_original_settings(self):
        result = self.run_shell(TRAPS, PAUSE_ERROR="true")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("failed to pause ArgoCD", result.stderr)
        self.assert_restored()

    def test_cleanup_failure_still_restores_argocd_and_exits_nonzero(self):
        result = self.run_shell(TRAPS, RESTORE_ERROR="true")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("restore manually to block-if-contains-last-replica", result.stderr)
        self.assert_restored()


if __name__ == "__main__":
    unittest.main()
