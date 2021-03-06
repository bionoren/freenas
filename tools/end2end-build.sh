#!/bin/sh
#
# An end-to-end build script which sets up a sourcebase from scratch, builds it
# for a series of architectures, and posts the images to a .
#
# usage: end2end-build.sh [-Cnr] [-A architecture] [-b branch] [-c cvsup-host] \
#			  [-f config-file] [-p local-postdir-base] \
#			  [-t build-tmpdir-template] [-T build-target]
#
# NOTES:
#
# -- -A can be specfied multiple times to generate a list of architectures to
#    build; defaults to amd64 and i386 today.
# -- -C means `force no-clean'.
# -- -f can be specified multiple times to source multiple config files (good
#    idea when working with multiple branches / releases to reduce code
#    duplication).
# -- -n fake build/image posting.
# -- -r release build.
# -- Look at `User definable functions' for a list of functions that you will
#    probably want to override.
# -- build-target is an option that can be specified multiple times, and the
#    implied / ever present build target is os-base.
#

# Values you shouldn't change.

BUILD_ENV_COMMON=
CLEAN=true
# Define beforehand to work around shell bugs.
LOCAL_POSTDIR=/dev/null
PROJECT_NAME=FIXME
RELEASE=FIXME2
SCRIPTDIR="$(realpath "$(dirname "$0")")"
TMPDIR=/dev/null

# Values you can specify via the command-line (or the config file).

BRANCH=trunk
BUILD_TARGETS="os-base"
CONFIG_FILES=
CVSUP_HOST=cvsup1.freebsd.org
DEFAULT_ARCHS="amd64 i386"
ECHO=
LOCAL_POSTDIR_BASE=/dev/null
RELEASE_BUILD=false
TMPDIR_TEMPLATE=e2e-bld.XXXXXXXX

# User definable functions.

# Generate release notes.
#
# Echos out filename if successful and returns 0. Returns a non-zero exit code
# otherwise.
generate_release_notes() {
	local release_notes_file
	local build_target_arch

	build_target_arch=$1

	if TMPDIR2=$(mktemp -d tmp.XXXXXX)
	then
		release_notes_file="$TMPDIR2/README"
		(
		 cat ReleaseNotes
		 "$SCRIPTDIR/checksum-to-release-format.sh" $build_target_arch
		 ) > "$TMPDIR2/README"
	else
		return $?
	fi
	echo $release_notes_file
	return 0
}

# Patch the sourcebase.
#
# Arguments:
# 1 - build directory
patch_source() {
	:
}

# Pull the sourcebase(s).
#
# Arguments:
# 1 - build directory
pull() {
	svn co https://freenas.svn.sourceforge.net/svnroot/freenas/$BRANCH $1
}

# Post files via a user-defined method.
#
# Arguments:
#   - a list of files to post
post_remote_files() {
	local arch
	local branch_reldir

	arch=$1; shift

	case "$BRANCH" in
	trunk)
		branch_reldir=FreeNAS-8-nightly
		;;
	*)
		# e.g. FreeNAS-8.2.0/x86
		branch_reldir=FreeNAS-${RELEASE%%-*}/$arch
		;;
	esac
	_do scp -o BatchMode=yes $* \
	    ${SFUSER:-yaberauneya},freenas@frs.sourceforge.net:/home/frs/project/f/fr/freenas/$branch_reldir
}

#
#

# End user definable functions.

_do()
{
	$ECHO "$@"
}

_setup() {
	export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
	export SHELL=/bin/sh

	TMPDIR=$(realpath "$(mktemp -d $TMPDIR_TEMPLATE)")
	chmod 0755 $TMPDIR
	pull $TMPDIR 2>&1 > $TMPDIR/pull.log
	tail -n 30 $TMPDIR/pull.log
	cd $TMPDIR
	patch_source $TMPDIR
	if [ -d "$LOCAL_POSTDIR_BASE" ]
	then
		LOCAL_POSTDIR="$LOCAL_POSTDIR_BASE/$(env LC_LANG=C date '+%Y-%m-%d')"
		sudo mkdir -p "$LOCAL_POSTDIR"
	else
		: ${LOCAL_POSTDIR=}
	fi
}

_cleanup() {
	sudo rm -Rf $TMPDIR
}

_post_local_files() {
	if [ -d "$LOCAL_POSTDIR" ]
	then
		_do sudo cp $file* "$LOCAL_POSTDIR"/.
	fi
}

_post_images() {
	local arch file build_target

	arch=$1
	build_target=$2

	(cd $build_target/$arch
	 # End-user rebranding; see build/nano_env for more details.
	 case "$arch" in
	 amd64)
		arch=x64
		;;
	 i386)
		arch=x86
		;;
	 esac
	 for file in $(ls *.iso *.pbi *.txz *.xz 2>/dev/null)
	 do
		sudo sh -c "sha256 $file > $file.sha256.txt"
		_post_local_files $arch $file*
		post_remote_files $arch $file*
	 done)
}

