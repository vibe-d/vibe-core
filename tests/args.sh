#!/bin/bash

set -e
die() { echo "$@" 1>&2 ; exit 1; }

( dub args.d | grep -q '^argtest=$' ) || die "Fail (no argument): '`dub args.d`'"
( dub args.d --argtest=aoeu | grep -q '^argtest=aoeu$' ) || die "Fail (with argument): '`dub args.d --argtest=aoeu`'"
( ( ! dub args.d --inexisting 2>&1 ) | grep -qF 'Unrecognized command line option' ) || die "Fail (unknown argument): '`dub args.d --inexisting 2>&1`'"

echo 'OK'
