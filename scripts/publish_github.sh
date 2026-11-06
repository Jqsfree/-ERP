#!/usr/bin/env bash
set -euo pipefail
# Execute locally with GitHub CLI authenticated. This NEVER overwrites an existing repo.
command -v gh >/dev/null || { echo '需要安装 gh (GitHub CLI)' >&2; exit 1; }
gh auth status >/dev/null
repo="${1:-Jqsfree/kaibao-sales-app}"
if gh repo view "$repo" >/dev/null 2>&1; then
  echo "仓库 $repo 已存在，为避免覆盖自动终止。请手动核对远端。" >&2
  exit 1
fi
if [[ ! -d .git ]]; then git init -b main; fi
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add .
  git commit -m 'feat: offline-first Kaibao sales Android prototype'
fi
# Use a private repository by default because this system will process business records.
gh repo create "$repo" --private --source=. --remote=origin --push
printf '已推送到 https://github.com/%s\n' "$repo"
