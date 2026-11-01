# copier-infra-ops

An infrastructure-operations archetype layered over [copier-base](https://github.com/AmazingHorse/copier-base). It supports Ansible, OpenTofu, or both, with offline checks and explicit live-operation approval. MIT licensed.

## Create a project

Install Copier 9.19.1+, Git and mise. Render the base first, then apply this overlay to the **same directory**:

```sh
copier copy --defaults --vcs-ref v0.1.0 \
  -d project_name=example-infra -d description='Infrastructure operations' \
  gh:AmazingHorse/copier-base example-infra
copier copy --defaults --vcs-ref v0.1.0 \
  -d 'iac=[ansible, opentofu]' -d live_targets=192.168.50.0/24 \
  gh:AmazingHorse/copier-infra-ops example-infra
cd example-infra
git init -b main
just setup
just --list
just check
```

The project directory must be a Git repository before installing hooks or running pre-commit. Python-backed tools need an available Python 3.12+; CI uses Python 3.13. Supported `iac` selections are `[ansible]` (default), `[opentofu]`, and `[ansible, opentofu]`. `live_targets` is a documented approval boundary, not automatic network permission.

## Layer ownership and updates

The base owns root entrypoints, pre-commit, provider configuration and base agent policy. This overlay owns `archetype.just`, `.config/mise/conf.d/infra-ops.toml`, `.agents/archetype.md`, its two skills, selected IaC directories and `docs/runbook.md`. It does **not** replace `justfile`, root `mise.toml`, root `AGENTS.md`, `CLAUDE.md`, the root README, project `fnox.toml` or `.agents/sandbox.toml`.

Copier records the two layers independently in `.copier-answers.base.yml` and `.copier-answers.infra-ops.yml`. Commit generated files and answers before updating:

```sh
copier update --defaults --answers-file .copier-answers.base.yml
copier update --defaults --answers-file .copier-answers.infra-ops.yml
```

Task precedence is project > archetype > base. Add project overrides in `project.just`, agent guidance in `.agents/project.md`, and secret references in `fnox.toml`; do not edit template-owned files to customize a project. The included base provider remains separate from project secret references. Review updates and preserve any deliberate custom edits through Copier's merge, not a forced re-render.

## Operations and offline gates

`just check` runs local pre-commit hooks, yamllint, Ansible lint/syntax checks when selected, and OpenTofu fmt/validate when selected. It never accesses a vault, installs collections/providers, initializes OpenTofu or contacts hosts. Recursive `project-lint` hooks are skipped inside `lint`; other hooks still run. An inline yamllint policy accommodates Copier answers and base workflow syntax without adding an overlay-owned root config.

`just plan` uses `fnox exec --` for Ansible check/diff and OpenTofu plan. The sequence is check → plan → review → explicitly approved apply. There is no generic apply or live smoke recipe. Map approved CIDRs and ports into the project-owned, deny-by-default `.agents/sandbox.toml` before approved live work. Keep SSH host-key checking enabled. Add no plaintext secrets, vault-password files or encrypted blobs. See generated `.agents/archetype.md`, both `infra-ops-*` skills and `docs/runbook.md`.

Ansible starts with an empty inventory, empty collection requirements and a localhost no-op playbook. OpenTofu starts provider-free and can validate offline. When adding dependencies, pin them and perform installation/initialization as an explicit setup action; never hide network access inside `check`.

## Develop and test
Clone `copier-base` as a sibling, or set `BASE_TEMPLATE` to a local clone. Install the maintainer tools from `mise.toml` and the full rendered toolchain before invoking the gate: pre-commit 4.7.0, pre-commit-hooks 6.0.0, betterleaks 1.9.0, yamllint 1.38.0, ansible-core 2.21.5, ansible-lint 26.10.1, OpenTofu 1.13.2 and the base's remaining pins. `mise exec -- bash tests/render.sh` consumes installed tools; it does not download them.
Clone `copier-base` as a sibling, or set `BASE_TEMPLATE` to a local clone. Install the maintainer tools from `mise.toml` and the full rendered toolchain before invoking the gate: pre-commit 4.5.1, pre-commit-hooks 6.0.0, betterleaks 1.9.0, yamllint 1.38.0, ansible-core 2.21.5, ansible-lint 26.10.1, OpenTofu 1.13.2 and the base's remaining pins. `mise exec -- bash tests/render.sh` consumes installed tools; it does not download them.

The isolated harness snapshots both local Git repositories, makes a test tag only in temporary fixtures if needed, renders all three IaC combinations and checks `just --list` and `just check` without Bitwarden or network dependencies. It also checks conditional files, tool pins, base-owned byte preservation, custom project files and both independent update paths. HOME/XDG/cache state is isolated and removed on exit. Source repositories and their tags are not changed.

CI performs tool installation as an explicit preceding step, then runs this same offline gate with read-only repository permissions. This template deliberately has no Copier tasks or migrations, so `--trust` is not required.