set -e
while getopts 'A:b:c:Cf:np:rt:T:' _OPTCH
do
	case "$_OPTCH" in
	A)
		_ARCH=
		for _ARCH in $DEFAULT_ARCHS
		do
			if [ "$_ARCH" = "$OPTARG" ]
			then
				_ARCH=$OPTARG
				break
			fi
		done
		if [ -z "$_ARCH" ]
		then
			echo "${0##*/}: ERROR: unknown architecture: $OPTARG"
			exit 1
		fi
		ARCHS="${ARCHS+$ARCHS }"
		ARCHS="$ARCHS$OPTARG"
		;;
	b)
		BRANCH=$OPTARG
		;;
	c)
		CVSUP_HOST=$OPTARG
		;;
	C)
		CLEAN=false
		;;
	f)
		CONFIG_FILES="$CONFIG_FILES $OPTARG"
		;;
	n)
		ECHO=echo
		;;
	p)
		LOCAL_POSTDIR_BASE=$OPTARG
		;;
	r)
		RELEASE_BUILD=true
		;;
	t)
		TMPDIR_TEMPLATE=$OPTARG
		;;
	T)
		BUILD_TARGETS="$BUILD_TARGETS $OPTARG"
		;;
	*)
		echo "${0##*/}: ERROR: unhandled/unknown option: $_OPTCH"
		exit 1
		;;
	esac
done

: ${ARCHS=$DEFAULT_ARCHS}

for CONFIG_FILE in $CONFIG_FILES
do
	. $CONFIG_FILE
done

if $CLEAN
then
	_CLEAN_S='yes'
else
	_CLEAN_S='no'
fi

if $RELEASE_BUILD
then
	BUILD_ENV_COMMON="$BUILD_ENV_COMMON REVISION="
	_RELEASE_BUILD_S='yes'
else
	_RELEASE_BUILD_S='no'
fi

_setup

cat <<EOF
=========================================================
SETTINGS SUMMARY
=========================================================
Will build these ARCHS:		$ARCHS
Branch:				$BRANCH
cvsup host:			$CVSUP_HOST
---------------------------------------------------------
Image directory:		$LOCAL_POSTDIR
Build directory:		$TMPDIR
Clean if successful:		$_CLEAN_S
Release build:			$_RELEASE_BUILD_S
---------------------------------------------------------
EOF

# Get the release string (see build/nano_env for more details).
set -- $(sh -c '. build/nano_env && echo "$NANO_LABEL" && echo "$VERSION${REVISION:+-$REVISION}"')
PROJECT_NAME=$1
RELEASE=$2

# Build(s) can fail below (hope not, but it could happen). If they do, let's
# report the problem in an intuitive manner and keep on going..
set +e

for _BUILD_TARGET in $BUILD_TARGETS
do
	for _ARCH in $ARCHS
	do
		_LOG=build-$_ARCH-$_BUILD_TARGET.log

		# Build
		BUILD="sh build/do_build.sh -t $_BUILD_TARGET"
		BUILD_PASS1_ENV="$BUILD_ENV_COMMON FREEBSD_CVSUP_HOST=$CVSUP_HOST PACKAGE_PREP_BUILD=1"
		BUILD_PASS2_ENV="$BUILD_ENV_COMMON"

		echo "[$_ARCH:$_BUILD_TARGET] Build started on: $(env LC_LANG=C date '+%m-%d-%Y %H:%M:%S')"

		# Build twice so the resulting image is smaller than the fat image
		# required for producing ports.
		# XXX: this should really be done in the nanobsd files to only have to
		# do this once, but it requires installing world twice.
		_do sudo sh -c "export FREENAS_ARCH=$_ARCH; env $BUILD_PASS1_ENV $BUILD && env $BUILD_PASS2_ENV $BUILD" > $_LOG 2>&1
		_EC=$?
		echo "[$_ARCH:$_BUILD_TARGET] $(tail -n 1 $_LOG)"
		if [ $_EC -eq 0 ]
		then
			_PASSED_ARCHS="$_PASSED_ARCHS $_ARCH"
		else
			tail -n 10 $_LOG | head -n 9
			CLEAN=false
		fi
		echo "[$_ARCH:$_BUILD_TARGET] Build completed on: $(env LC_LANG=C date '+%m-%d-%Y %H:%M:%S')"
	done
	for _ARCH in $_PASSED_ARCHS
	do
		_post_images $_ARCH $_BUILD_TARGET
		if $RELEASE_BUILD
		then
			if _RELEASE_NOTES_FILE=$(generate_release_notes $_BUILD_TARGET/$_ARCH)
			then
				post_remote_files $_ARCH $_RELEASE_NOTES_FILE
			fi
		fi
	done
done
if $CLEAN
then
	cd /; _cleanup
fi
