#!/usr/bin/env bash
#
# run-tests.sh - run mail-setup's tests.
#
#   ./tests/run-tests.sh            unit + shell + e2e
#   ./tests/run-tests.sh unit       Python unit tests for bin/* (fake servers)
#   ./tests/run-tests.sh shell      scripts/*.sh + mail-setup.sh in a sandbox $HOME
#   ./tests/run-tests.sh e2e        configure -> mail-pull -> pop-pull/getmail over
#                                   real TLS; plus e2e_master.sh on a configured
#                                   Linux master (skipped elsewhere)
#
# Nothing outside a temp dir is changed, except that e2e_master.sh sends one
# message to you on a real master and expunges it again.  A suite that can't
# run here (exit 77) counts as skipped, not failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
cd "$root" || exit 1
what="${1:-all}"

PY=""
for c in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
  command -v "$c" >/dev/null 2>&1 && { PY=$(command -v "$c"); break; }
done
[ -n "$PY" ] || { echo "run-tests.sh: no python3" >&2; exit 1; }

results=()
suite() {   # suite NAME CMD...
  name=$1; shift
  echo; echo "=== $name ==="
  "$@"; rc=$?
  case "$rc" in
    0)  results+=("PASS  $name") ;;
    77) results+=("SKIP  $name") ;;
    *)  results+=("FAIL  $name") ;;
  esac
}

case "$what" in unit|shell|e2e|all) : ;; *) echo "usage: $0 [unit|shell|e2e|all]" >&2; exit 2 ;; esac

if [ "$what" = unit ] || [ "$what" = all ]; then
  suite unit "$PY" -B -m unittest discover -s tests/unit -v
fi
if [ "$what" = shell ] || [ "$what" = all ]; then
  suite shell bash tests/shell/test_scripts.sh
fi
if [ "$what" = e2e ] || [ "$what" = all ]; then
  suite e2e-pull "$PY" -B -m unittest tests/e2e/test_pull_e2e.py -v
  suite e2e-master bash tests/e2e/e2e_master.sh
fi

echo; echo "=== summary ==="
printf '  %s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q '^FAIL'
