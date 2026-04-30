#!/usr/bin/env bash
# 02-home-patcher.sh
# Applies a git diff patch to a repo on a hotfix branch, tags it, and opens a PR to main.
#
# Usage: ./sbin/02-home-patcher.sh <REPO_NAME> <PATCH_FILE> [TAG_NAME]
#   REPO_NAME   - Repo directory relative to workspace root (e.g., autobots-agents-pay)
#   PATCH_FILE  - Patch filename inside releases/ (e.g., autobots-agents-pay-hotfix.patch)
#   TAG_NAME    - Optional tag (e.g., v20260304-2); defaults to v$(date +%Y%m%d-%H%M)
# ================================
# sh sbin/02-home-patcher.sh autobots-agents-mer patch_main_to_develop.patch
# sh sbin/02-home-patcher.sh autobots-agents-pay Pay-patch_main_to_develop.patch
# ================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Step 1: Validate ────────────────────────────────────────────────────────

REPO_NAME="${1:-}"
PATCH_FILE="${2:-}"

if [[ -z "${REPO_NAME}" || -z "${PATCH_FILE}" ]]; then
    echo "Usage: $(basename "$0") <REPO_NAME> <PATCH_FILE> [TAG_NAME]"
    echo "  REPO_NAME   Repo directory relative to workspace root (e.g., autobots-agents-pay)"
    echo "  PATCH_FILE  Patch filename inside releases/ (e.g., autobots-agents-pay-hotfix.patch)"
    echo "  TAG_NAME    Optional tag (e.g., v20260304-2); defaults to v\$(date +%Y%m%d-%H%M)"
    exit 1
fi

REPO_DIR="${WORKSPACE_ROOT}/${REPO_NAME}"
if [[ ! -d "${REPO_DIR}" ]]; then
    echo "Error: Repo directory not found: ${REPO_DIR}"
    exit 1
fi

RELEASES_DIR="${WORKSPACE_ROOT}/releases"
PATCH_FILE="${RELEASES_DIR}/${PATCH_FILE}"

if [[ ! -f "${PATCH_FILE}" ]]; then
    echo "Error: Patch file not found: ${PATCH_FILE}"
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "Error: git is not installed or not in PATH"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "Error: gh (GitHub CLI) is not installed. Install it with: brew install gh"
    exit 1
fi

# ── Step 2: Generate tag and branch name ────────────────────────────────────

TAG_NAME="${3:-v$(date +%Y%m%d-%H%M)}"
HOTFIX_BRANCH="hotfix/${TAG_NAME}"

echo "==> Repo:    ${REPO_NAME}"
echo "==> Patch:   ${PATCH_FILE}"
echo "==> Tag:     ${TAG_NAME}"
echo "==> Branch:  ${HOTFIX_BRANCH}"

# ── Step 3: Pull latest main and create hotfix branch ───────────────────────

cd "${REPO_DIR}"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
    echo "Warning: Not on 'main' branch (currently on '${CURRENT_BRANCH}'). Switching to main."
    git checkout main
fi

echo "==> Pulling latest main"
git pull origin main

if git tag -l | grep -qx "${TAG_NAME}"; then
    echo "Error: Tag '${TAG_NAME}' already exists locally. Choose a different tag name."
    exit 1
fi

if git branch --list "${HOTFIX_BRANCH}" | grep -q .; then
    echo "Error: Branch '${HOTFIX_BRANCH}' already exists. Choose a different tag name."
    exit 1
fi

echo "==> Creating hotfix branch: ${HOTFIX_BRANCH}"
git checkout -b "${HOTFIX_BRANCH}"

# ── Step 4: Apply the patch ─────────────────────────────────────────────────

echo "==> Running dry-run check on patch"
if git apply --check --whitespace=fix "${PATCH_FILE}" 2>/dev/null; then
    echo "==> Dry run passed — applying patch cleanly"
    git apply --whitespace=fix "${PATCH_FILE}"
else
    # Check if patch is already fully applied (reverse check)
    if git apply --check --reverse --whitespace=fix "${PATCH_FILE}" 2>/dev/null; then
        echo "Warning: Patch is already fully applied — nothing to do."
        git checkout main
        git branch -d "${HOTFIX_BRANCH}"
        exit 0
    fi

    echo "Warning: Patch cannot apply cleanly — attempting 3-way merge"
    if git apply --3way --whitespace=fix "${PATCH_FILE}" 2>/dev/null; then
        echo "==> Patch applied via 3-way merge"
    else
        echo "Warning: 3-way merge had issues — falling back to --reject (skips already-applied hunks)"
        git apply --reject --whitespace=fix "${PATCH_FILE}" 2>/dev/null || true

        REJ_FILES="$(find . -name '*.rej' -not -path './.git/*' 2>/dev/null || true)"
        if [[ -n "${REJ_FILES}" ]]; then
            echo ""
            echo "Warning: The following reject files were created (hunks that could not be applied):"
            echo "${REJ_FILES}" | sed 's/^/    /'
            echo "Review and apply these manually, then delete the .rej files before committing."
            echo ""
            echo "Aborting — clean up .rej files and re-run, or apply the changes manually."
            git checkout main
            git branch -D "${HOTFIX_BRANCH}"
            exit 1
        else
            echo "==> All applicable hunks applied (already-applied hunks were skipped)"
        fi
    fi
fi

# ── Step 5: Stage, commit, tag ───────────────────────────────────────────────

echo "==> Changed files:"
git diff --name-only HEAD | sed 's/^/    /'

echo "==> Staging and committing"
git add .

COMMIT_MSG="hotfix(${TAG_NAME}): apply patch from away

Patch file: $(basename "${PATCH_FILE}")
Tag: ${TAG_NAME}"

git commit -m "${COMMIT_MSG}"

echo "==> Creating git tag: ${TAG_NAME}"
git tag "${TAG_NAME}"

# ── Step 6: Push branch and tag ─────────────────────────────────────────────

echo "==> Pushing branch to origin"
if ! git push origin "${HOTFIX_BRANCH}"; then
    echo "Error: Failed to push branch '${HOTFIX_BRANCH}' to origin."
    exit 1
fi

echo "==> Pushing tag to origin"
if ! git push origin "${TAG_NAME}"; then
    echo "Error: Failed to push tag '${TAG_NAME}' to origin."
    echo "  The tag was created locally. To remove it: git tag -d ${TAG_NAME}"
    exit 1
fi

# ── Step 7: Open PR to main ─────────────────────────────────────────────────

echo "==> Creating PR to main"
PR_URL="$(gh pr create \
    --base main \
    --head "${HOTFIX_BRANCH}" \
    --title "hotfix(${TAG_NAME}): apply patch from away" \
    --body "## Summary

Patch applied from away environment.

- **Patch file**: \`$(basename "${PATCH_FILE}")\`
- **Tag**: \`${TAG_NAME}\`
- **Branch**: \`${HOTFIX_BRANCH}\`

## Checklist
- [ ] Review changed files
- [ ] Run tests
- [ ] Merge to main
" 2>&1)"

# ── Step 8: Summary ─────────────────────────────────────────────────────────

echo ""
echo "Done."
echo "  Repo:    ${REPO_NAME}"
echo "  Tag:     ${TAG_NAME}"
echo "  Branch:  ${HOTFIX_BRANCH}"
echo "  Patch:   ${PATCH_FILE}"
echo "  PR:      ${PR_URL}"
