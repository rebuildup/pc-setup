#!/usr/bin/env python3
"""Verify the mise global lock does not carry supply-chain policy options that
the declared machine-global config does not set.

`mise lock` records a tool's resolved options under `[tools.<name>.options]`.
When an option is removed from `mise.global.toml`, the lock can keep the old
value: the lock is only regenerated for tools whose resolution changes. The
result is a lock that still enforces (or, as in issue #175, still *exempts* a
package from) a policy the declared config no longer contains. The lock is the
file a fresh machine installs from, so that stale option is what actually
reaches a machine.

Only the supply-chain policy options are checked. The lock also records
backend-derived options (for example `infisical`'s `asset_pattern` and
`core:ruby`'s build flags) that are legitimately absent from the config, so a
blanket "lock options must exist in config" rule would false-positive on them.
"""

from __future__ import annotations

import json
import sys
import tomllib
from pathlib import Path

# Options mise declares on a tool and writes through to the lock. These are the
# ones that widen or narrow a supply-chain check, so a stale value in the lock
# silently changes what a machine enforces.
POLICY_OPTIONS = (
    "allow_builds",
    "trust_policy_excludes",
    "allow_low_downloads",
    "allow_exotic_deps",
)


def normalize(value: object) -> object:
    """Compare a config list with the JSON string the lock stores for it.

    `mise.global.toml` writes `allow_builds = ["esbuild"]`, while the lock
    records the same value as the string `'["esbuild"]'`. Both spell the same
    policy, so they are compared as parsed data rather than as text.
    """
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def declared_policy(config: dict) -> dict[str, dict[str, object]]:
    tools = config.get("tools", {})
    declared: dict[str, dict[str, object]] = {}
    for name, spec in tools.items():
        if not isinstance(spec, dict):
            continue
        options = {
            key: normalize(spec[key])
            for key in POLICY_OPTIONS
            if key in spec
        }
        if options:
            declared[name] = options
    return declared


def locked_policy(lock: dict) -> dict[str, dict[str, object]]:
    tools = lock.get("tools", {})
    locked: dict[str, dict[str, object]] = {}
    for name, entry in tools.items():
        # All but `vercel`-style single entries are arrays of version entries,
        # and `options` sits inside the entry it belongs to.
        entries = entry if isinstance(entry, list) else [entry]
        for item in entries:
            if not isinstance(item, dict):
                continue
            options = item.get("options")
            if not isinstance(options, dict):
                continue
            found = {
                key: normalize(options[key])
                for key in POLICY_OPTIONS
                if key in options
            }
            if found:
                locked.setdefault(name, {}).update(found)
    return locked


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    config_path = root / "mise.global.toml"
    lock_path = root / "mise.global.lock"

    if not lock_path.exists():
        print(f"ok      {lock_path.name} absent; no locked policy to reconcile")
        return 0

    with config_path.open("rb") as fh:
        config = tomllib.load(fh)
    with lock_path.open("rb") as fh:
        lock = tomllib.load(fh)

    declared = declared_policy(config)
    locked = locked_policy(lock)

    problems: list[str] = []
    for tool, options in sorted(locked.items()):
        for key, value in sorted(options.items()):
            if tool not in declared or key not in declared[tool]:
                problems.append(
                    f"{tool}.{key} is locked as {value!r} but "
                    f"mise.global.toml does not declare it"
                )
            elif declared[tool][key] != value:
                problems.append(
                    f"{tool}.{key} is locked as {value!r} but "
                    f"mise.global.toml declares {declared[tool][key]!r}"
                )

    if problems:
        for problem in problems:
            print(f"ERROR   {problem}", file=sys.stderr)
        print(
            "\nmise.global.lock still carries policy options the declared config "
            "does not set. Regenerate the lock (`mise lock --global`) so the "
            "committed lock matches mise.global.toml.",
            file=sys.stderr,
        )
        return 1

    print(
        "ok      mise.global.lock policy options match mise.global.toml "
        f"({sum(len(v) for v in declared.values())} declared)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
