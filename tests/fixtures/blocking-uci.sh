#!/usr/bin/env bash
# shellcheck disable=SC2154  # CAKE_AUTORATE_TEST_DIR is supplied by fatal-status.sh.

case ${1}:${2:-} in
	show:cake-autorate)
		: > "${CAKE_AUTORATE_TEST_DIR}/discovery.ready"
		while [[ ! -e ${CAKE_AUTORATE_TEST_DIR}/discovery.release ]]
		do
			:
		done
		printf '%s\n' "cake-autorate.primary.enabled='1'"
		;;
	get:cake-autorate.primary.enabled)
		printf '%s\n' 1
		;;
	show:cake-autorate.primary)
		printf '%s\n' "cake-autorate.primary.enabled='1'"
		;;
	*)
		exit 1
		;;
esac
