#!/usr/bin/env bash

set -e
set -o pipefail

# https://stackoverflow.com/a/72183258/134409
# this hangs in CI (no tty?)
# yes 'will cite' | parallel --citation 2>/dev/null 1>/dev/null || true
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  mkdir -p "$HOME/.parallel"
  touch "$HOME/.parallel/will-cite"
fi


# Avoid re-building workspace in parallel in all test derivations
>&2 echo "### Making sure workspace is built..."
nix build -L .#debug.workspaceBuild 2>&1 | ts -s


function cli_test_reconnect() {
  echo "### Starting reconnect test..."
  nix build -L .#debug.cli-test.reconnect 2>&1 | ts -s
}
export -f cli_test_reconnect

function cli_test_latency() {
  echo "### Starting latency test..."
  nix build -L .#debug.cli-test.latency 2>&1 | ts -s
}
export -f cli_test_latency

function cli_test_cli() {
  echo "### Starting cli test..."
  nix build -L .#debug.cli-test.cli 2>&1 | ts -s
}
export -f cli_test_cli

function cli_test_rust_tests() {
  echo "### Starting integration test..."
  nix build -L .#debug.cli-test.rust-tests 2>&1 | ts -s
}
export -f cli_test_rust_tests

function cli_test_always_fail() {
  set -o pipefail
  echo "### Starting always_fail test..."
  # this must fail, so we know nix build is actually running tests
  ! nix build -L .#debug.cli-test.always-fail 2>&1 | ts -s
}
export -f cli_test_always_fail

>&2 echo "### Starting all tests in parallel..."
# --load to keep the load under-control, especially during target dir extraction
# --delay to let nix start extracting and bump the load
# --memfree to make sure tests have enough memory to run
# --nice to let you browse twitter without lag while the tests are running
# try to keep the slowest tests first
parallel --load 150% --delay 5 --memfree 512M --nice 15 ::: \
  cli_test_rust_tests \
  cli_test_latency \
  cli_test_reconnect \
  cli_test_cli \
  cli_test_always_fail
