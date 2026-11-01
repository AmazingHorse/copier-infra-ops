set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install maintainer tools; rendered-project tools are a separate setup step.
setup:
    mise install

# Render and validate all combinations using already installed tools.
check:
    bash tests/render.sh
