#!/bin/sh

if ! mdformat --help | tail -1 | grep -q ' mdformat_gfm:'
then
	cat >&2 <<-EOF
	You must install both mdformat and mdformat-gfm.

	Using PIP:
	  pip install mdformat mdformat-gfm

	Using PIPX:
	  pipx install mdformat
	  pipx inject mdformat mdformat-gfm

EOF

	exit 1
fi

exec mdformat --wrap=70 .
