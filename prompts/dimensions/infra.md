## Lens: INFRA

Aim this scan at the operational surface — compose files, Dockerfiles, CI configs,
systemd units, and the env plumbing that wires them together. This is a shared-VM
project; a mistake here has blast radius beyond one process.

Hunt for:
- docker-compose quality: missing healthchecks, no `deploy.resources`/mem limits,
  `image: ...:latest` (unpinned) tags, `network_mode: host` sprawl, containers that
  bind a port to 0.0.0.0 when a private network would do, missing `restart:` policy;
- Dockerfile hygiene: running as root, `ADD` of a URL, secrets baked into a layer,
  `apt-get` without cleanup, no layer ordering for cache reuse, missing `.dockerignore`;
- CI config: a job that references a missing script/secret, a step that cannot run, a
  cache key that never hits, a workflow trigger that fires on the wrong event;
- systemd units: wrong `WorkingDirectory`/`ExecStart` path, missing `Restart=`, a unit
  that starts before its dependency;
- env plumbing: a variable read in code but never set in compose/CI/unit, a value
  duplicated across files that has drifted, a required var with no default and no doc.

Proof standard for this lens:
- Most findings are `static-given-deps`: the defect is visible in the file, but the
  PROOF that it is a defect cites the tool's documented behavior (compose spec, Docker
  build semantics, the CI provider's docs). Name the tool and, where relevant, the
  pinned version; write the recipe so the reviewer confirms the behavior from that
  source, not from memory.
- A pure "this key is absent / this tag is unpinned" claim is `static`: cite file:line
  and the grep that shows the absence or the literal.

Caution: before citing a missing healthcheck or limit as a defect, check whether a
sibling service in THIS repo's own compose/stack sets it — a `convention` claim needs
that in-repo standard, not a generic best-practices list. Respect the shared-VM blast
radius: if reconciling a value means guessing which network/port is authoritative, and
the repo does not settle it, set disposition:surface.
