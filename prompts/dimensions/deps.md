## Lens: DEPS

Aim this scan at the dependency manifests and their lockfiles — `package.json`/
`package-lock.json`/`yarn.lock`, `requirements.txt`/`poetry.lock`/`pyproject.toml`,
`go.mod`/`go.sum`, and equivalents. The defect lives in the pins and the graph, not in
application logic.

Hunt for:
- end-of-life or known-vulnerable pinned versions: a dependency pinned to a release with
  a documented CVE or past its supported life;
- lockfile drift vs manifest: a version range in the manifest the lockfile does not
  satisfy, a package in the lockfile absent from the manifest (or vice versa), a lockfile
  not regenerated after a manifest edit;
- duplicate/conflicting deps: the same package pinned to two incompatible versions across
  workspaces, or two packages that provide the same thing;
- unused deps: a manifest entry no source file imports or requires — dead weight in the
  install and the attack surface.

Proof standard for this lens:
- A drift or duplicate claim is `static`: both the manifest and the lockfile are in the
  repo. Cite both file:line locations and the exact version strings that disagree.
- An unused-dep claim is `static` but demands a THOROUGH reference hunt: grep every
  import/require form for the package (and any binary/CLI it installs, and plugin configs
  that name it by string) before claiming it is unused — a dep used only via a config key
  or a tool's implicit resolution will have no `import` line yet still be required.
- An EOL/vulnerable claim is `static-given-deps`: the pin is in the repo, but the CVE /
  support status is external. Name the package and pinned version, and write the recipe
  so the reviewer confirms the advisory against that exact version — not from memory.

Caution: "newer version available" is NOT a finding — an upgrade is a judgment about
risk and breakage the repo does not settle. Report a stale pin only when it is provably
vulnerable or EOL; otherwise disposition:surface, do not bump.
