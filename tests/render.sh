#!/usr/bin/env bash
set -euo pipefail

# Installation is intentionally outside this offline gate. Resolve the caller's
# installed executables before isolating HOME and mise/XDG state.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
base=${BASE_TEMPLATE:-"$repo/../copier-base"}
if [[ ! -d "$base" ]]; then
  printf 'Local copier-base is missing: %s (set BASE_TEMPLATE)\n' "$base" >&2
  exit 1
fi
base=$(cd -- "$base" && pwd -P)
tool_path=''
for tool in git python3 copier mise just pre-commit betterleaks check-yaml \
  end-of-file-fixer trailing-whitespace-fixer yamllint ansible-lint \
  ansible-playbook tofu; do
  executable=$(command -v "$tool") || {
    printf 'Install the pinned toolchain before running this gate: %s\n' "$tool" >&2
    exit 1
  }
  executable=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$executable")
  tool_path="${tool_path:+$tool_path:}$(dirname -- "$executable")"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/copier-infra-ops.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export MISE_CONFIG_DIR="$XDG_CONFIG_HOME/mise"
export MISE_DATA_DIR="$XDG_DATA_HOME/mise"
export MISE_CACHE_DIR="$XDG_CACHE_HOME/mise"
export MISE_STATE_DIR="$XDG_STATE_HOME/mise"
export MISE_TRUSTED_CONFIG_PATHS="$work"
export MISE_YES=1
export PRE_COMMIT_HOME="$XDG_CACHE_HOME/pre-commit"
export ANSIBLE_HOME="$XDG_CACHE_HOME/ansible"
export ANSIBLE_LOCAL_TEMP="$XDG_CACHE_HOME/ansible/tmp"
export ANSIBLE_REMOTE_TEMP="$XDG_CACHE_HOME/ansible/remote"
export ANSIBLE_GALAXY_CACHE_DIR="$XDG_CACHE_HOME/ansible/galaxy"
export ANSIBLE_LINT_NODEPS=1
export UV_OFFLINE=1
export PIP_NO_INDEX=1
export TF_IN_AUTOMATION=1
export CHECKPOINT_DISABLE=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export PATH="$tool_path:/usr/bin:/bin"
unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BWS_ACCESS_TOKEN \
  FNOX_MASTER_KEY FNOX_PROFILE FNOX_CONFIG_DIR || true
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
  "$XDG_STATE_HOME" "$ANSIBLE_LOCAL_TEMP" "$ANSIBLE_REMOTE_TEMP"

# Never tag or modify the actual template repositories. Copier reads versioned
# local fixtures so the test remains independent of GitHub and publication.
for source_name in base infra; do
  source_repo=$repo
  if [[ "$source_name" == base ]]; then source_repo=$base; fi
  git -C "$source_repo" rev-parse --verify HEAD >/dev/null
  git clone --quiet --no-hardlinks "$source_repo" "$work/$source_name"
  if ! git -C "$work/$source_name" describe --tags --exact-match HEAD >/dev/null 2>&1; then
    git -C "$work/$source_name" tag v0.1.0
  fi
done
base_revision=$(git -C "$work/base" rev-parse HEAD)
infra_revision=$(git -C "$work/infra" rev-parse HEAD)
for source_name in base infra; do
  fixture="$work/$source_name"
  git -C "$fixture" config user.name 'Template Tests'
  git -C "$fixture" config user.email 'template-tests@example.invalid'
  printf 'Independent %s update reached the project.\n' "$source_name" \
    > "$fixture/template/.$source_name-update-marker"
  git -C "$fixture" add --all
  git -C "$fixture" commit --quiet -m "test: add $source_name update marker"
done

# Only local fixtures are used below. Dead proxies make accidental remote
# fetches fail promptly; no vault session is available to these checks.
export HTTP_PROXY=http://127.0.0.1:9
export HTTPS_PROXY=http://127.0.0.1:9
export ALL_PROXY=http://127.0.0.1:9
export NO_PROXY=''
export http_proxy=$HTTP_PROXY https_proxy=$HTTPS_PROXY all_proxy=$ALL_PROXY no_proxy=''

