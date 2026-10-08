#!/usr/bin/env bash
# Update ccserver onto the latest upstream moon_rs.
#
# Strategy: ccserver history is rooted at the upstream baseline commit, so our
# changes are a thin delta on top of upstream. This script fetches upstream and
# rebases our delta onto `upstream/main`.
#
# Usage:
#   scripts/update-upstream.sh            # rebase onto upstream/main
#   scripts/update-upstream.sh <ref>      # rebase onto an explicit tag/commit
#
# After a successful rebase, update the recorded baseline:
#   - AGENTS.md  meta block `upstream_baseline`
#   - docs/agent/STATE.md  `## 上游基线`
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM_URL="${CCS_UPSTREAM_URL:-https://github.com/sniper00/moon_rs.git}"
TARGET="${1:-upstream/main}"

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "adding upstream remote: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
fi

echo "==> fetching upstream"
git fetch upstream --tags --prune

if ! git rev-parse --verify --quiet "$TARGET" >/dev/null; then
    echo "target '$TARGET' not found after fetch" >&2
    exit 1
fi

NEW_REV="$(git rev-parse "$TARGET")"
echo "==> rebasing current branch onto $TARGET ($NEW_REV)"
echo "    (resolve conflicts, then: git rebase --continue)"

if ! git rebase "$TARGET"; then
    cat >&2 <<'EOF'

rebase stopped. Common conflicts and how to resolve:
  - crates/*/Cargo.toml        -> keep upstream deps + our default-feature edits
  - crates/moon-runtime/**     -> prefer upstream; re-apply our small fixes
  - lualib/, assets/, docs/    -> ours usually wins (new files), keep both sides
Then run `git rebase --continue` and `cargo xtask agent-check`.
EOF
    exit 1
fi

echo "==> verifying build + memory layer"
cargo check --workspace
cargo xtask agent-check

echo
echo "Rebase done. Now record the new baseline:"
echo "  upstream_baseline: $NEW_REV"
echo "Update AGENTS.md (meta block) and docs/agent/STATE.md (上游基线)."
