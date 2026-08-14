#!/usr/bin/env bash
# Initialise this folder as a git repo and publish it to GitHub as PRIVATE.
#
#   ./init-repo.sh [repo-name]
#
# Requires the GitHub CLI, authenticated once with:  gh auth login
set -euo pipefail

REPO_NAME="${1:-android-docker-emulator}"

command -v gh >/dev/null || {
  echo "gh (GitHub CLI) not found. Install it first:" >&2
  echo "  Ubuntu: sudo apt install gh     macOS: brew install gh" >&2
  exit 1
}

gh auth status >/dev/null 2>&1 || {
  echo "Not authenticated. Run: gh auth login" >&2
  exit 1
}

# Safety: never publish a real .env
if git check-ignore -q .env 2>/dev/null || [ ! -f .env ]; then
  :
else
  echo "Refusing to continue: .env exists but is not ignored." >&2
  exit 1
fi

chmod +x entrypoint.sh

if [ ! -d .git ]; then
  git init -b main
fi

git add .
git status --short

git diff --cached --name-only | grep -qx '.env' && {
  echo "ABORT: .env is staged. Check .gitignore." >&2
  exit 1
}

git commit -m "Headless official Android emulator in Docker, ADB over Tailscale" || true

# --private is the important flag here.
gh repo create "$REPO_NAME" \
  --private \
  --source=. \
  --remote=origin \
  --description "Official Google Android system image, headless in Docker on a homelab, mirrored to macOS via scrcpy over Tailscale" \
  --push

echo
echo "Done. Repo: $(gh repo view --json url -q .url)"
