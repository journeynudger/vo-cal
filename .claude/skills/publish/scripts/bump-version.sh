#!/usr/bin/env bash
# Bump VoCal's build number (and optionally marketing version) in project.yml,
# then regenerate the Xcode project so the change reaches the archive.
#
# project.yml is the SOURCE OF TRUTH for versioning. apps/ios/VoCal.xcodeproj is
# generated from it (gitignored) — never edit the .xcodeproj directly, it gets
# overwritten on the next `make ios-generate`.
#
# Format in apps/ios/project.yml (under targets.VoCal.settings.base):
#     MARKETING_VERSION: "0.1.0"      <- quoted string
#     CURRENT_PROJECT_VERSION: 1      <- bare integer (no quotes)
#
# Usage:
#   bump-version.sh                                   # build +1, keep marketing version
#   bump-version.sh --build-number N                  # set explicit build number
#   bump-version.sh --marketing-version X.Y.Z         # set marketing version, build +1
#   bump-version.sh --marketing-version X.Y.Z --build-number N
#
# App Store Connect rejects a build whose (marketing, build) pair is <= one already
# uploaded for the same train, so this script refuses to move either value backwards.

set -euo pipefail

# scripts/ -> publish/ -> skills/ -> .claude/ -> repo root
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PROJECT_YML="$ROOT_DIR/apps/ios/project.yml"

if [[ ! -f "$PROJECT_YML" ]]; then
  echo "ERROR: project.yml not found at $PROJECT_YML" >&2
  exit 1
fi

# ── Parse flags ──────────────────────────────────────────────────────────────
MARKETING_VERSION=""
BUILD_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --marketing-version) MARKETING_VERSION="${2:?--marketing-version needs a value}"; shift 2 ;;
    --build-number)      BUILD_NUMBER="${2:?--build-number needs a value}";           shift 2 ;;
    -h|--help)
      cat <<'USAGE'
bump-version.sh — bump VoCal's build number (and optionally marketing version) in
apps/ios/project.yml (the source of truth), then run `make ios-generate`.

Usage:
  bump-version.sh                                   # build +1, keep marketing version
  bump-version.sh --build-number N                  # set explicit build number
  bump-version.sh --marketing-version X.Y.Z         # set marketing version, build +1
  bump-version.sh --marketing-version X.Y.Z --build-number N

Refuses to move either value backwards (App Store Connect rejects a (marketing, build)
pair that is <= one already uploaded for the same train).
USAGE
      exit 0 ;;
    *) echo "Unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# ── Read current values ──────────────────────────────────────────────────────
# Tolerates quoted or bare values for either key.
CURRENT_MARKETING=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/')
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/')

if [[ -z "$CURRENT_MARKETING" || -z "$CURRENT_BUILD" ]]; then
  echo "ERROR: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from $PROJECT_YML" >&2
  exit 1
fi

echo "Current: v${CURRENT_MARKETING} (build ${CURRENT_BUILD})"

# ── Resolve new values ───────────────────────────────────────────────────────
NEW_MARKETING="${MARKETING_VERSION:-$CURRENT_MARKETING}"
NEW_BUILD="${BUILD_NUMBER:-$((CURRENT_BUILD + 1))}"

if ! [[ "$NEW_BUILD" =~ ^[0-9]+$ ]]; then
  echo "ERROR: build number must be a non-negative integer, got '$NEW_BUILD'" >&2
  exit 1
fi
if ! [[ "$NEW_MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: marketing version must be X.Y.Z, got '$NEW_MARKETING'" >&2
  exit 1
fi

# ── Validate: versions must not go backwards ─────────────────────────────────
version_to_tuple() { echo "$1" | awk -F. '{ printf "%d%03d%03d", $1, $2, $3 }'; }

if [[ $(version_to_tuple "$NEW_MARKETING") -lt $(version_to_tuple "$CURRENT_MARKETING") ]]; then
  echo "ERROR: Marketing version $NEW_MARKETING < current $CURRENT_MARKETING (refusing to go backwards)" >&2
  exit 1
fi
if [[ "$NEW_BUILD" -lt "$CURRENT_BUILD" ]]; then
  echo "ERROR: Build number $NEW_BUILD < current $CURRENT_BUILD (refusing to go backwards)" >&2
  exit 1
fi
if [[ "$NEW_MARKETING" == "$CURRENT_MARKETING" && "$NEW_BUILD" == "$CURRENT_BUILD" ]]; then
  echo "ERROR: Nothing to change (already at v${NEW_MARKETING} build ${NEW_BUILD})" >&2
  exit 1
fi

# ── Update project.yml ───────────────────────────────────────────────────────
# MARKETING_VERSION stays quoted; CURRENT_PROJECT_VERSION stays a bare integer —
# matching the existing project.yml conventions exactly.
sed -i '' "s/\(MARKETING_VERSION:\) *\"\{0,1\}[^\"#]*\"\{0,1\}/\1 \"${NEW_MARKETING}\"/" "$PROJECT_YML"
sed -i '' "s/\(CURRENT_PROJECT_VERSION:\) *\"\{0,1\}[0-9]*\"\{0,1\}/\1 ${NEW_BUILD}/" "$PROJECT_YML"

# ── Regenerate the Xcode project from the source of truth ─────────────────────
# `make ios-generate` runs `xcodegen generate` in apps/ios (see Makefile). The
# generated VoCal.xcodeproj is gitignored; this keeps it in sync with project.yml.
echo "Regenerating Xcode project (make ios-generate)..."
make -C "$ROOT_DIR" ios-generate

echo ""
echo "Bumped: v${CURRENT_MARKETING} (build ${CURRENT_BUILD}) -> v${NEW_MARKETING} (build ${NEW_BUILD})"
