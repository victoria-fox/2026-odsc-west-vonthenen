#!/usr/bin/env bash
# Double-click in Finder to bring up the workshop environment: starts Docker,
# the five workshop containers, validates, then opens a shell with the Python
# environment active.

cd "$(dirname "$0")" || exit 1
WORKSHOP_DIR="$PWD"
CONTAINERS=(postgres mem0 mem0-dashboard opensearch-single opensearch-single-dashboards)

# Finder-launched scripts don't read ~/.zshrc, so pull the API keys from it.
eval "$(grep -E '^export (OPENAI|TAVILY)_API_KEY=' ~/.zshrc)"

step() { printf '\n==> %s\n' "$*"; }

# wait_for <description> <timeout seconds> <command...>
wait_for() {
    local what="$1" timeout="$2" waited=0
    shift 2
    printf 'Waiting for %s' "$what"
    until "$@" >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            printf ' timed out after %ss\n' "$timeout"
            return 1
        fi
        printf '.'
        sleep 3
        waited=$((waited + 3))
    done
    echo " ready"
}

step "Docker"
if ! docker info >/dev/null 2>&1; then
    open -a Docker
    wait_for "Docker Desktop" 180 docker info || exit 1
else
    echo "Docker is running"
fi

step "Containers"
missing=()
for c in "${CONTAINERS[@]}"; do
    docker container inspect "$c" >/dev/null 2>&1 || missing+=("$c")
done

# Bind mounts are absolute paths, so containers created before the repo was
# moved still point at the old location. Treat those as missing too. Only
# postgres and mem0 mount repo files; OpenSearch's data lives in ~/opensearch.
stale_mounts() {
    docker inspect "$1" \
        --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null |
    while IFS= read -r src; do
        src="${src#/host_mnt}"
        [ -n "$src" ] && [[ "$src" != "$WORKSHOP_DIR"/* ]] && echo "$src"
    done
}
for c in postgres mem0; do
    if [ -n "$(stale_mounts "$c")" ]; then
        echo "$c mounts files outside $WORKSHOP_DIR (repo was moved?)"
        missing+=("$c")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing or stale: ${missing[*]}. Rebuilding with setup.sh."
    ./stop.sh
    ./setup.sh
else
    docker start "${CONTAINERS[@]}" >/dev/null && echo "Started all five containers"
fi

step "Services"
wait_for "OpenSearch" 180 curl -fsS "http://localhost:9200/_cluster/health"
wait_for "Mem0 API" 180 curl -fsS "http://localhost:8888/auth/setup-status"
wait_for "Mem0 dashboard" 180 curl -fsS "http://localhost:3000/api/health"

step "Python environment"
# PyTorch publishes no pip wheels for Intel Macs, so there use a conda env with
# conda-forge's pytorch and pip-install the rest on top. A named env keeps
# conda out of this repo's path, which contains spaces.
if [ "$(uname -sm)" = "Darwin x86_64" ]; then
    CONDA_ENV=odsc-workshop
    if ! conda run -n "$CONDA_ENV" true >/dev/null 2>&1; then
        echo "Creating conda env $CONDA_ENV from requirements.txt"
        if ! { conda create -y -q -n "$CONDA_ENV" -c conda-forge --override-channels python=3.13 'pytorch>=2.7,<3' &&
               conda run -n "$CONDA_ENV" python -m pip install -q -r requirements.txt; }; then
            conda env remove -y -q -n "$CONDA_ENV"
            exit 1
        fi
    else
        echo "conda env $CONDA_ENV found"
    fi
    PY="$(conda run -n "$CONDA_ENV" python -c 'import sys; print(sys.executable)')"
    ACTIVATE="conda activate $CONDA_ENV"
else
    if [ ! -x .venv/bin/python ]; then
        echo "Creating .venv from requirements.txt"
        if ! { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }; then
            rm -rf .venv
            exit 1
        fi
    else
        echo ".venv found"
    fi
    PY=.venv/bin/python
    ACTIVATE="source .venv/bin/activate"
fi

step "Validating environment"
"$PY" validate_environment.py

cat <<EOF

Mem0 dashboard:        http://localhost:3000
OpenSearch dashboards: http://localhost:5601
Stop everything later: ./stop.sh
EOF

# Hand over to an interactive zsh with the venv activated after ~/.zshrc runs,
# so conda's base environment doesn't shadow it.
rcdir="$(mktemp -d)"
cat > "$rcdir/.zshrc" <<EOF
ZDOTDIR="\$HOME"
source "\$HOME/.zshrc"
cd "$WORKSHOP_DIR"
$ACTIVATE
EOF
ZDOTDIR="$rcdir" exec zsh -i
