#!/bin/zsh
# Runs the whole test suite at the repo root.
# Command Line Tools Swift 6.4 quirk: the test build sometimes fails with "plugin for module
# 'TestingMacros' not found" (the emit-module job misses the macro plugin flag) on identical sources.
# Extra arguments go to `swift test` (e.g. --filter RFBCoreTests).
# Retrying the build fixes it, so build tests with retries first, then run them without rebuilding.
set -u
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8; do
  if swift build --build-tests > .build/test-build.log 2>&1; then
    exec swift test --skip-build "$@"
  fi
  if ! grep -q "TestingMacros" .build/test-build.log; then
    cat .build/test-build.log; exit 1
  fi
  echo "test build hit the TestingMacros plugin flake (attempt $i), retrying" >&2
done
cat .build/test-build.log; exit 1
