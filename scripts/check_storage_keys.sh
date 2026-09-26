#!/usr/bin/env bash
# Storage key inventory linter (Issue #330).
#
# Every `const NAME: Symbol = ...` in src/storage.rs must be listed in
# docs/STORAGE_KEYS.md by its constant name (in backticks) and, for
# `symbol_short!` keys, by its symbol string. Fails closed: any Symbol
# constant the parser cannot classify is an error, not a skip.
set -euo pipefail

SRC="${1:-src/storage.rs}"
DOC="${2:-docs/STORAGE_KEYS.md}"
fail=0
count=0

while IFS= read -r line; do
  name=$(sed -E 's/.*const ([A-Z0-9_]+): *Symbol.*/\1/' <<<"$line")
  count=$((count + 1))
  if [[ "$line" =~ symbol_short!\(\"([A-Za-z0-9_]+)\"\) ]]; then
    sym="${BASH_REMATCH[1]}"
    if ! grep -qF "\`\"$sym\"\`" "$DOC"; then
      echo "MISSING: symbol \"$sym\" ($name) not documented in $DOC"; fail=1
    fi
  elif [[ "$line" =~ =\ *([A-Z0-9_]+)\; ]]; then
    : # alias of another constant; the target is checked on its own line
  else
    echo "UNKNOWN: cannot classify Symbol constant '$name': $line"; fail=1
  fi
  if ! grep -qF "\`$name\`" "$DOC"; then
    echo "MISSING: constant $name not documented in $DOC"; fail=1
  fi
done < <(grep -E '^\s*(pub(\([a-z]+\))? )?const [A-Z0-9_]+: *Symbol' "$SRC")

# Symbol::new keys cannot be inventoried statically; reject them.
if grep -nE 'Symbol::new\(' "$SRC"; then
  echo "UNKNOWN: Symbol::new in $SRC — use a documented const key"; fail=1
fi

if [[ $count -eq 0 ]]; then
  echo "ERROR: no Symbol constants found in $SRC (parser broken?)"; exit 1
fi
if [[ $fail -ne 0 ]]; then
  echo "Storage key inventory check FAILED — update $DOC"; exit 1
fi
echo "Storage key inventory OK ($count constants documented)"
