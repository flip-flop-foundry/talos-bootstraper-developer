"""Offline hook/renderer/publication tests. Never uses live Kubernetes or Gitea."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import re
import tempfile
import unittest

TASKS = Path(__file__).resolve().parents[1]
BASE_REPO = Path(os.environ.get("TALOS_BOOTSTRAPER_DIR",
                 str(Path(os.environ.get("TALOS_BOOTSTRAPPER_DATA_DIR", "/workspaces/talos-bootstrapper-data")) / "talos-bootstraper")))
MIGRATION = BASE_REPO / "base/deploymentHooks/beforeArgo/20-gateway-api-migration.sh"
SYNC = "argocd.argoproj.io/sync-options"
TRACK = "argocd.argoproj.io/tracking-id"
REFRESH = "argocd.argoproj.io/refresh"
GROUP = "gateway.networking.k8s.io"
NAMES = ("backendtlspolicies", "gatewayclasses", "gateways", "grpcroutes",
         "httproutes", "listenersets", "referencegrants", "tcproutes", "tlsroutes", "udproutes")

MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
# Kustomize is a local build, not an API operation; use the actual installed
# client to validate real transformations while mocking every API call.
if args and args[0] == "kustomize":
    import shutil
    real = shutil.which("kubectl", path=os.environ["REAL_PATH"])
    os.execv(real, [real, *args])
statefile = Path(os.environ["MOCK_STATE"])
state = json.loads(statefile.read_text())
with open(os.environ["MOCK_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\n")
while args and (args[0] == "--context" or args[0].startswith("--request-timeout=")):
    if args[0] == "--context":
        del args[:2]
    else:
        del args[0]
def emit(value):
    if value is not None:
        print(json.dumps(value))
def error(message):
    print(message, file=sys.stderr)
    sys.exit(1)
if args[0] == "config":
    if args[1] == "current-context":
        print(state.get("context", "admin@demo"))
    elif "context.cluster" in args[-1]:
        print(state.get("cluster", "demo"))
    else:
        print(state.get("server", "https://demo.example:6443"))
elif args[:3] == ["get", "--raw", "/readyz"]:
    if state.get("unreachable"):
        error("connection refused")
    print("ok")
elif args[0] == "get":
    kind = args[1]
    if state.get("forbidden") == kind:
        error("Forbidden")
    if kind == "crd" and args[2] == "applications.argoproj.io":
        automated = {"prune": {"type": "boolean"}}
        if state.get("enabled_schema", True):
            automated["enabled"] = {"type": "boolean"}
        schema = {"properties": {"spec": {"properties": {"syncPolicy": {"properties": {
            "automated": {"properties": automated}}}}}}}
        emit({"kind": "CustomResourceDefinition", "spec": {"versions": [
            {"name": "v1alpha1", "schema": {"openAPIV3Schema": schema}}]}} if state.get("api", True) else None)
    elif kind == "applications.argoproj.io":
        app = state.get("app")
        if app:
            # Simulated application controller: acknowledges refresh requests
            # and reports a running sync for "busy_polls" reads.
            annotations = app["metadata"].setdefault("annotations", {})
            if "argocd.argoproj.io/refresh" in annotations and state.get("controller_running", True):
                del annotations["argocd.argoproj.io/refresh"]
            if state.get("busy_polls", 0) > 0:
                state["busy_polls"] -= 1
                app["operation"] = {"sync": {}}
            else:
                app.pop("operation", None)
            automated = app["spec"].get("syncPolicy", {}).get("automated")
            if state.get("reenable") and automated and automated.get("enabled") is False:
                automated["enabled"] = True
            statefile.write_text(json.dumps(state))
        emit(app)
    elif kind == "crds":
        emit({"items": state.get("crds", [])})
    elif kind == "crd":
        emit(next(x for x in state["crds"] if x["metadata"]["name"] == args[2]))
    elif kind == "configmap":
        emit({"data": state.get("config", {"application.resourceTrackingMethod": "annotation+label"})})
    else:
        error("Unexpected get: " + str(args))
elif args[0] == "patch":
    if state.get("patch_failure") == args[1]:
        error("patch conflict/Forbidden")
    obj = state["app"] if args[1] == "applications.argoproj.io" else next(x for x in state["crds"] if x["metadata"]["name"] == args[2])
    patch = json.loads(args[args.index("-p") + 1])
    if patch[0]["op"] != "test" or patch[0]["value"] != obj["metadata"]["resourceVersion"]:
        error("Missing/stale resourceVersion precondition")
    for op in patch[1:]:
        parts = [p.replace("~1", "/").replace("~0", "~") for p in op["path"].strip("/").split("/")]
        target = obj
        for part in parts[:-1]:
            target = target.setdefault(part, {})
        target[parts[-1]] = op["value"]
    obj["metadata"]["resourceVersion"] = str(int(obj["metadata"]["resourceVersion"]) + 1)
    if state.get("break_verify") and args[1] == "crd":
        obj["metadata"]["annotations"].pop("argocd.argoproj.io/sync-options", None)
    statefile.write_text(json.dumps(state))
    emit(obj)
else:
    error("Unexpected command: " + str(args))
'''


def crd(name="gateways", owner="traefik_traefik", channel="standard", version="v1.3.0", opts="Validate=false"):
    full = name + "." + GROUP
    annotations = {"gateway.networking.k8s.io/channel": channel,
                   "gateway.networking.k8s.io/bundle-version": version}
    if owner:
        annotations[TRACK] = f"{owner}:apiextensions.k8s.io/CustomResourceDefinition:/{full}"
    if opts:
        annotations[SYNC] = opts
    return {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
            "metadata": {"name": full, "resourceVersion": "1", "annotations": annotations},
            "spec": {"group": GROUP, "versions": [{"name": "v1", "served": True, "storage": True}]},
            "status": {"storedVersions": ["v1"]}}


def default_state():
    return {
        "app": {"metadata": {"name": "traefik", "namespace": "traefik", "resourceVersion": "1"},
                "spec": {"sources": [{"chart": "traefik", "repoURL": "https://traefik.github.io/charts",
                                      "targetRevision": "39.0.8"}],
                         "syncPolicy": {"automated": {"prune": True, "selfHeal": True}}},
                "status": {"resources": [{"group": "apiextensions.k8s.io", "kind": "CustomResourceDefinition",
                                          "name": "gateways." + GROUP}]}},
        "crds": [crd()],
    }


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.repo = self.data / "talos-bootstraper"
        self.base = self.repo / "base"
        self.overlay = self.data / "environments/demo"
        self.base.mkdir(parents=True)
        self.overlay.mkdir(parents=True)
        self.envfile = self.overlay / "demo.env"
        self.envfile.write_text('export OVERLAY_NAME="demo"\nexport TALOS_CLUSTER_NAME="demo"\n'
                                'export TALOS_CLUSTER_ENDPOINT="demo.example"\nexport TOKEN="substitution"\n'
                                'export GITEA_CLUSTER_SERVICES_REPO_URL="https://git.example/cluster/services.git"\n'
                                'export GITEA_CLUSTER_SERVICES_REPO_BRANCH="main"\n')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "kubectl").write_text(MOCK_KUBECTL)
        (self.bin / "kubectl").chmod(0o755)
        self.statefile = self.root / "state.json"
        self.callsfile = self.root / "calls.jsonl"
        self.write_state(default_state())
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        REAL_PATH=os.environ["PATH"],
                        TALOS_BOOTSTRAPPER_DATA_DIR=str(self.data), TALOS_BOOTSTRAPER_DIR=str(self.repo),
                        MOCK_STATE=str(self.statefile), MOCK_CALLS=str(self.callsfile),
                        HOOK_KUBE_CONTEXT="admin@demo", ARGOCD_NAMESPACE="argocd",
                        GITEA_CLUSTER_SERVICES_REPO_URL="https://git.example/cluster/services.git",
                        GITEA_CLUSTER_SERVICES_REPO_BRANCH="main")

    def write_state(self, state):
        self.statefile.write_text(json.dumps(state))

    def calls(self):
        return [json.loads(line) for line in self.callsfile.read_text().splitlines()] if self.callsfile.exists() else []

    def run_cmd(self, argv):
        # New session: no controlling terminal, so approval prompts fail closed.
        return subprocess.run([str(x) for x in argv], env=self.env, text=True, capture_output=True, timeout=30,
                              start_new_session=True)

    def hook(self, root, filename, content):
        file = root / "deploymentHooks/beforeArgo" / filename
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        return file

    def render(self, *args):
        return self.run_cmd([TASKS / "render-overlay.sh", self.envfile, *args])

    def runner(self, *args):
        return self.run_cmd([TASKS / "run-deployment-hooks.sh", self.envfile, "beforeArgo", *args])


class FrameworkTests(Fixture):
    def test_render_is_side_effect_free_and_scripts_are_verbatim(self):
        file = self.hook(self.base, "20-a.sh", '#!/bin/bash\nprintf "%s" "$TOKEN" > "$MARKER"\n')
        self.env["MARKER"] = str(self.root / "unexpected")
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse(Path(self.env["MARKER"]).exists())
        self.assertEqual((self.overlay / "_rendered/deploymentHooks/beforeArgo/20-a.sh").read_bytes(), file.read_bytes())
        self.assertEqual(self.calls(), [])

    def test_overlay_replacement_and_deterministic_order(self):
        self.env["EVENTS"] = str(self.root / "events")
        self.hook(self.base, "20-b.sh", 'echo base >> "$EVENTS"\n')
        self.hook(self.base, "10-a.sh", 'echo first >> "$EVENTS"\n')
        self.hook(self.overlay, "20-b.sh", 'echo overlay >> "$EVENTS"\n')
        result = self.runner()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(Path(self.env["EVENTS"]).read_text(), "first\noverlay\n")
        self.assertFalse((self.overlay / "_rendered").exists(), "runner render must be isolated")

    def test_whole_and_exact_exclusions_apply_to_overlays(self):
        self.hook(self.base, "10-a.sh", "exit 99\n")
        self.hook(self.overlay, "10-a.sh", "exit 98\n")
        self.hook(self.base, "20-b.sh", "exit 0\n")
        for excluded in ("deploymentHooks", "deploymentHooks/beforeArgo/10-a.sh"):
            self.envfile.write_text(self.envfile.read_text().split("EXCLUDED_BASE")[0] +
                                    f'EXCLUDED_BASE=("{excluded}")\n')
            result = self.runner()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_phase_prefix_is_not_recursive_exclusion(self):
        self.hook(self.base, "10-a.sh", "exit 99\n")
        with self.envfile.open("a") as env:
            env.write('EXCLUDED_BASE=("deploymentHooks/beforeArgo")\n')
        self.assertNotEqual(self.runner().returncode, 0)

    def test_stale_rendered_hook_is_not_executed(self):
        self.hook(self.overlay / "_rendered", "10-a.sh", "exit 99\n")
        result = self.runner()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.calls(), [])

    def test_fail_fast_does_not_execute_later_hooks(self):
        self.env["EVENTS"] = str(self.root / "events")
        self.hook(self.base, "10-a.sh", "exit 7\n")
        self.hook(self.base, "20-b.sh", 'echo unsafe >> "$EVENTS"\n')
        self.assertNotEqual(self.runner().returncode, 0)
        self.assertFalse(Path(self.env["EVENTS"]).exists())

    def test_dry_run_executes_nothing_and_reserved_phase_rejected(self):
        self.hook(self.base, "10-a.sh", "exit 99\n")
        self.assertEqual(self.runner("--dry-run").returncode, 0)
        self.assertEqual(self.calls(), [])
        result = self.run_cmd([TASKS / "run-deployment-hooks.sh", self.envfile, "beforeTalos"])
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_cluster_endpoint_or_context_blocks_hooks(self):
        self.env["EVENTS"] = str(self.root / "events")
        self.hook(self.base, "10-a.sh", 'echo unsafe >> "$EVENTS"\n')
        for change in ({"cluster": "other"}, {"server": "https://wrong:6443"}, {"context": "other"}):
            state = default_state()
            state.update(change)
            self.write_state(state)
            self.env["DEPLOYMENT_HOOK_KUBE_CONTEXT"] = "admin@demo"
            result = self.runner()
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(self.env["EVENTS"]).exists())

    def test_hook_environment_and_render_overrides_agree(self):
        self.env["EVENTS"] = str(self.root / "events")
        values = self.base / "example/values.yaml"
        values.parent.mkdir()
        values.write_text("value: ${TOKEN}\n")
        self.hook(self.base, "10-a.sh", 'test "$TOKEN" = override\n'
                  'test "$(yq .value "$HOOK_RENDERED_DIR/example/values.yaml")" = override\n')
        result = self.runner("TOKEN=override")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_excluded_and_removed_manifests_are_pruned_but_talos_is_preserved(self):
        manifest = self.base / "example/app.yaml"
        manifest.parent.mkdir()
        manifest.write_text("kind: ConfigMap\n")
        rendered = self.overlay / "_rendered"
        (rendered / "talos/generated").mkdir(parents=True)
        secret = rendered / "talos/generated/keep.yaml"
        secret.write_text("DO NOT TOUCH")
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        with self.envfile.open("a") as env:
            env.write('EXCLUDED_BASE=("example/app.yaml")\n')
        self.assertEqual(self.render().returncode, 0)
        self.assertFalse((rendered / "example/app.yaml").exists())
        self.assertEqual(secret.read_text(), "DO NOT TOUCH")
        manifest.unlink()
        self.assertEqual(self.render().returncode, 0)

    def test_output_symlink_is_rejected_before_cleanup(self):
        destination = self.root / "other/_rendered"
        destination.mkdir(parents=True)
        marker = destination / "keep.yaml"
        marker.write_text("DO NOT DELETE")
        (self.overlay / "_rendered").symlink_to(destination, target_is_directory=True)
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "DO NOT DELETE")

    def test_symlink_discovery_fails_before_execution(self):
        file = self.hook(self.base, "10-a.sh", "exit 0\n")
        file.unlink()
        file.symlink_to("/dev/null")
        result = self.runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular file", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_excluded_component_and_exact_symlink_do_not_block_discovery(self):
        file = self.hook(self.base, "10-a.sh", "exit 0\n")
        file.unlink()
        file.symlink_to("/dev/null")
        with self.envfile.open("a") as env:
            env.write('EXCLUDED_BASE=("deploymentHooks/beforeArgo/10-a.sh")\n')
        self.assertEqual(self.runner().returncode, 0)
        self.envfile.write_text(self.envfile.read_text().split("EXCLUDED_BASE")[0] +
                                'EXCLUDED_BASE=("deploymentHooks")\n')
        self.assertEqual(self.runner().returncode, 0)

    def test_runner_does_not_discover_reserved_phase(self):
        reserved = self.base / "deploymentHooks/beforeTalos"
        reserved.mkdir(parents=True)
        (reserved / "unused.sh").write_text("exit 99\n")
        result = self.runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_required_hook_cannot_be_excluded_while_dependent_app_is_published(self):
        hook = self.hook(self.base, "10-a.sh", "exit 0\n")
        manifest = self.base / "example/app.yaml"
        manifest.parent.mkdir()
        manifest.write_text('kind: Application\nmetadata:\n  name: example\n  annotations:\n'
                            '    bootstrapper.talos.dev/required-before-argo-hook: deploymentHooks/beforeArgo/10-a.sh\n')
        for excluded in ("deploymentHooks", "deploymentHooks/beforeArgo/10-a.sh"):
            self.envfile.write_text(self.envfile.read_text().split("EXCLUDED_BASE")[0] + f'EXCLUDED_BASE=("{excluded}")\n')
            result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires enabled beforeArgo hook", result.stderr)
            self.assertNotIn("Fetching Gitea admin", result.stdout)
            self.assertEqual(self.calls(), [])
        self.envfile.write_text(self.envfile.read_text().split("EXCLUDED_BASE")[0] +
                                'EXCLUDED_BASE=("deploymentHooks" "example")\n')
        result = self.runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        hook.unlink()

    def test_overlay_replacement_satisfies_required_hook_by_exact_path(self):
        self.hook(self.base, "10-a.sh", "exit 99\n")
        self.hook(self.overlay, "10-a.sh", "exit 0\n")
        manifest = self.base / "example/app.yaml"
        manifest.parent.mkdir()
        manifest.write_text('kind: Application\nmetadata:\n  name: example\n  annotations:\n'
                            '    bootstrapper.talos.dev/required-before-argo-hook: deploymentHooks/beforeArgo/10-a.sh\n')
        result = self.runner()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nested_overlay_application_requirement_is_enforced(self):
        self.hook(self.base, "10-a.sh", "exit 0\n")
        manifest = self.overlay / "example/nested/app.yaml"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('kind: Application\nmetadata:\n  name: example\n  annotations:\n'
                            '    bootstrapper.talos.dev/required-before-argo-hook: deploymentHooks/beforeArgo/10-a.sh\n')
        self.envfile.write_text(self.envfile.read_text() + 'EXCLUDED_BASE=("deploymentHooks")\n')
        result = self.runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires enabled beforeArgo hook", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_hook_component_templates_and_yaml_are_not_manifest_inputs(self):
        component = self.base / "deploymentHooks"
        (component / "templates").mkdir(parents=True)
        (component / "bad.yaml").write_text("INVALID YAML")
        (component / "templates/script.sh").write_text("must not publish")
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse((self.overlay / "_rendered/deploymentHooks").exists())

    def test_push_hook_failure_precedes_credentials_clone_and_publication(self):
        self.hook(self.base, "10-a.sh", "exit 7\n")
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("10-a.sh", result.stdout + result.stderr)
        self.assertFalse(any("secret" in call or "patch" in call for call in self.calls()))
        self.assertNotIn("Cloning", result.stdout)

    def test_merge_failure_aborts_actual_push_instead_of_publishing_partial_render(self):
        for root in (self.base, self.overlay):
            file = root / "example/app.yaml"
            file.parent.mkdir()
            file.write_text("kind: ConfigMap\nmetadata:\n  name: example\n")
        mock = self.bin / "yq"
        mock.write_text('#!/bin/bash\nif [[ "$1" == eval-all ]]; then echo "forced merge failure" >&2; exit 7; fi\n'
                        'exec "$(PATH="$REAL_PATH" command -v yq)" "$@"\n')
        mock.chmod(0o755)
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("yq merge failed", result.stdout + result.stderr)
        self.assertNotIn("Cloning", result.stdout)
        self.assertNotIn("Fetching Gitea admin", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_envsubst_failure_aborts_instead_of_copying_unrendered_source(self):
        file = self.base / "example/app.yaml"
        file.parent.mkdir()
        file.write_text("kind: ConfigMap\n")
        mock = self.bin / "envsubst"
        mock.write_text("#!/bin/sh\nexit 7\n")
        mock.chmod(0o755)
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("envsubst failed", result.stdout + result.stderr)
        self.assertNotIn("Fetching Gitea admin", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_invalid_yaml_aborts_before_publication(self):
        file = self.base / "example/app.yaml"
        file.parent.mkdir()
        file.write_text("invalid: [unclosed\n")
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Fetching Gitea admin", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_deferred_talos_template_contract_is_unchanged(self):
        file = self.base / "talos/trustedRootsConfigTemplate.yaml"
        file.parent.mkdir()
        file.write_text("certificates: |-\n${CA_CERT_BODY}\n")
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.overlay / "_rendered/talos/trustedRootsConfigTemplate.yaml").read_bytes(), file.read_bytes())

    def test_push_dry_run_never_queries_cluster(self):
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo", "--dry-run"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_both_publication_filters_exclude_hooks_and_talos(self):
        for script in ("push-to-gitea.sh", "cluster-bootstrap.sh"):
            source = (TASKS / script).read_text()
            line = next(line for line in source.splitlines() if line.startswith("rsync -a") or line.strip().startswith("rsync -a"))
            self.assertIn("--exclude '/deploymentHooks/'", line)
            self.assertIn("--exclude '/talos/'", line)
            src = self.root / script / "src"
            dest = self.root / script / "dest"
            (src / "deploymentHooks/beforeArgo").mkdir(parents=True)
            (src / "talos").mkdir()
            (src / "safe").mkdir()
            (src / "deploymentHooks/beforeArgo/a.sh").write_text("SECRET")
            (src / "talos/secret").write_text("SECRET")
            (src / "safe/app.yaml").write_text("kind: Application")
            dest.mkdir()
            # Execute the actual options from each transport, not a duplicate filter.
            options = line.strip().split('"', 1)[0]
            result = self.run_cmd(["bash", "-c", f'{options} "$1/" "$2/"', "_", src, dest])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((dest / "deploymentHooks").exists())
            self.assertFalse((dest / "talos").exists())
            self.assertTrue((dest / "safe/app.yaml").exists())
        self.assertNotIn('kubectl cp "$OVERLAY_DIR/."', (TASKS / "cluster-bootstrap.sh").read_text())

    def test_all_argo_publication_entrypoints_are_gated(self):
        cluster = (TASKS / "cluster-bootstrap.sh").read_text()
        self.assertLess(cluster.index('run-deployment-hooks.sh'), cluster.index('helm repo list'))
        self.assertLess(cluster.index('run-deployment-hooks.sh', cluster.index('kubectl wait --for=condition=Ready pod/git-bootstrap-server')),
                        cluster.index('kubectl cp "$publish_dir/."'))
        gitea = (TASKS / "gitea-bootstrap.sh").read_text()
        self.assertLess(gitea.index('run-deployment-hooks.sh'), gitea.index('create_gitea_token "$credentials"'))
        customer = (TASKS / "bootstrap-customer.sh").read_text()
        self.assertLess(customer.index('run-deployment-hooks.sh'), customer.index('create_or_update_gitea_file'))

    @unittest.skipUnless(MIGRATION.exists(), "Shared base repository required")
    def test_real_migration_failure_blocks_actual_push_before_credentials(self):
        self.env["TALOS_BOOTSTRAPER_DIR"] = str(BASE_REPO)
        with self.envfile.open("a") as env:
            env.write('export TRAEFIK_HELM_VERSION="42.3.1"\nexport ARGOCD_NAMESPACE="argocd"\n')
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("approval required", result.stderr)
        self.assertNotIn("Fetching Gitea admin", result.stdout)
        self.assertFalse(any("patch" in call or "secret" in call for call in self.calls()))

    @unittest.skipUnless(MIGRATION.exists(), "Shared base repository required")
    def test_fresh_snapshot_exclusion_drops_stale_gateway_and_blocks_handover(self):
        self.env["TALOS_BOOTSTRAPER_DIR"] = str(BASE_REPO)
        stale = self.overlay / "_rendered/gatewayApi/gatewayApiArgoApp.yaml"
        stale.parent.mkdir(parents=True)
        stale.write_text("kind: Application\nmetadata:\n  name: gateway-api\n")
        with self.envfile.open("a") as env:
            env.write('export TRAEFIK_HELM_VERSION="42.3.1"\nexport ARGOCD_NAMESPACE="argocd"\nEXCLUDED_BASE=("gatewayApi")\n')
        result = self.run_cmd([TASKS / "push-to-gitea.sh", "demo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("excluded/missing", result.stderr)
        self.assertFalse(stale.exists())
        self.assertNotIn("Cloning", result.stdout)


@unittest.skipUnless(MIGRATION.exists(), "Shared base repository required for migration tests")
class MigrationTests(Fixture):
    def setUp(self):
        super().setUp()
        self.rendered = self.root / "_rendered"
        self.bundle = self.rendered / "gatewayApi/templates"
        self.bundle.mkdir(parents=True)
        self.env["HOOK_RENDERED_DIR"] = str(self.rendered)
        self.env.update(GATEWAY_API_MIGRATION_APPROVED="true", GATEWAY_API_MIGRATION_POLL_SECONDS="0",
                        GATEWAY_API_MIGRATION_TIMEOUT_SECONDS="5")
        self.files = []
        for name in NAMES:
            file = self.bundle / f"{GROUP}_{name}.yaml"
            file.write_bytes((BASE_REPO / "base/gatewayApi/templates" / file.name).read_bytes())
            self.files.append(file.name)
        vap = self.bundle / f"{GROUP}_vap_safeupgrades.yaml"
        vap.write_bytes((BASE_REPO / "base/gatewayApi/templates" / vap.name).read_bytes())
        self.files.append(vap.name)
        self.kustomization = self.bundle / "kustomization.yaml"
        self.kustomization.write_text(json.dumps({"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
                                                 "resources": self.files, "commonAnnotations": {SYNC: "Prune=false,Delete=false"}}))
        gateway = self.rendered / "gatewayApi/gatewayApiArgoApp.yaml"
        gateway.write_text(json.dumps({"kind": "Application", "metadata": {"name": "gateway-api", "namespace": "argocd"},
                                      "spec": {"source": {"path": "_rendered/gatewayApi/templates",
                                                          "repoURL": self.env["GITEA_CLUSTER_SERVICES_REPO_URL"],
                                                          "targetRevision": "main"},
                                               "destination": {"server": "https://kubernetes.default.svc"},
                                               "syncPolicy": {"syncOptions": ["ServerSideApply=true"]}}}))
        self.gateway = gateway
        self.traefik = self.rendered / "traefik/traefikArgoApp.yaml"
        self.traefik.parent.mkdir()
        self.set_chart("42.3.1")

    def set_chart(self, version, enabled=True):
        automated = {"prune": True, "selfHeal": True}
        if enabled is not None:
            automated["enabled"] = enabled
        self.traefik.write_text(json.dumps({"kind": "Application", "metadata": {"name": "traefik"}, "spec": {
            "sources": [{"chart": "traefik", "repoURL": "https://traefik.github.io/charts", "targetRevision": version}],
            "syncPolicy": {"automated": automated}}}))

    def crd_patches(self):
        return sum(1 for call in self.calls() if "patch" in call and "crd" in call)

    def app_patches(self):
        return sum(1 for call in self.calls() if "patch" in call and "applications.argoproj.io" in call)

    def migrate(self, state=None):
        if state is not None:
            self.write_state(state)
        return self.run_cmd(["bash", MIGRATION])

    def assert_blocked(self, state, text):
        result = self.migrate(state)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(text, result.stderr)

    def test_protects_preserving_options_without_changing_tracking_or_specs(self):
        before = default_state()
        result = self.migrate(before)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        after = json.loads(self.statefile.read_text())
        metadata = after["crds"][0]["metadata"]
        self.assertEqual(metadata["annotations"][SYNC], "Validate=false,Prune=false,Delete=false")
        self.assertEqual(after["crds"][0]["spec"], before["crds"][0]["spec"])
        self.assertEqual(metadata["annotations"][TRACK], before["crds"][0]["metadata"]["annotations"][TRACK])
        # Only Traefik's auto-sync is disabled; the refresh was acknowledged; nothing else is touched.
        self.assertIs(after["app"]["spec"]["syncPolicy"]["automated"]["enabled"], False)
        self.assertNotIn(REFRESH, after["app"]["metadata"]["annotations"])
        self.assertIn("stays DISABLED until 'Apply Overlay'", result.stdout)
        self.assertFalse(any("delete" in call or "scale" in call for call in self.calls()))

    def test_idempotent_no_duplicate_options_or_repeat_crd_patch(self):
        self.assertEqual(self.migrate().returncode, 0)
        first = self.crd_patches()
        # A rerun (Apply Overlay's push gate) must not ask for approval again.
        del self.env["GATEWAY_API_MIGRATION_APPROVED"]
        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.crd_patches(), first)
        after = json.loads(self.statefile.read_text())
        self.assertEqual(after["crds"][0]["metadata"]["annotations"][SYNC], "Validate=false,Prune=false,Delete=false")

    def test_unqualified_legacy_identity_is_supported(self):
        state = default_state()
        state["crds"] = [crd(owner="traefik")]
        self.assertEqual(self.migrate(state).returncode, 0)

    def test_adopted_resources_skip_without_pausing_or_writing(self):
        state = default_state()
        state["crds"] = [crd(owner="gateway-api", version="v1.6.3")]
        result = self.migrate(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no legacy", result.stdout)
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_reachable_fresh_bootstrap_api_absence_skips(self):
        state = default_state()
        state.update(api=False, app=None, crds=[])
        result = self.migrate(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fresh bootstrap", result.stdout)
        self.assertFalse(any("applications.argoproj.io" in call and "crd" not in call for call in self.calls()))

    def test_unreachable_and_forbidden_are_not_absence(self):
        for change, expected in (({"unreachable": True}, "connection refused"),
                                 ({"forbidden": "crd"}, "Forbidden"),
                                 ({"forbidden": "applications.argoproj.io"}, "Forbidden"),
                                 ({"forbidden": "crds"}, "Forbidden")):
            state = default_state()
            state.update(change)
            self.assert_blocked(state, expected)
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_approval_is_required_before_any_write(self):
        del self.env["GATEWAY_API_MIGRATION_APPROVED"]
        self.assert_blocked(default_state(), "approval required")
        # Also when Traefik auto-sync is already off/absent, or Traefik already runs
        # the target chart and only the CRDs need protecting.
        for change in ({"enabled": False}, None, "target"):
            state = default_state()
            if change == "target":
                state["app"]["spec"]["sources"][0]["targetRevision"] = "42.3.1"
            elif change is None:
                del state["app"]["spec"]["syncPolicy"]["automated"]
            else:
                state["app"]["spec"]["syncPolicy"]["automated"].update(change)
            self.assert_blocked(state, "approval required")
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_waits_for_running_traefik_sync_before_protecting(self):
        state = default_state()
        state["busy_polls"] = 3
        result = self.migrate(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.statefile.read_text())["busy_polls"], 0)
        self.assertEqual(self.crd_patches(), 1)

    def test_unacknowledged_refresh_or_endless_sync_time_out_before_crd_writes(self):
        self.env["GATEWAY_API_MIGRATION_TIMEOUT_SECONDS"] = "0"
        for change, expected in (({"controller_running": False}, "did not process"),
                                 ({"busy_polls": 1000}, "still running")):
            state = default_state()
            state.update(change)
            self.assert_blocked(state, expected)
        self.assertEqual(self.crd_patches(), 0)

    def test_autosync_reenabled_during_wait_blocks(self):
        state = default_state()
        state["reenable"] = True
        self.assert_blocked(state, "re-enabled by someone else")
        self.assertEqual(self.crd_patches(), 0)

    def test_unsupported_argocd_or_render_without_enabled_blocks_before_writes(self):
        state = default_state()
        state["enabled_schema"] = False
        self.assert_blocked(state, "requires ArgoCD 3.x")
        self.set_chart("42.3.1", enabled=None)
        self.assert_blocked(default_state(), "automated.enabled: true")
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_live_target_chart_protects_without_pausing_traefik(self):
        state = default_state()
        state["app"]["spec"]["sources"][0]["targetRevision"] = "42.3.1"
        result = self.migrate(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app_patches(), self.crd_patches()), (0, 1))
        result = self.migrate()
        self.assertIn("Handover in progress", result.stdout)
        self.assertEqual((self.app_patches(), self.crd_patches()), (0, 1))

    def test_parent_managed_app_blocks(self):
        state = default_state()
        state["app"]["metadata"]["ownerReferences"] = [{"kind": "ApplicationSet"}]
        self.assert_blocked(state, "parent manager")
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_cross_installation_ownership_and_wrong_destination_block(self):
        state = default_state()
        state["config"] = {"application.resourceTrackingMethod": "annotation+label", "installationID": "other"}
        self.assert_blocked(state, "installation ID")
        gateway = json.loads(self.gateway.read_text())
        gateway["spec"]["destination"]["server"] = "https://other-cluster"
        self.gateway.write_text(json.dumps(gateway))
        self.assert_blocked(default_state(), "local cluster")

    def test_status_and_ownership_mismatch_blocks(self):
        state = default_state()
        state["app"]["status"]["resources"] = []
        self.assert_blocked(state, "status disagree")
        state["app"] = None
        self.assert_blocked(state, "without the Traefik")

    def test_non_self_referencing_tracking_id_does_not_imply_ownership(self):
        state = default_state()
        state["crds"][0]["metadata"]["annotations"][TRACK] = "traefik:apiextensions.k8s.io/CustomResourceDefinition:/wrong"
        self.assert_blocked(state, "cannot establish ownership")

    def test_custom_label_tracking_cannot_hide_legacy_status_resources(self):
        state = default_state()
        state["config"] = {"application.resourceTrackingMethod": "label", "application.instanceLabelKey": "custom.example/owner"}
        state["crds"][0]["metadata"]["annotations"].pop(TRACK)
        state["crds"][0]["metadata"]["labels"] = {"custom.example/owner": "traefik_traefik"}
        self.assert_blocked(state, "unsupported/custom")
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_experimental_unknown_newer_or_incompatible_versions_block(self):
        for channel, version, stored, expected in (
            ("experimental", "v1.3.0", "v1", "experimental/unknown"),
            ("unknown", "v1.3.0", "v1", "experimental/unknown"),
            ("standard", "v1.7.0", "v1", "unknown/newer"),
            ("standard", "", "v1", "unknown/newer"),
            ("standard", "v1.3.0", "v1alpha2", "incompatible"),
        ):
            state = default_state()
            state["crds"] = [crd(channel=channel, version=version)]
            state["crds"][0]["status"]["storedVersions"] = [stored]
            self.assert_blocked(state, expected)
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_experimental_nonlegacy_is_not_silently_downgraded(self):
        state = default_state()
        state["crds"] = [crd(owner="someone-else", channel="experimental")]
        self.assert_blocked(state, "experimental/unknown")

    def test_excluded_gateway_blocks_upgrade_but_old_chart_can_skip(self):
        self.gateway.unlink()
        self.assert_blocked(default_state(), "excluded/missing")
        self.set_chart("39.0.8")
        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not included", result.stdout)
        self.assertFalse(any("patch" in call for call in self.calls()))

    def test_bundled_or_unaudited_target_blocks_included_gateway(self):
        for version in ("39.0.8", "42.3.2"):
            self.set_chart(version)
            self.assert_blocked(default_state(), "bundled or unaudited")

    def test_missing_crds_and_unsafe_kustomization_block(self):
        (self.bundle / self.files[0]).unlink()
        self.assert_blocked(default_state(), "pinned upstream file")
        (self.bundle / self.files[0]).write_bytes((BASE_REPO / "base/gatewayApi/templates" / self.files[0]).read_bytes())
        self.kustomization.write_text(json.dumps({"resources": self.files}))
        self.assert_blocked(default_state(), "Kustomization must protect")

    def test_overlay_kustomization_cannot_undo_resource_protection(self):
        config = json.loads(self.kustomization.read_text())
        config["patches"] = [{"target": {"kind": "CustomResourceDefinition", "name": "gateways." + GROUP},
                              "patch": '[{"op":"remove","path":"/metadata/annotations/argocd.argoproj.io~1sync-options"}]'}]
        self.kustomization.write_text(json.dumps(config))
        self.assert_blocked(default_state(), "kubectl kustomize")

    def test_overlay_kustomization_cannot_change_pinned_schema(self):
        config = json.loads(self.kustomization.read_text())
        config["patches"] = [{"target": {"kind": "CustomResourceDefinition", "name": "gateways." + GROUP},
                              "patch": '[{"op":"replace","path":"/spec/group","value":"danger.example"}]'}]
        self.kustomization.write_text(json.dumps(config))
        self.assert_blocked(default_state(), "preserve CRD protection and pinned upstream schemas")

    def test_conflicting_options_fail_without_overwriting_them(self):
        state = default_state()
        state["crds"] = [crd(opts="Validate=false,Prune=true")]
        self.assert_blocked(state, "conflicting Prune/Delete")
        self.assertFalse(any("patch" in call and "crd" in call for call in self.calls()))

    def test_pause_patch_crd_patch_and_postcondition_failures_block(self):
        for flags, expected in (({"patch_failure": "applications.argoproj.io"}, "patch conflict"),
                                ({"patch_failure": "crd"}, "patch conflict"),
                                ({"break_verify": True}, "verification failed")):
            state = default_state()
            state.update(flags)
            self.assert_blocked(state, expected)

    def test_real_pinned_sources_match_documented_hashes_and_instructions_mirror(self):
        component = BASE_REPO / "base/gatewayApi"
        hashes = dict(re.findall(r"\| ([a-z_]+\.yaml) \| ([a-f0-9]{64}) \|", (component / "README.md").read_text()))
        self.assertEqual(len(hashes), 11)
        for suffix, digest in hashes.items():
            file = component / "templates" / f"{GROUP}_{suffix}"
            self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(), digest, file.name)
        self.assertIn("Apache License", (component / "UPSTREAM-LICENSE").read_text())
        self.assertEqual((BASE_REPO / "CLAUDE.md").read_bytes(), (BASE_REPO / ".github/copilot-instructions.md").read_bytes())


if __name__ == "__main__":
    unittest.main()
