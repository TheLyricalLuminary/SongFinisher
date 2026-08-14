#!/usr/bin/env bash
set -euo pipefail

branch="claude/reconcile-branches"
remote="origin"

echo "==> Fetching branch $branch from $remote"
git fetch "$remote" "$branch"

# Try to checkout the branch. If it's only a remote branch, create a local tracking branch.
if git checkout "$branch" 2>/dev/null; then
  echo "==> Checked out $branch"
else
  echo "==> Creating local branch tracking $remote/$branch"
  git checkout -B "$branch" "$remote/$branch"
fi

echo "==> Running tests for Swift packages"

declare -a packages=(
  "Packages/Domain"
  "Packages/MelodyKit"
  "Packages/LyricEngine"
  "Packages/PersistenceKit"
)

for pkg in "${packages[@]}"; do
  echo "\n==> swift test --package-path $pkg"
  swift test --package-path "$pkg"
  echo "==> Completed tests for $pkg"
done

echo "\nAll tests finished successfully."
