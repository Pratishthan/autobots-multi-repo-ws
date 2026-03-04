#!/usr/bin/env bash
# 01-home-extractor.sh
# Tags a repo at HEAD, optionally runs pre-zip modifications, creates a clean zip archive.
#
# Usage: ./sbin/01-home-extractor.sh <REPO_NAME> [TAG_NAME]
#   REPO_NAME  - Repo directory relative to workspace root (e.g., autobots-agents-pay)
#   TAG_NAME   - Optional tag (e.g., v20260304-13); defaults to v$(date +%Y%m%d-%H)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASES_DIR="${WORKSPACE_ROOT}/releases"

# ── Step 1: Validate ────────────────────────────────────────────────────────

REPO_NAME="${1:-}"
if [[ -z "${REPO_NAME}" ]]; then
    echo "Usage: $(basename "$0") <REPO_NAME> [TAG_NAME]"
    echo "  REPO_NAME  Repo directory relative to workspace root (e.g., autobots-agents-pay)"
    echo "  TAG_NAME   Optional tag (e.g., v20260304-13); defaults to v\$(date +%%Y%%m%%d-%%H)"
    exit 1
fi

REPO_DIR="${WORKSPACE_ROOT}/${REPO_NAME}"
if [[ ! -d "${REPO_DIR}" ]]; then
    echo "Error: Repo directory not found: ${REPO_DIR}"
    exit 1
fi

if ! command -v git &>/dev/null; then
    echo "Error: git is not installed or not in PATH"
    exit 1
fi

if ! command -v zip &>/dev/null; then
    echo "Error: zip is not installed. Install it with: brew install zip  (macOS) or apt install zip (Linux)"
    exit 1
fi

# ── Step 2: Generate tag ────────────────────────────────────────────────────

TAG_NAME="${2:-v$(date +%Y%m%d-%H)}"
echo "==> Repo:    ${REPO_NAME}"
echo "==> Tag:     ${TAG_NAME}"

# ── Step 3: Create & push git tag ──────────────────────────────────────────

cd "${REPO_DIR}"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
    echo "Warning: Not on 'main' branch (currently on '${CURRENT_BRANCH}'). Proceeding anyway."
fi

echo "==> Pull latest code from main"
git pull origin main

if git tag -l | grep -qx "${TAG_NAME}"; then
    echo "Error: Tag '${TAG_NAME}' already exists locally. Choose a different tag name."
    exit 1
fi

echo "==> Creating git tag: ${TAG_NAME}"
git tag "${TAG_NAME}"

echo "==> Pushing tag to origin..."
if ! git push origin "${TAG_NAME}"; then
    echo "Error: Failed to push tag '${TAG_NAME}' to origin."
    echo "  The tag was created locally. To remove it: git tag -d ${TAG_NAME}"
    exit 1
fi

# ── Step 4: Run pre-zip hook ────────────────────────────────────────────────

PRE_ZIP_HOOK="${REPO_DIR}/sbin/pre-zip-mods.sh"
if [[ -f "${PRE_ZIP_HOOK}" ]]; then
    echo "==> Running pre-zip hook: ${PRE_ZIP_HOOK}"
    bash "${PRE_ZIP_HOOK}"
else
    echo "==> No pre-zip-mods.sh found, skipping"
fi

# ── Step 5: Create zip ──────────────────────────────────────────────────────

mkdir -p "${RELEASES_DIR}"
ZIP_FILE="${RELEASES_DIR}/${REPO_NAME}-${TAG_NAME}.zip"

echo "==> Creating zip: ${ZIP_FILE}"
cd "${REPO_DIR}"

# Parse ${REPO_NAME}/.gitignore to build exclude args dynamically.
# Rules:
#   - Skip blank lines, comments (#), and negation patterns (!)
#   - Strip leading / (root-relative gitignore anchoring; zip paths have no leading /)
#   - Pattern ending with /  → directory; exclude dir entry and all contents  (pattern*)
#   - All other patterns    → may be file or dir; exclude both (pattern and pattern/*)
GITIGNORE_EXCLUDES=()
GITIGNORE_FILE="${REPO_DIR}/.gitignore"
if [[ -f "${GITIGNORE_FILE}" ]]; then
    echo "==> Reading exclusions from ${REPO_NAME}/.gitignore"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines, comments, and negation patterns
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" =~ ^! ]] && continue
        # Strip trailing whitespace
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue
        # Strip leading / (root-anchored gitignore patterns)
        line="${line#/}"
        [[ -z "${line}" ]] && continue
        if [[ "${line}" == */ ]]; then
            GITIGNORE_EXCLUDES+=("--exclude" "${line}*")
        else
            GITIGNORE_EXCLUDES+=("--exclude" "${line}")
            GITIGNORE_EXCLUDES+=("--exclude" "${line}/*")
        fi
    done < "${GITIGNORE_FILE}"
else
    echo "Warning: No .gitignore found at ${GITIGNORE_FILE}"
fi

zip -r "${ZIP_FILE}" . \
    --exclude ".git/*" \
    --exclude ".claude/*" \
    "${GITIGNORE_EXCLUDES[@]+"${GITIGNORE_EXCLUDES[@]}"}"

# ── Step 6: Revert local changes ────────────────────────────────────────────

echo "==> Reverting local changes..."
git restore . 2>/dev/null || true

UNTRACKED="$(git status --porcelain 2>/dev/null | grep '^??' || true)"
if [[ -n "${UNTRACKED}" ]]; then
    echo "Warning: Untracked files remain (not auto-deleted):"
    echo "${UNTRACKED}"
fi

# ── Step 7: Summary ─────────────────────────────────────────────────────────

ZIP_SIZE="$(du -sh "${ZIP_FILE}" | cut -f1)"
echo ""
echo "Done."
echo "  Repo:  ${REPO_NAME}"
echo "  Tag:   ${TAG_NAME}"
echo "  Zip:   ${ZIP_FILE}"
echo "  Size:  ${ZIP_SIZE}"
