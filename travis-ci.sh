#!/bin/bash

set -e -x -o pipefail

export DUB_ARGS="--build-mode=${DUB_BUILD_MODE:-separate} ${DUB_ARGS:-}"

# test for successful release build
dub build -b release --compiler=$DC -c $CONFIG $DUB_ARGS

# test for successful 32-bit build
if [ "$DC" == "dmd" ]; then
	dub build --arch=x86 -c $CONFIG $DUB_ARGS
fi

dub test --compiler=$DC -c $CONFIG $DUB_ARGS

if [ ${BUILD_EXAMPLE=1} -eq 1 ]; then
    for ex in $(\ls -1 examples/); do
        echo "[INFO] Building example $ex"
        # --override-config vibe-core/$CONFIG
        (cd examples/$ex && dub build --compiler=$DC $DUB_ARGS && dub clean)
    done
fi
if [ ${RUN_TEST=1} -eq 1 ]; then
    for ex in `\ls -1 tests/*.d`; do
        script="${ex:0:-2}.sh"
        if [ -e "$script" ]; then
            echo "[INFO] Running test scipt $script"
            (cd tests && "./${script:6}")
        else
            echo "[INFO] Running test $ex"
            dub --temp-build --compiler=$DC --single $DUB_ARGS $ex # --override-config vibe-core/$CONFIG
        fi
    done
fi
