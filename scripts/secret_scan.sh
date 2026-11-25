#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

declare -a files=()

if git rev-parse --show-toplevel >/dev/null 2>&1; then
  while IFS= read -r -d '' path; do
    case "$path" in
      scripts/secret_scan.sh)
        continue
        ;;
    esac
    files+=("$path")
  done < <(git ls-files -z)

  forbidden_paths=(
    "Config/Secrets.xcconfig"
    ".env"
  )

  for forbidden in "${forbidden_paths[@]}"; do
    if git ls-files --error-unmatch "$forbidden" >/dev/null 2>&1; then
      echo "Forbidden tracked secret file: $forbidden"
      exit 1
    fi
  done

  while IFS= read -r tracked_env; do
    [[ -z "$tracked_env" ]] && continue
    echo "Forbidden tracked secret-like file: $tracked_env"
    exit 1
  done < <(git ls-files -- '.env.*' '*.p8' '*.pem' '*.key')
else
  while IFS= read -r -d '' path; do
    case "$path" in
      ./Config/Secrets.xcconfig|./scripts/secret_scan.sh|./.git/*|./DerivedData/*|./.build/*)
        continue
        ;;
    esac
    files+=("${path#./}")
  done < <(find . -type f -print0)
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No files to scan."
  exit 0
fi

# grep -E (POSIX ERE) : pas de dépendance à ripgrep, fonctionne sur macOS et Linux.
patterns=(
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk_(live|test)_[A-Za-z0-9]{16,}'
  'rk_(live|test)_[A-Za-z0-9]{16,}'
  'sb_secret_[A-Za-z0-9_-]{20,}'
  'https?://[a-z0-9-]+\.supabase\.co'
  'postgresql://[^[:space:]]+'
  'ca-app-pub-[0-9]{16}~[0-9]{10}'
  'ca-app-pub-[0-9]{16}/[0-9]{10}'
)

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

for pattern in "${patterns[@]}"; do
  if printf '%s\0' "${files[@]}" | xargs -0 grep -nIHE -e "$pattern" -- >>"$tmpfile" 2>/dev/null; then
    :
  fi
done

if [[ -s "$tmpfile" ]]; then
  echo "Potential secret(s) detected:"
  sort -u "$tmpfile"
  exit 1
fi

echo "Secret scan passed."
