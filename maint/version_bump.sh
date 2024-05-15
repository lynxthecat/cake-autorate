#!/usr/bin/env bash

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

version=${1:?}
is_latest=${2:-1}
EDITOR=${EDITOR:-nano}
version_major=$(cut -d. -f1,2 <<<"${version}")

if asker "Would you like to create a new changelog entry? (y/n) "
then
	cur_date=$(date -I)
	sed -e '/Zep7RkGZ52/a\' -e '\n\n\#\# '"${cur_date}"' - Version '"${version}"'\n\n**Release notes here**' -i CHANGELOG.md
fi
${EDITOR} CHANGELOG.md
( git add CHANGELOG.md && git commit -sm "Updated CHANGELOG for ${version}"; ) || :

if sed -E 's/(^cake_autorate_version=\")[^\"]+(\"$)/\1'"${version}"'\2/' -i cake-autorate.sh
then
	echo Cake autorate version updated in cake-autorate.sh
	( git add cake-autorate.sh
	git commit -sm "Updated cake-autorate.sh version to ${version}"; ) || :
fi

if ((is_latest))
then
	if sed -E -e 's|(<span id=\"version\">)[^\<]+(</span>)|\1'"${version}"'\2|' \
			  -e 's|\[v[^\<]+( branch[^\<]+tree\/v)([^\)]+)|\[v'${version_major}'\1'${version_major}'|' -i README.md
	then
		echo Latest cake autorate version updated in README.md
	fi
	( git add README.md
	git commit -sm "Updated latest version in README.md to ${version}"; ) || :
fi