for combination in ansible opentofu both; do
  selection='[ansible]'
  if [[ "$combination" == opentofu ]]; then selection='[opentofu]'; fi
  if [[ "$combination" == both ]]; then selection='[ansible, opentofu]'; fi
  project="$work/project-$combination"
  baseline="$work/baseline-$combination"
  copier copy --defaults --vcs-ref "$base_revision" \
    --answers-file .copier-answers.base.yml \
    -d project_name=demo-infra -d description='Offline infrastructure fixture' \
    "$work/base" "$project"
  git -C "$project" init --quiet -b main
  git -C "$project" config user.name 'Template Tests'
  git -C "$project" config user.email 'template-tests@example.invalid'

  # These are project-owned extension points. Seed distinct bytes before the
  # overlay, then verify every pre-existing file survives copy AND both updates.
  printf '\n# Project-owned reference sentinel; no secret value.\n' >> "$project/fnox.toml"
  printf '\n# Project policy sentinel.\n' >> "$project/.agents/project.md"
  printf '\n# Project sandbox sentinel.\n' >> "$project/.agents/sandbox.toml"
  printf '# Project recipe sentinel.\n' > "$project/project.just"
  printf 'Project-owned local notes.\n' > "$project/project-notes.txt"
  mkdir -p "$baseline"
  python3 - "$project" "$baseline" <<'PY'
from pathlib import Path
import shutil
import sys
source, target = map(Path, sys.argv[1:])
for entry in source.rglob('*'):
    relative = entry.relative_to(source)
    if '.git' in relative.parts or entry.is_dir():
        continue
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if entry.is_symlink():
        destination.symlink_to(entry.readlink())
    else:
        shutil.copyfile(entry, destination)
PY
  copier copy --defaults --vcs-ref "$infra_revision" \
    --answers-file .copier-answers.infra-ops.yml \
    -d "iac=$selection" -d live_targets=192.0.2.0/24 \
    "$work/infra" "$project"

  python3 - "$project" "$baseline" "$combination" <<'PY'
from pathlib import Path
import sys
import tomllib
project, baseline = map(Path, sys.argv[1:3])
combination = sys.argv[3]
for original in baseline.rglob('*'):
    if original.is_dir():
        continue
    rendered = project / original.relative_to(baseline)
    if original.is_symlink():
        assert rendered.is_symlink() and rendered.readlink() == original.readlink(), rendered
    else:
        assert rendered.read_bytes() == original.read_bytes(), rendered
assert (project / '.copier-answers.base.yml').is_file()
assert (project / '.copier-answers.infra-ops.yml').is_file()
assert (project / 'archetype.just').is_file()
assert (project / '.agents/archetype.md').is_file()
assert (project / '.agents/skills/infra-ops-runbook/SKILL.md').is_file()
assert (project / '.agents/skills/infra-ops-add-secret/SKILL.md').is_file()
assert (project / 'docs/runbook.md').is_file()
assert (project / 'ansible').is_dir() == (combination != 'opentofu')
assert (project / 'opentofu').is_dir() == (combination != 'ansible')
with (project / '.config/mise/conf.d/infra-ops.toml').open('rb') as handle:
    tools = tomllib.load(handle)['tools']
assert tools['aqua:astral-sh/uv'] == '0.13.5'
assert tools['pipx:yamllint'] == '1.38.0'
assert ('pipx:ansible-core' in tools) == (combination != 'opentofu')
assert ('pipx:ansible-lint' in tools) == (combination != 'opentofu')
assert ('aqua:opentofu/opentofu' in tools) == (combination != 'ansible')
PY
  (
    cd "$project"
    git add --all
    git commit --quiet -m 'test: seed composed infrastructure fixture'
    just --list
    just check

    # Copier must use each answer file independently without replacing the
    # underlay or the project-owned extension points.
    copier update --defaults --vcs-ref HEAD --answers-file .copier-answers.base.yml
    git add --all
    git commit --quiet -m 'test: update base independently'
    copier update --defaults --vcs-ref HEAD --answers-file .copier-answers.infra-ops.yml
    git add --all
    git commit --quiet -m 'test: update archetype independently'
    just --list
    just check
  )
  test -f "$project/.base-update-marker"
  test -f "$project/.infra-update-marker"
  python3 - "$project" "$baseline" <<'PY'
from pathlib import Path
import sys
project, baseline = map(Path, sys.argv[1:])
for original in baseline.rglob('*'):
    # The base answer file legitimately records its newer template commit.
    if original.is_dir() or original.name == '.copier-answers.base.yml':
        continue
    rendered = project / original.relative_to(baseline)
    if original.is_symlink():
        assert rendered.is_symlink() and rendered.readlink() == original.readlink(), rendered
    else:
        assert rendered.read_bytes() == original.read_bytes(), rendered
PY
  printf 'Passed infrastructure composition: %s\n' "$combination"
done
