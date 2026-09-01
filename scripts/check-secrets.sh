#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
cd "$project_root"

patterns=(
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{40,}'
  'sk-[A-Za-z0-9_-]{20,}'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  '(api[_-]?key|access[_-]?token|client[_-]?secret|password)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}'
)

files=(${(f)"$(git ls-files 2>/dev/null || find . -type f -not -path './.git/*' -not -path './.build/*' -not -path './dist/*')"})
(( ${#files} )) || exit 0

found=0
for pattern in $patterns; do
  if rg --line-number --hidden --glob '!scripts/check-secrets.sh' --glob '!.git/**' --glob '!.build/**' --glob '!dist/**' --regexp "$pattern" -- $files; then
    found=1
  fi
done

if (( found )); then
  print -u2 "Potential credential material found. Inspect and remove it before committing."
  exit 1
fi

print "Secret-pattern scan passed."
