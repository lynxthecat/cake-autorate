#!/bin/bash

set -e

asker() {
	read -r -p "$1" yn
	case ${yn} in
		[yY]) return 0 ;;
		[nN]) return 1 ;;
		*) asker "$@" ;;
	esac
}

asker "Would you like to proceed? This script will erase all your work. (y/n) " || exit 1
git reset --hard

branch=${1:?}

sed -E 's|(BRANCH=\"\$\{CAKE_AUTORATE_BRANCH:-\$\{2-)[^\}]+(\}\})\"|\1'"${branch}"'\2|' -i setup.sh
git add setup.sh
git commit -sm "Update setup.sh branch for release"
git push -u origin "${branch}"
