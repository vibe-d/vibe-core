#!/bin/bash

set -e
die() { echo "$@" 1>&2 ; exit 1; }

DUB_ARGS="--single ${DUB_ARGS:-}"

( dub $DUB_ARGS args.d | grep -q '^argtest=$' ) || die "Fail (no argument)"
( dub $DUB_ARGS args.d -- --argtest=aoeu | grep -q '^argtest=aoeu$' ) || die "Fail (with argument)"
( ( ! dub $DUB_ARGS args.d -- --inexisting 2>&1 ) | grep -qF 'Unrecognized command line option' ) || die "Fail (unknown argument)"

echo 'OK'
