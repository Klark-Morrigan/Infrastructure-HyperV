# Writing system-wide environment variables on a VM

## Index

- [Context](#context)
- [Problem](#problem)
- [Scope](#scope)
- [Out of scope](#out-of-scope)
- [Design decisions](#design-decisions)
- [Acceptance criteria](#acceptance-criteria)

## Context

`Infrastructure.HyperV` already owns the VM-side transport primitives:
[Copy-VmFiles](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFiles.ps1),
[Copy-VmFilesByPattern](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFilesByPattern.ps1),
and the shared schema validator
[Assert-VmFilesField](../../../../Infrastructure.HyperV/Public/FileTransfer/Assert-VmFilesField.ps1).
Multiple downstream repos
([Infrastructure-Vm-Provisioner](https://github.com/VitaliiAndreev/Infrastructure-Vm-Provisioner),
[Infrastructure-Vm-Users](https://github.com/VitaliiAndreev/Infrastructure-Vm-Users))
funnel through that transport.

[Install-Jdk](../../../../../Infrastructure-Vm-Provisioner/hyper-v/ubuntu/up/post/Install-Jdk.ps1)
writes `JAVA_HOME` and prepends `$JAVA_HOME/bin` to `PATH` via
`/etc/profile.d/jdk.sh`. That snippet is only sourced by **login**
shells. Non-login bash invocations (`bash -c '...'`, CI agent
`ExecStart=` lines) and systemd services do not see it. For the Java
JDK case that happens to be enough because the `/usr/local/bin/java`
symlink covers PATH lookup; but it does not generalise to arbitrary
variables a CI workload needs.

The first concrete consumer is a CI build farm whose workloads run
under a systemd-managed agent (i.e. as a service, not from an
interactive login). Such workloads compile against vendor JARs
placed by
[07 - ci jars](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/07%20-%20ci%20jars/problem.md)
and need build-tool variables - a path to the vendor JAR directory,
JVM tuning flags, build-cache locations, and so on - none of which
fit the "drop a symlink" trick that `JAVA_HOME` gets away with.
Project-specific variable names belong in the operator's JSON, not
in this transport: the cmdlet treats every entry as an opaque
`{ name, value }` pair.

## Problem

There is no transport-layer primitive for setting **system-wide**
environment variables on a VM. The existing options - profile-only
snippets via `Copy-VmFiles`, or ad-hoc `echo X=Y >> /etc/environment`
SSH commands from a downstream repo - all leak the same defects:

- **Wrong scope.** `/etc/profile.d/*.sh` does not reach non-login
  bash or systemd services, which is exactly where the CI workload
  runs. A build invoked from a CI agent service silently sees the
  variable as unset.
- **No idempotence story.** An `echo >> /etc/environment` line
  duplicates on every re-provision. A "replace the whole file"
  approach stomps on lines the operating system or other components
  put there (Ubuntu ships `/etc/environment` with `PATH=...` already
  set). Neither is safe to re-run.
- **No removal story.** Dropping a key from the JSON should remove
  the corresponding line on the next run. Without a discriminator
  saying "these lines were written by us", you cannot tell which
  lines to drop and which to keep.
- **Duplicated across consumers.** Each downstream repo that needs
  this ends up reimplementing the same shell snippet. The bug
  classes above then exist in two-to-N places.

## Scope

Add a new transport primitive to `Infrastructure.HyperV`:

- `Set-VmEnvironmentVariables` - per-entry transport that writes a
  set of `{ name, value }` pairs into `/etc/environment` on the VM,
  under sudo, in a single SSH round-trip per call. Entries land
  between sentinel markers so re-runs replace the block in place
  and removed keys disappear cleanly.

- `Assert-VmEnvVarsField` - shared schema validator for an
  `envVars` array on a VM definition, mirroring the
  [Assert-VmFilesField](../../../../Infrastructure.HyperV/Public/FileTransfer/Assert-VmFilesField.ps1)
  pattern (consumer opts in by calling it; rules are owned here).

Both are exported from the module so any downstream repo
(`Vm-Provisioner`, `Vm-Users`, future consumers) can wire them in
without re-deriving the rules.

Per-entry write algorithm, one SSH round-trip:

1. Build the desired block host-side as a single string with one
   `NAME="VALUE"` line per entry, framed by sentinel markers
   (`# BEGIN Infrastructure.HyperV envVars` /
   `# END Infrastructure.HyperV envVars`).
2. Send a remote script that, under `set -e`:
   - reads `/etc/environment` (or treats it as empty when missing),
   - strips any existing managed block (the sentinel pair plus
     anything between them),
   - appends the freshly built block,
   - writes the result atomically via a temp file + `mv` so a
     half-write cannot leave the file in an inconsistent state,
   - chowns `root:root`, chmods `0644`.
3. Skip the write entirely when the desired block byte-for-byte
   matches what is already inside the existing markers (the
   skip-unchanged contract from
   [02 - skip-unchanged-on-copy](../02%20-%20skip-unchanged-on-copy/problem.md)
   applied here too - same observable state, same opt-out switch
   shape).

## Out of scope

- **User-scoped environment variables** (`~/.profile`,
  `~/.config/environment.d/`). The CI workload runs as a service
  account whose profile is not the right surface; user-scoped vars
  belong to `Infrastructure-Vm-Users`, which can adopt this
  primitive later with a per-user target path if needed.
- **Shell-evaluated values.** Each line in `/etc/environment` is
  parsed by `pam_env`, not by a shell - `VALUE` is a literal,
  `$OTHER_VAR` is not expanded. The cmdlet documents this and
  rejects values containing shell metacharacters that would only
  make sense under shell evaluation (see Design decisions).
- **PATH manipulation as a first-class feature.** Setting
  `PATH=...` works (it is just another key), but "prepend this dir
  to PATH" is a separate concern with its own ordering / dedup
  rules and is not introduced here. Operators who need it set the
  full PATH explicitly.
- **systemd `EnvironmentFile=` integration.** `/etc/environment`
  via `pam_env` is the scope this feature targets. Service-scoped
  env files are a separate primitive.
- **Encryption of values at rest on the VM.** `/etc/environment`
  is root-owned `0644`, same as today. Secrets do not belong here -
  that is what `Infrastructure-Secrets` is for. The validator
  rejects empty values to make accidental "I forgot to template
  the secret" cases loud.
- **Multi-file management.** Exactly one file is touched
  (`/etc/environment`). Splitting across multiple files is a future
  concern if it materialises.

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Target file | `/etc/environment` | Read by `pam_env` on login, non-login, and systemd-service contexts - the only single-file location that reaches all three. Login-only `/etc/profile.d/*.sh` was rejected because the primary consumer (CI agent under systemd, builds under non-login bash) cannot see it. |
| Entry shape | Array of `{ name, value }` objects | Consistent with the `files` array; future-proof (adds room for per-entry flags like `append` without changing the discriminator). A flat `{ NAME -> value }` map was rejected because JSON technically permits duplicate keys (parsers silently drop one) and because we cannot evolve a flat map without breaking the shape. |
| Idempotence model | Managed block with sentinel markers | Re-runs replace the block in place, preserving any lines the OS or another component added outside the markers. Removing a key from JSON removes it from the file on the next run. Per-key upsert was rejected because it cannot detect removals; full-file overwrite was rejected because it stomps on Ubuntu's pre-seeded `PATH=...`. |
| Atomic write | Temp file + `mv` inside the same `set -e` script | A crash mid-write must never leave `/etc/environment` truncated - PAM would then refuse logins. `mv` within the same filesystem is atomic on Linux. |
| Skip-unchanged | On by default, `-NoSkipUnchanged` opts out | Same shape as [Copy-VmFiles](../02%20-%20skip-unchanged-on-copy/problem.md). The remote script compares the *managed block content* (not the whole file - operator edits outside the block must not force a re-write) against the desired bytes and `exit 0`s on match. |
| Validation: name | POSIX identifier (`[A-Za-z_][A-Za-z0-9_]*`), reject `=` | `pam_env` requires identifier syntax; an `=` in the name corrupts the file. Validator catches this before SSH. |
| Validation: value | Non-empty string, no newlines, no NULs | Newlines silently split into two lines, half of which would be unparseable; NULs are rejected by `pam_env`. Empty values are rejected to flag "untemplated secret" mistakes; an operator who genuinely wants an empty string can pass `""` explicitly through an escape hatch documented in the validator (not in v1). |
| Value quoting on disk | Always `NAME="VALUE"` with `"` and `\` escaped | `pam_env` treats unquoted whitespace as a delimiter; always-quoting normalises that. Escaping `"` and `\` lets values legitimately contain those characters without corrupting the file. |
| Removing the whole block | Calling the cmdlet with an empty entries array strips the block (markers and all) | Lets a consumer say "this VM no longer wants any of our vars" without growing a second cmdlet. Mirrors how an `uninstall` flag works at the consumer layer. |
| Public surface | Two functions: transport (`Set-VmEnvironmentVariables`) + validator (`Assert-VmEnvVarsField`) | Same split as the files feature - keeps the schema rules in one shared place and the transport in another, so consumers do not re-derive either. |
| Sentinel string | `# BEGIN <blockName>` / `# END <blockName>` where `blockName` comes from the JSON | A single shared name across all consumers means two repos that both wire in this transport would collide on the same block. Naming the block per VM (or per consumer) lets unrelated owners coexist in one `/etc/environment` without stepping on each other. A comment-line `#` keeps the markers invisible to `pam_env`. Versioning the marker (e.g. `v1`) was rejected as premature - the block format itself is the contract, and the marker rename can be added later if the format ever breaks. |
| `envVars` schema shape | Object `{ blockName, entries }` with both required | Wraps the entry list with its owner so the validator (and any consumer reading the JSON) sees both fields in one place. A sibling top-level field (`envVarsBlockName`) was rejected because the two fields are useless apart - forgetting one leaves the other dangling. `blockName` is required (no implicit default) so colliding writes can never happen by accident; the operator picks the name deliberately. |
| `blockName` rules | Non-empty string, 1-128 chars, `[A-Za-z0-9._ -]` only, no leading/trailing whitespace | Forbidden characters would break the marker line: `'` breaks the shell single-quoted assignment, newlines split the marker across lines, NUL is rejected by tools. Bounded length keeps `/etc/environment` readable. Allowing internal spaces preserves the natural form (`MyApp envVars`) the original sentinel used. |

## Acceptance criteria

- `Set-VmEnvironmentVariables` writes a managed block into
  `/etc/environment` between the two sentinel markers, with one
  `NAME="VALUE"` line per entry, ownership `root:root`, mode `0644`.
- Lines outside the managed block (Ubuntu's pre-seeded `PATH=...`,
  operator additions, other components' lines) are preserved
  byte-for-byte across runs.
- A re-run with identical entries does not rewrite the file
  (`mtime` unchanged on the target). Asserted with skip-unchanged
  on; with `-NoSkipUnchanged` the write runs unconditionally.
- A re-run with one key removed from the entries array writes a
  file in which that key's line is gone from the managed block,
  while the others remain.
- A call with an empty entries array removes the markers and the
  block entirely; lines outside the block are preserved. A
  subsequent call with entries re-creates the block.
- A crash partway through the remote script never leaves
  `/etc/environment` truncated - the atomic write is asserted by
  inspecting the script shape (temp file + `mv` under `set -e`).
- `Assert-VmEnvVarsField` rejects, before any SSH I/O: `envVars`
  that is not an object; missing `blockName` or `entries`;
  `blockName` empty, too long, or containing disallowed
  characters; `entries` that is not an array; entries that are
  not objects; entries missing `name` or `value`; `name` that is
  not a POSIX identifier; `name` containing `=`; `value` that is
  empty, contains a newline, or contains a NUL; entries with
  unknown sub-fields.
- `Set-VmEnvironmentVariables` requires a `-BlockName` parameter
  and emits markers using that name; two calls with different
  block names produce two independent managed blocks in
  `/etc/environment` that do not interfere with each other.
- A `Set-VmEnvironmentVariables` call where the freshly built
  managed block byte-for-byte equals the file's existing managed
  block produces no `mv` and no `chmod` (skip-unchanged path).
- Unit tests pin the emitted script shape (sentinel handling,
  `set -e`, temp-file + `mv`, owner / mode commands, optional
  reconcile block under default and absent under
  `-NoSkipUnchanged`).
- Integration tests against the Docker target cover: first-run
  create, identical re-run is a no-op, key removal trims one
  line, empty-entries removes the whole block, drift outside the
  block is preserved across all of the above.
- Module manifest exports both new functions; README documents
  both alongside the existing transport primitives. The
  `Module.Tests.ps1` parity check between `FunctionsToExport`
  and `Export-ModuleMember` continues to pass.
