#!/bin/bash

set -e
die() { echo "$@" 1>&2 ; exit 1; }

( dub --single args.d | sed 's/\x0D$//' | grep -q '^argtest=$' ) || die "Fail (no argument): '`dub --single args.d`'"
( dub --single args.d -- --argtest=aoeu | sed 's/\x0D$//' | grep -q '^argtest=aoeu$' ) || die "Fail (with argument): '`dub --single args.d -- --argtest=aoeu`'"
( ( ! dub --single args.d -- --inexisting 2>&1 ) | sed 's/\x0D$//' | grep -qF 'Unrecognized command line option' ) || die "Fail (unknown argument): '`dub --single args.d -- --inexisting 2>&1`'"

echo 'OK'
