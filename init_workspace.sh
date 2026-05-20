#!/usr/bin/env bash
# =================================================================
# Node-Guardian - Workspace Bootstrapper
# ================================================================

set -euo pipefail

echo "[INFO] Starting workspace initialization for node-guardian..."

DIRS=(
    "bin"
    "lib"
    "config"
    "tests"
    ".github/workflows"
    ".github/ISSUE_TEMPLATE"
)

for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "[INFO] Created directory: $dir"
    else
        echo "[WARN] Directory already exists: $dir"
    fi
done

touch lib/core.sh lib/sysctl.sh lib/network.sh lib/k8s-utils.sh
touch config/sysctl_baseline.env config/cis_rules.cfg config/backup_targets.conf
touch CHANGELOG.md

BINS=("kn-preflight" "kn-security" "kn-diagnose" "kn-backup")
for bin_script in "${BINS[@]}"; do
    target="bin/$bin_script"
    if [ ! -f "$target" ]; then
        cat << 'EOF' > "$target"
#!/usr/bin/env bash
# Kube-Node-Guardian - Core Component
set -euo pipefail
echo "[INFO] Initializing component..."
EOF
        chmod +x "$target"
        echo "[INFO] Created executable: $target"
    fi
done

echo "[SUCCESS] Workspace skeleton is ready! Ready for engineering."
