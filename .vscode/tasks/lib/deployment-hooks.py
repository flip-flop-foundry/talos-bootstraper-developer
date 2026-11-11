#!/usr/bin/env python3
"""Current-source hook inventory, shared by the renderer and phase runner."""
import argparse
from pathlib import Path
import shutil
import json
import subprocess


def discover(base, overlay, exclusions, phases=("beforeArgo", "beforeTalos")):
    selected = {}
    if "deploymentHooks" in exclusions:
        return []
    for root in (Path(base), Path(overlay)):
        component = root / "deploymentHooks"
        if component.is_symlink():
            raise ValueError(f"Hook component must not be a symlink: {component}")
        if not component.exists():
            continue
        for phase in phases:
            directory = component / phase
            if directory.is_symlink():
                raise ValueError(f"Hook phase must not be a symlink: {directory}")
            if not directory.exists():
                continue
            for file in directory.iterdir():
                if file.suffix != ".sh":
                    continue
                relative = f"deploymentHooks/{phase}/{file.name}"
                if relative in exclusions:
                    continue
                if file.is_symlink() or not file.is_file():
                    raise ValueError(f"Hook must be a regular file: {file}")
                if any(c in relative for c in "\n\r\t"):
                    raise ValueError("Hook filenames cannot contain control characters")
                selected[relative] = file
    return sorted(selected.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "copy", "check-requirements"))
    parser.add_argument("base")
    parser.add_argument("overlay")
    parser.add_argument("target", help="phase for list; output directory for copy")
    parser.add_argument("exclusions", nargs="*")
    args = parser.parse_args()
    if args.action == "list":
        if args.target != "beforeArgo":
            parser.error("beforeTalos is reserved, not wired")
        hooks = discover(args.base, args.overlay, args.exclusions, phases=(args.target,))
        for relative, source in hooks:
            if relative.startswith(f"deploymentHooks/{args.target}/"):
                print(source)
    elif args.action == "check-requirements":
        selected = {relative for relative, _ in discover(args.base, args.overlay, args.exclusions, phases=("beforeArgo",))}
        rendered = Path(args.target)
        for file in sorted(set(rendered.rglob("*.yaml")) | set(rendered.rglob("*.yml"))):
            if file.relative_to(rendered).parts[0] in ("talos", "deploymentHooks"):
                continue
            result = subprocess.run(
                ["yq", "-o=json", "-I=0",
                 'select(.kind == "Application" or .kind == "ApplicationSet") | '
                 '.metadata.annotations."bootstrapper.talos.dev/required-before-argo-hook" // ""',
                 str(file)], text=True, capture_output=True, check=True)
            for line in result.stdout.splitlines():
                required = json.loads(line)
                if required and required not in selected:
                    raise ValueError(
                        f"{file.name} requires enabled beforeArgo hook {required}; "
                        "it is missing/excluded. Include the hook or exclude the dependent Application too.")
    else:
        hooks = discover(args.base, args.overlay, args.exclusions)
        destination = Path(args.target) / "deploymentHooks"
        if destination.is_symlink():
            raise ValueError(f"Output must not be a symlink: {destination}")
        if destination.exists():
            shutil.rmtree(destination)
        for relative, source in hooks:
            target = Path(args.target) / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)  # Never envsubst shell scripts.


if __name__ == "__main__":
    main()
