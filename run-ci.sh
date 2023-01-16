#!/bin/bash

set -e -x -o pipefail

DUB_FLAGS=${DUB_FLAGS:-}
DCVER=${DC#*-}
DC=${DC%-*}
if [ "$DC" == "ldc" ]; then DC="ldc2"; fi

# Check for trailing whitespace"
grep -nrI --include='*.d' '\s$' . && (echo "Trailing whitespace found"; exit 1)

# test for successful release build
dub build -b release --compiler=$DC $DUB_FLAGS

# test for successful 32-bit build
if [ "$DC" == "dmd" ]; then
	dub build --arch=x86 $DUB_FLAGS
fi

dub test --compiler=$DC $DUB_FLAGS

if [ ${BUILD_EXAMPLE=1} -eq 1 ]; then
    for ex in $(\ls -1 examples/); do
        echo "[INFO] Building example $ex"
        (cd examples/$ex && dub build --compiler=$DC  && dub clean)
    done
fi

if [ ${RUN_TEST=1} -eq 1 ]; then
    for ex in `\ls -1 tests/*.d`; do
        script="${ex%.d}.sh"
        if [ -e "$script" ]; then
            echo "[INFO] Running test scipt $script"
            (cd tests && "./${script:6}")
        else
            echo "[INFO] Running test $ex"
            dub --temp-build --compiler=$DC --single $ex
        fi
    done
fi
