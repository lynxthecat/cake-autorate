#!/bin/sh
export SHELLCHECK_OPTS="-e SC2244 -e SC2312 -e SC2086 -e SC2261"
find . -name '*.sh' ! -name '*config*.sh' ! -name 'defaults.sh' -print0 | exec xargs -0 shellcheck -x -o all
