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

version=${1:?}
EDITOR=${EDITOR:-nano}

if asker "Would you like to create a new changelog entry? (y/n) "
then
	cur_date=$(date -I)
	sed -e '/Zep7RkGZ52/a\' -e '\n\n\#\# '"${cur_date}"' - Version '"${cur_version}"'\n\n**Release notes here**' -i CHANGELOG.md
	${EDITOR} CHANGELOG.md
fi
git add CHANGELOG.md
git commit -sm 'Updated CHANGELOG for '"${cur_version}"

if sed -E 's/(^cake_autorate_version=\")[^\"]+(\"$)/\1'"${cur_version}"'\2/' -i cake-autorate.sh
then
	echo Cake autorate version updated in cake-autorate.sh
fi
git add cake-autorate.sh
git commit -sm "Updated cake-autorate.sh version"

if sed -E 's|(<span id=\"cur_version\">)[^\<]+(</span>)|\1'"${cur_version}"'\2|' -i README.md
then
	echo Latest cake autorate version updated in README.md
fi
git add README.md
git commit -sm 'Updated latest version in README.md'

git push origin
