# Deployment hooks (beforeArgo)

Trusted source scripts live in the shared base or environment overlay:

```
base/deploymentHooks/beforeArgo/20-example.sh
environments/<env>/deploymentHooks/beforeArgo/20-example.sh
```

Matching relative paths are **replaced**, not merged; overlay wins. Execution is
lexically sorted by filename. `EXCLUDED_BASE` matches either the entire
`deploymentHooks` component or an **exact** path, e.g.
`deploymentHooks/beforeArgo/20-example.sh`. Exclusions apply to overlays too.
A directory prefix such as `deploymentHooks/beforeArgo` does not exclude children.
`beforeTalos` is reserved, copied when rendered, and never executed.

`render-overlay.sh` only generates files; it never runs hooks. Hooks are copied
verbatim, without envsubst. Non-Talos generated trees are rebuilt so exclusions
and source deletions cannot leave stale published manifests. Generated Talos
files are preserved. `--output-dir <scratch>/_rendered` isolates both manifests
and generated workflows from the environment output.

`run-deployment-hooks.sh <env-file> beforeArgo [VAR=value ...] [--dry-run]`
discovers **current sources**, validates the kubeconfig cluster and API endpoint,
then uses the existing renderer to make an isolated fresh desired-state snapshot.
It does not execute stale `_rendered` scripts. A nonzero discovery/render/hook
exit blocks publication, with no silent fallback. Dry runs execute nothing.
The renderer also aborts on Argo YAML/merge/envsubst failures rather than publishing
partial output or copying unsubstituted templates as a success fallback.
Deferred Talos templates keep their existing later-substitution contract and are
not parsed as Argo manifests.
Overrides are applied to both the hook environment and its render snapshot.
The optional `DEPLOYMENT_HOOK_KUBE_CONTEXT` must match current-context;
`DEPLOYMENT_HOOK_KUBE_SERVER` permits an explicitly selected alternative endpoint.
Hook kubectl operations must use `--context "$HOOK_KUBE_CONTEXT"`.

Applications/ApplicationSets may declare the exact source hook path in
`bootstrapper.talos.dev/required-before-argo-hook`. The runner checks this against
the current-source inventory using a fresh render even when that inventory is
empty. Excluding/removing a required hook blocks publication while its dependent
Application remains included; excluding both still works. Gateway and Traefik
declare the migration hook requirement. Exact-path overlay replacement is
supported, but replacements are trusted code: authors/operators must retain an
equivalent safety gate. The framework cannot prove arbitrary script equivalence.

Scripts are Bash-compatible and receive exported env variables plus:
`HOOK_ENV_FILE`, `HOOK_BASE_DIR`, `HOOK_OVERLAY_DIR`, `HOOK_RENDERED_DIR`,
`HOOK_TOOL_DIR`, `HOOK_PHASE`, `HOOK_KUBE_CONTEXT`. Sources/env files are trusted
code, not a security sandbox. Authors must check relevance before expensive
operations, be idempotent, distinguish reachable API absence from API failure,
and never mutate during rendering. See the shared repository skill
`.github/skills/create-deployment-hook/SKILL.md`.

Wiring:
* `push-to-gitea.sh`: fresh render + hooks before credentials/clone/publication;
  `--dry-run` skips all work.
* `cluster-bootstrap.sh`: after kubeconfig setup, before first bootstrap
  mutation; recheck before temporary Git publication; final push checks again.
* `gitea-bootstrap.sh`: full-bootstrap preflight + push gate; integration-only
  modes do not publish deployment manifests.
* `bootstrap-customer.sh`: before the direct cluster-services descriptor API
  commit (an Argo ApplicationSet input).

Both Git publication transports filter `/deploymentHooks/` and `/talos/`.
The normal mirror purges formerly published excluded files; the temporary
bootstrap Git server receives only publication content, never the raw overlay.
No Talos entrypoint has been changed.

Offline tests:
`python3 -m unittest discover -s .vscode/tasks/tests -v`.
The Gateway migration asks the administrator for approval, then pauses auto-sync
for the Traefik Application only (no controller-wide pause). Apply Overlay
re-enables it with the chart upgrade. See `base/gatewayApi/README.md` for the
maintenance sequence and recovery. No cluster/Gitea deployment is performed by
these tests or by implementing this change.
