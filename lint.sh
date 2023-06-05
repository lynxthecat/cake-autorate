#!/bin/sh
# export SHELLCHECK_OPTS="-e SC2244 -e SC2312"
find . -name '*.sh' ! -name '*_config*.sh' ! -name '*_defaults.sh' -print0 | exec xargs -0 shellcheck -x -o all
