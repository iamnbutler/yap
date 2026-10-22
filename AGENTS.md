# AGENTS

<!-- lane:protocol -->
## Context memory

- Before editing a file, read `.lane/memory/<path>/` if it exists, or run `lane why <path>`.
- Record non-obvious findings with `lane note add <path> -a <anchor> "..."`.
- Do not edit `.lane/` by hand; landing manages it.
- Land with `lane merge`, or `lane push` where trunk is protected, then `lane prune` once it merges.
- Detailed workflow lives in `.agents/skills/lane/SKILL.md`; run `lane install skill` if it is absent.
<!-- /lane:protocol -->

## Making a change

Every change goes through a lane, never the main checkout:

1. `lane new <name>`, then work in the tree it prints.
2. `lane why <path>` before editing a file.
3. Commit. Add `Why: <path> | <note>` trailers only for constraints the code can't show.
4. `lane check`, then confirm, replace or retire any stale notes.
5. `lane push`, open a PR, and squash-merge it.
6. In the main checkout: `git pull --ff-only`, then `lane prune --dry-run` and `lane rm <name>` for merged lanes that prune misses.

## Building

`make run` builds, installs to `/Applications/Yap.app` and launches. `make test` runs the Core tests. Always install to /Applications: macOS ties permission grants to where the app lives, so a copy anywhere else has to be granted again.
