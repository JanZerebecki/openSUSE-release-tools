#!/bin/bash

set -e
shopt -s nullglob

self=$(readlink $(type -p "$0"))

: ${project:=openSUSE:Factory}
: ${api:=api.opensuse.org}
: ${repos:=$project/standard}

groups="000package-groups"
product="000product"
releases="000release-packages"

cachedir=${XDG_CACHE_HOME:-~/.cache}/opensuse-packagelists/$api/$project

_osc=`type -p osc`
osc()
{
    "$_osc" -A "https://$api" "$@"
}

checkin() {
	if [ -n "$dryrun" ]; then
		osc diff
	else
		osc addremove
		osc ci -m "Automatic update"
	fi
}

if [ -z "$FORCE" ]; then
	if ! osc api "/source/$project/" | grep -q "$product"  ; then
		osc undelete -m revive "$project/$product"
	fi
	bs_status=`osc api "/build/$project/_result?package=$product&repository=standard"`
	if echo "${bs_status}" | grep -q 'building\|dirty'; then
		echo "$project build in progress, skipping."
		exit 0
	fi
fi

mkdir -p "$cachedir"
cd "$cachedir"

todo=("$product" "$groups")
if [ -z "$skip_releases" ]; then
	todo+=("$releases")
	if ! osc api "/source/$project/" | grep -q "$releases"  ; then
		osc undelete -m revive "$project/$releases"
	fi
fi
# update package checkouts
for i in "${todo[@]}"; do
	if [ ! -e "$i" ]; then
		osc co -c "$project/$i"
	fi
	pushd "$i"
	if ! osc status; then
		# merge conflict etc, try to check out new
		popd
		rm -rf "$i"
		osc co -c "$project/$i"
	else
		osc up
		popd
	fi
done

[ -z "$releases" ] || rm -f "$cachedir/$releases"/*
cd "$cachedir/$product"
rm -f -- *
cp .osc/_service .
cp "$cachedir/$groups"/* .
rm -f supportstatus.txt groups.yml package-groups.changes
for i in *.spec.in; do
  mv -v $i "${i%.in}"
done
${self%.sh}.py -i "$cachedir/$groups" -r $repos -o . -a x86_64 update
${self%.sh}.py -i "$cachedir/$groups" -r $repos -o . -a x86_64 solve
for i in $delete_products; do
	rm -vf -- "$i"
done
for i in *.product; do
   /usr/lib/obs/service/create_single_product $PWD/$i $PWD $(cat .osc/_project)
done
for i in $delete_kiwis; do
	rm -vf -- "$i"
done
if [ -z "$skip_releases" ]; then
	mv -v *.spec "$cachedir/$releases"
else
	rm -vf *.spec
fi
echo '<multibuild>' > _multibuild
for file in *.kiwi; do
	container="${file##*/}"
	container="${container%.kiwi}"
	echo "  <package>${container}</package>" >> _multibuild
done
echo '</multibuild>' >> _multibuild
cat << EOF > stub.kiwi
# prevent building single kiwi files twice
Name: stub
Version: 0.0
EOF
checkin

if [ -z "$skip_releases" ]; then
	cd "$cachedir/$releases"
	echo '<multibuild>' > _multibuild
	for file in *.spec; do
		container="${file##*/}"
		container="${container%.spec}"
		echo "  <package>${container}</package>" >> _multibuild
	done
	echo '</multibuild>' >> _multibuild
	cat <<-EOF > stub.spec
	# prevent building single spec files twice
	Name: stub
	Version: 0.0
	EOF
	checkin
fi