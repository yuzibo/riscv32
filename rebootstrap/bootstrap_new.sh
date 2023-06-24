#!/bin/sh

set -v
set -e
set -u

# we have to make the workround to skip time64 issue on rv32
export DEB_CFLAGS_APPEND="${DEB_CFLAGS_APPEND:+$DEB_CFLAGS_APPEND }-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
export DEB_CPPFLAGS_APPEND="${DEB_CPPFLAGS_APPEND:+$DEB_CPPFLAGS_APPEND }-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"

export DEB_BUILD_OPTIONS="nocheck noddebs parallel=16"
export DH_VERBOSE=1
HOST_ARCH=undefined
# select gcc version from gcc-defaults package unless set
GCC_VER=
: ${MIRROR:="http://http.debian.net/debian"}
ENABLE_MULTILIB=no
ENABLE_MULTIARCH_GCC=yes
REPODIR=/tmp/repo
APT_GET="apt-get --no-install-recommends -y -o Debug::pkgProblemResolver=true -o Debug::pkgDepCache::Marker=1 -o Debug::pkgDepCache::AutoInstall=1 -o Acquire::Languages=none"
DEFAULT_PROFILES="cross nocheck noinsttest noudeb"
DROP_PRIVS=buildd
GCC_NOLANG="ada asan brig d gcn go itm java jit hppa64 lsan m2 nvptx objc obj-c++ rust tsan ubsan"
ENABLE_DIFFOSCOPE=no

if df -t tmpfs /var/cache/apt/archives >/dev/null 2>&1; then
	APT_GET="$APT_GET -o APT::Keep-Downloaded-Packages=false"
fi

if test "$(hostname -f)" = ionos9-amd64.debian.net; then
	# jenkin's proxy fails very often
	echo 'APT::Acquire::Retries "10";' > /etc/apt/apt.conf.d/80-retries
fi

# evaluate command line parameters of the form KEY=VALUE
for param in "$@"; do
	echo "bootstrap-configuration: $param"
	eval $param
done

# test whether element $2 is in set $1
set_contains() {
	case " $1 " in
		*" $2 "*) return 0; ;;
		*) return 1; ;;
	esac
}

# add element $2 to set $1
set_add() {
	case " $1 " in
		"  ") echo "$2" ;;
		*" $2 "*) echo "$1" ;;
		*) echo "$1 $2" ;;
	esac
}

# remove element $2 from set $1
set_discard() {
	local word result
	if set_contains "$1" "$2"; then
		result=
		for word in $1; do
			test "$word" = "$2" || result="$result $word"
		done
		echo "${result# }"
	else
		echo "$1"
	fi
}

# create a set from a string of words with duplicates and excess white space
set_create() {
	local word result
	result=
	for word in $1; do
		result=`set_add "$result" "$word"`
	done
	echo "$result"
}

# intersect two sets
set_intersect() {
	local word result
	result=
	for word in $1; do
		if set_contains "$2" "$word"; then
			result=`set_add "$result" "$word"`
		fi
	done
	echo "$result"
}

# compute the set of elements in set $1 but not in set $2
set_difference() {
	local word result
	result=
	for word in $1; do
		if ! set_contains "$2" "$word"; then
			result=`set_add "$result" "$word"`
		fi
	done
	echo "$result"
}

# compute the union of two sets $1 and $2
set_union() {
	local word result
	result=$1
	for word in $2; do
		result=`set_add "$result" "$word"`
	done
	echo "$result"
}

# join the words the arguments starting with $2 with separator $1
join_words() {
	local separator word result
	separator=$1
	shift
	result=
	for word in "$@"; do
		result="${result:+$result$separator}$word"
	done
	echo "$result"
}

check_arch() {
	if elf-arch -a "$2" "$1"; then
		return 0
	else
		case "$2:$(file -b "$1")" in
			"arc:ELF 32-bit LSB relocatable, *unknown arch 0xc3* version 1 (SYSV)"*|"arc:ELF 32-bit LSB relocatable, Synopsys ARCv2/HS3x/HS4x cores, version 1 (SYSV)"*)
				return 0
			;;
			"csky:ELF 32-bit LSB relocatable, *unknown arch 0xfc* version 1 (SYSV)"*|"csky:ELF 32-bit LSB relocatable, C-SKY processor family, version 1 (SYSV)"*)
				return 0
			;;
			"loong64:ELF 64-bit LSB relocatable, LoongArch, version 1 (SYSV)"*)
				return 0
			;;
			"riscv32:ELF 32-bit LSB relocatable, UCB RISC-V, double-float ABI, version 1 (SYSV)"*|"riscv32:ELF 32-bit LSB relocatable, UCB RISC-V, RVC, double-float ABI, version 1 (SYSV)"*)
				# https://github.com/kilobyte/arch-test/pull/11
				return 0
			;;
		esac
		echo "expected $2, but found $(file -b "$1")"
		return 1
	fi
}

filter_dpkg_tracked() {
	local pkg pkgs
	pkgs=""
	for pkg in "$@"; do
		dpkg-query -s "$pkg" >/dev/null 2>&1 && pkgs=`set_add "$pkgs" "$pkg"`
	done
	echo "$pkgs"
}

apt_get_install() {
	DEBIAN_FRONTEND=noninteractive $APT_GET install "$@"
}

apt_get_build_dep() {
	DEBIAN_FRONTEND=noninteractive $APT_GET build-dep "$@"
}

apt_get_remove() {
	local pkgs
	pkgs=$(filter_dpkg_tracked "$@")
	if test -n "$pkgs"; then
		$APT_GET remove $pkgs
	fi
}

apt_get_purge() {
	local pkgs
	pkgs=$(filter_dpkg_tracked "$@")
	if test -n "$pkgs"; then
		$APT_GET purge $pkgs
	fi
}

$APT_GET update
$APT_GET dist-upgrade # we need upgrade later, so make sure the system is clean
apt_get_install build-essential debhelper reprepro quilt arch-test

if test -z "$DROP_PRIVS"; then
	drop_privs_exec() {
		exec env -- "$@"
	}
else
	apt_get_install adduser fakeroot
	if ! getent passwd "$DROP_PRIVS" >/dev/null; then
		adduser --system --group --home /tmp/buildd --no-create-home --shell /bin/false "$DROP_PRIVS"
	fi
	drop_privs_exec() {
		exec /sbin/runuser --user "$DROP_PRIVS" --group "$DROP_PRIVS" -- /usr/bin/env -- "$@"
	}
fi
drop_privs() {
	( drop_privs_exec "$@" )
}

if test -z "$GCC_VER"; then
	GCC_VER=`apt-cache depends gcc | sed 's/^ *Depends: gcc-\([0-9.]*\)$/\1/;t;d'`
fi

if test "$ENABLE_MULTIARCH_GCC" = yes; then
	apt_get_install cross-gcc-dev
	echo "removing unused unstripped_exe patch"
	sed -i '/made-unstripped_exe-setting-overridable/d' /usr/share/cross-gcc/patches/gcc-*/series
fi

obtain_source_package() {
	local use_experimental
	use_experimental=
	case "$1" in
		gcc-[0-9]*)
			test -n "$(apt-cache showsrc "$1")" || use_experimental=yes
		;;
	esac
	if test "$use_experimental" = yes; then
		echo "deb-src $MIRROR experimental main" > /etc/apt/sources.list.d/tmp-experimental.list
		$APT_GET update
	fi
	drop_privs apt-get source "$1"
	if test -f /etc/apt/sources.list.d/tmp-experimental.list; then
		rm /etc/apt/sources.list.d/tmp-experimental.list
		$APT_GET update
	fi
}

cat <<EOF >> /usr/share/dpkg/cputable
csky		csky		csky		32	little
riscv32		riscv32		riscv32		32	little
EOF

if test -z "$HOST_ARCH" || ! dpkg-architecture "-a$HOST_ARCH"; then
	echo "architecture $HOST_ARCH unknown to dpkg"
	exit 1
fi

# ensure that the rebootstrap list comes first
test -f /etc/apt/sources.list && mv -v /etc/apt/sources.list /etc/apt/sources.list.d/local.list
grep -q '^deb-src .*sid' /etc/apt/sources.list.d/*.list || echo "deb-src $MIRROR sid main" >> /etc/apt/sources.list.d/sid-source.list

dpkg --add-architecture $HOST_ARCH
$APT_GET update

rm -Rf /tmp/buildd
drop_privs mkdir -p /tmp/buildd

HOST_ARCH_SUFFIX="-`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE | tr _ -`"

case "$HOST_ARCH" in
	amd64) MULTILIB_NAMES="i386 x32" ;;
	i386) MULTILIB_NAMES="amd64 x32" ;;
	mips|mipsel) MULTILIB_NAMES="mips64 mipsn32" ;;
	mips64|mips64el) MULTILIB_NAMES="mips32 mipsn32" ;;
	mipsn32|mipsn32el) MULTILIB_NAMES="mips32 mips64" ;;
	powerpc) MULTILIB_NAMES=ppc64 ;;
	ppc64) MULTILIB_NAMES=powerpc ;;
	s390x) MULTILIB_NAMES=s390 ;;
	sparc) MULTILIB_NAMES=sparc64 ;;
	sparc64) MULTILIB_NAMES=sparc ;;
	x32) MULTILIB_NAMES="amd64 i386" ;;
	*) MULTILIB_NAMES="" ;;
esac
if test "$ENABLE_MULTILIB" != yes; then
	MULTILIB_NAMES=""
fi

for f in /etc/apt/sources.list.d/*.list; do
	test -f "$f" && sed -i "s/^deb \(\[.*\] \)*/deb [ arch-=$HOST_ARCH ] /" "$f"
done
mkdir -p "$REPODIR/conf" "$REPODIR/archive" "$REPODIR/stamps"
cat > "$REPODIR/conf/distributions" <<EOF
Codename: rebootstrap
Label: rebootstrap
Architectures: `dpkg --print-architecture` $HOST_ARCH
Components: main
UDebComponents: main
Description: cross toolchain and build results for $HOST_ARCH

Codename: rebootstrap-native
Label: rebootstrap-native
Architectures: `dpkg --print-architecture`
Components: main
UDebComponents: main
Description: native packages needed for bootstrap
EOF
cat > "$REPODIR/conf/options" <<EOF
verbose
ignore wrongdistribution
EOF
export REPREPRO_BASE_DIR="$REPODIR"
reprepro export
echo "deb [ arch=$(dpkg --print-architecture),$HOST_ARCH trusted=yes ] file://$REPODIR rebootstrap main" >/etc/apt/sources.list.d/000_rebootstrap.list
echo "deb [ arch=$(dpkg --print-architecture) trusted=yes ] file://$REPODIR rebootstrap-native main" >/etc/apt/sources.list.d/001_rebootstrap-native.list
cat >/etc/apt/preferences.d/rebootstrap.pref <<EOF
Explanation: prefer our own rebootstrap (native) packages over everything
Package: *
Pin: release l=rebootstrap-native
Pin-Priority: 1001

Explanation: prefer our own rebootstrap (toolchain) packages over everything
Package: *
Pin: release l=rebootstrap
Pin-Priority: 1002

Explanation: do not use archive cross toolchain
Package: *-$HOST_ARCH-cross *$HOST_ARCH_SUFFIX gcc-*$HOST_ARCH_SUFFIX-base
Pin: release a=unstable
Pin-Priority: -1
EOF
$APT_GET update

# Since most libraries (e.g. libgcc_s) do not include ABI-tags,
# glibc may be confused and try to use them. A typical symptom is:
# apt-get: error while loading shared libraries: /lib/x86_64-kfreebsd-gnu/libgcc_s.so.1: ELF file OS ABI invalid
cat >/etc/dpkg/dpkg.cfg.d/ignore-foreign-linker-paths <<EOF
path-exclude=/etc/ld.so.conf.d/$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_MULTIARCH).conf
EOF

# Work around Multi-Arch: same file conflict in libxdmcp-dev. #825146
cat >/etc/dpkg/dpkg.cfg.d/bug-825146 <<'EOF'
path-exclude=/usr/share/doc/libxdmcp-dev/xdmcp.txt.gz
EOF

# Work around binNMU file conflicts of e.g. binutils or gcc.
cat >/etc/dpkg/dpkg.cfg.d/binNMU-changelogs <<EOF
path-exclude=/usr/share/doc/*/changelog.Debian.$(dpkg-architecture -qDEB_BUILD_ARCH).gz
EOF

# debhelper/13.10 started trimming changelogs, this breaks all over the place
cat >/etc/dpkg/dpkg.cfg.d/trimmed-changelogs <<'EOF'
path-exclude=/usr/share/doc/*/changelog.Debian.gz
path-exclude=/usr/share/doc/*/changelog.gz
EOF

if test "$HOST_ARCH" = nios2; then
	echo "fixing libtool's nios2 misdetection as os2 #851253"
	apt_get_install libtool
	sed -i -e 's/\*os2\*/*-os2*/' /usr/share/libtool/build-aux/ltmain.sh
fi

# removing libc*-dev conflict with each other
LIBC_DEV_PKG=$(apt-cache showpkg libc-dev | sed '1,/^Reverse Provides:/d;s/ .*//;q')
if test "$(apt-cache show "$LIBC_DEV_PKG" | sed -n 's/^Source: //;T;p;q')" = glibc; then
if test -f "$REPODIR/pool/main/g/glibc/$LIBC_DEV_PKG"_*_"$(dpkg --print-architecture).deb"; then
	dpkg -i "$REPODIR/pool/main/g/glibc/$LIBC_DEV_PKG"_*_"$(dpkg --print-architecture).deb"
else
	cd /tmp/buildd
	apt-get download "$LIBC_DEV_PKG"
	dpkg-deb -R "./$LIBC_DEV_PKG"_*.deb x
	sed -i -e '/^Conflicts: /d' x/DEBIAN/control
	mv -nv -t x/usr/include "x/usr/include/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/"*
	mv -nv x/usr/include x/usr/include.orig
	mkdir x/usr/include
	mv -nv x/usr/include.orig "x/usr/include/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
	dpkg-deb -b x "./$LIBC_DEV_PKG"_*.deb
	reprepro includedeb rebootstrap-native "./$LIBC_DEV_PKG"_*.deb
	dpkg -i "./$LIBC_DEV_PKG"_*.deb
	$APT_GET update
	rm -R "./$LIBC_DEV_PKG"_*.deb x
fi # already repacked
fi # is glibc

chdist_native() {
	local command
	command="$1"
	shift
	chdist --data-dir /tmp/chdist_native --arch "$HOST_ARCH" "$command" native "$@"
}

if test "$ENABLE_DIFFOSCOPE" = yes; then
	apt_get_install devscripts
	chdist_native create "$MIRROR" sid main
	if ! chdist_native apt-get update; then
		echo "rebootstrap-warning: not comparing packages to native builds"
		rm -Rf /tmp/chdist_native
		ENABLE_DIFFOSCOPE=no
	fi
fi
if test "$ENABLE_DIFFOSCOPE" = yes; then
	compare_native() {
		local pkg pkgname tmpdir downloadname errcode
		apt_get_install diffoscope binutils-multiarch vim-common
		for pkg in "$@"; do
			if test "`dpkg-deb -f "$pkg" Architecture`" != "$HOST_ARCH"; then
				echo "not comparing $pkg: wrong architecture"
				continue
			fi
			pkgname=`dpkg-deb -f "$pkg" Package`
			tmpdir=`mktemp -d`
			mkdir "$tmpdir/a" "$tmpdir/b"
			cp "$pkg" "$tmpdir/a" # work around diffoscope recursing over the build tree
			if ! (cd "$tmpdir/b" && chdist_native apt-get download "$pkgname"); then
				echo "not comparing $pkg: download failed"
				rm -R "$tmpdir"
				continue
			fi
			downloadname=`dpkg-deb -W --showformat '${Package}_${Version}_${Architecture}.deb' "$pkg" | sed 's/:/%3a/'`
			if ! test -f "$tmpdir/b/$downloadname"; then
				echo "not comparing $pkg: downloaded different version"
				rm -R "$tmpdir"
				continue
			fi
			errcode=0
			timeout --kill-after=1m 1h diffoscope --text "$tmpdir/out" "$tmpdir/a/$(basename -- "$pkg")" "$tmpdir/b/$downloadname" || errcode=$?
			case $errcode in
				0)
					echo "diffoscope-success: $pkg"
				;;
				1)
					if ! test -f "$tmpdir/out"; then
						echo "rebootstrap-error: no diffoscope output for $pkg"
						exit 1
					elif test "`wc -l < "$tmpdir/out"`" -gt 1000; then
						echo "truncated diffoscope output for $pkg:"
						head -n1000 "$tmpdir/out"
					else
						echo "diffoscope output for $pkg:"
						cat "$tmpdir/out"
					fi
				;;
				124)
					echo "rebootstrap-warning: diffoscope timed out"
				;;
				*)
					echo "rebootstrap-error: diffoscope terminated with abnormal exit code $errcode"
					exit 1
				;;
			esac
			rm -R "$tmpdir"
		done
	}
else
	compare_native() { :
	}
fi

pickup_additional_packages() {
	local f
	for f in "$@"; do
		if test "${f%.deb}" != "$f"; then
			reprepro includedeb rebootstrap "$f"
		elif test "${f%.changes}" != "$f"; then
			reprepro include rebootstrap "$f"
		else
			echo "cannot pick up package $f"
			exit 1
		fi
	done
	$APT_GET update
}

pickup_packages() {
	local sources
	local source
	local f
	local i
	# collect source package names referenced
	sources=""
	for f in "$@"; do
		if test "${f%.deb}" != "$f"; then
			source=`dpkg-deb -f "$f" Source`
			test -z "$source" && source=${f%%_*}
		elif test "${f%.changes}" != "$f"; then
			source=${f%%_*}
		else
			echo "cannot pick up package $f"
			exit 1
		fi
		sources=`set_add "$sources" "$source"`
	done
	# archive old contents and remove them from the repository
	for source in $sources; do
		i=1
		while test -e "$REPODIR/archive/${source}_$i"; do
			i=`expr $i + 1`
		done
		i="$REPODIR/archive/${source}_$i"
		mkdir "$i"
		for f in $(reprepro --list-format '${Filename}\n' listfilter rebootstrap "\$Source (== $source)"); do
			cp -v "$REPODIR/$f" "$i"
		done
		find "$i" -type d -empty -delete
		reprepro removesrc rebootstrap "$source"
	done
	# add new contents
	pickup_additional_packages "$@"
}

# compute a function name from a hook prefix $1 and a package name $2
# returns success if the function actually exists
get_hook() {
	local hook
	hook=`echo "$2" | tr -- -. __` # - and . are invalid in function names
	hook="${1}_$hook"
	echo "$hook"
	type "$hook" >/dev/null 2>&1 || return 1
}

cross_build_setup() {
	local pkg subdir hook
	pkg="$1"
	subdir="${2:-$pkg}"
	cd /tmp/buildd
	drop_privs mkdir "$subdir"
	cd "$subdir"
	obtain_source_package "$pkg"
	cd "${pkg}-"*
	hook=`get_hook patch "$pkg"` && "$hook"
	return 0
}

# add a binNMU changelog entry
# . is a debian package
# $1 is the binNMU number
# $2 is reason
add_binNMU_changelog() {
	cat - debian/changelog <<EOF |
$(dpkg-parsechangelog -SSource) ($(dpkg-parsechangelog -SVersion)+b$1) sid; urgency=medium, binary-only=yes

  * Binary-only non-maintainer upload for $HOST_ARCH; no source changes.
  * $2

 -- rebootstrap <invalid@invalid>  $(dpkg-parsechangelog -SDate)

EOF
		drop_privs tee debian/changelog.new >/dev/null
	drop_privs mv debian/changelog.new debian/changelog
}

check_binNMU() {
	local pkg srcversion binversion maxversion
	srcversion=`dpkg-parsechangelog -SVersion`
	maxversion=$srcversion
	for pkg in `dh_listpackages`; do
		binversion=`apt-cache show "$pkg=$srcversion*" 2>/dev/null | sed -n 's/^Version: //p;T;q'`
		test -z "$binversion" && continue
		if dpkg --compare-versions "$maxversion" lt "$binversion"; then
			maxversion=$binversion
		fi
	done
	case "$maxversion" in
		"$srcversion+b"*)
			echo "rebootstrap-warning: binNMU detected for $(dpkg-parsechangelog -SSource) $srcversion/$maxversion"
			add_binNMU_changelog "${maxversion#$srcversion+b}" "Bump to binNMU version of $(dpkg --print-architecture)."
		;;
	esac
}

PROGRESS_MARK=1
progress_mark() {
	echo "progress-mark:$PROGRESS_MARK:$*"
	PROGRESS_MARK=$(($PROGRESS_MARK + 1 ))
}

# prints the set (as in set_create) of installed packages
record_installed_packages() {
	dpkg --get-selections | sed 's/\s\+install$//;t;d' | xargs
}

# Takes the set (as in set_create) of packages and apt-get removes any
# currently installed packages outside the given set.
remove_extra_packages() {
	local origpackages currentpackages removedpackages extrapackages
	origpackages="$1"
	currentpackages=$(record_installed_packages)
	removedpackages=$(set_difference "$origpackages" "$currentpackages")
	extrapackages=$(set_difference "$currentpackages" "$origpackages")
	echo "original packages: $origpackages"
	echo "removed packages:  $removedpackages"
	echo "extra packages:    $extrapackages"
	apt_get_remove $extrapackages
}

buildpackage_failed() {
	local err last_config_log
	err="$1"
	echo "rebootstrap-error: dpkg-buildpackage failed with status $err"
	last_config_log=$(find . -type f -name config.log -printf "%T@ %p\n" | sort -g | tail -n1 | cut "-d " -f2-)
	if test -f "$last_config_log"; then
		tail -v -n+0 "$last_config_log"
	fi
	exit "$err"
}

cross_build() {
	local pkg profiles stamp ignorebd hook installedpackages
	pkg="$1"
	profiles="$DEFAULT_PROFILES ${2:-}"
	stamp="${3:-$pkg}"
	if test "$ENABLE_MULTILIB" = "no"; then
		profiles="$profiles nobiarch"
	fi
	profiles=$(join_words , $profiles)
	if test -f "$REPODIR/stamps/$stamp"; then
		echo "skipping rebuild of $pkg with profiles $profiles"
	else
		echo "building $pkg with profiles $profiles"
		cross_build_setup "$pkg" "$stamp"
		installedpackages=$(record_installed_packages)
		if hook=`get_hook builddep "$pkg"`; then
			echo "installing Build-Depends for $pkg using custom function"
			"$hook" "$HOST_ARCH" "$profiles"
		else
			echo "installing Build-Depends for $pkg using apt-get build-dep"
			apt_get_build_dep "-a$HOST_ARCH" --arch-only -P "$profiles" ./
		fi
		check_binNMU
		ignorebd=
		if get_hook builddep "$pkg" >/dev/null; then
			if dpkg-checkbuilddeps -B "-a$HOST_ARCH" -P "$profiles"; then
				echo "rebootstrap-warning: Build-Depends for $pkg satisfied even though a custom builddep_  function is in use"
			fi
			ignorebd=-d
		fi
		(
			if hook=`get_hook buildenv "$pkg"`; then
				echo "adding environment variables via buildenv hook for $pkg"
				"$hook" "$HOST_ARCH"
			fi
			drop_privs_exec dpkg-buildpackage "-a$HOST_ARCH" -B "-P$profiles" $ignorebd -uc -us
		) || buildpackage_failed "$?"
		cd ..
		remove_extra_packages "$installedpackages"
		ls -l
		pickup_packages *.changes
		touch "$REPODIR/stamps/$stamp"
		compare_native ./*.deb
		cd ..
		drop_privs rm -Rf "$stamp"
	fi
	progress_mark "$stamp cross build"
}

if test "$ENABLE_MULTIARCH_GCC" != yes; then
	apt_get_install dpkg-cross
fi

automatic_packages=
add_automatic() { automatic_packages=$(set_add "$automatic_packages" "$1"); }

add_automatic acl
add_automatic apt
add_automatic attr
add_automatic base-files
add_automatic base-passwd

add_automatic bash
patch_bash() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-linux-any || return 0
	echo "fixing logic error around wrapping strtoimax #1023053"
	drop_privs patch -p1 <<'EOF'
--- a/configure
+++ b/configure
@@ -20443,7 +20443,7 @@

 { printf "%s\n" "$as_me:${as_lineno-$LINENO}: result: $bash_cv_func_strtoimax" >&5
 printf "%s\n" "$bash_cv_func_strtoimax" >&6; }
-if test $bash_cv_func_strtoimax = yes; then
+if test $bash_cv_func_strtoimax = no; then
 case " $LIBOBJS " in
   *" strtoimax.$ac_objext "* ) ;;
   *) LIBOBJS="$LIBOBJS strtoimax.$ac_objext"
EOF
}

patch_binutils() {
	echo "patching binutils to discard ldscripts"
	# They cause file conflicts with binutils and the in-archive cross
	# binutils discard ldscripts as well.
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -751,6 +751,7 @@
 		mandir=$(pwd)/$(D_CROSS)/$(PF)/share/man install
 
 	rm -rf \
+		$(D_CROSS)/$(PF)/lib/ldscripts \
 		$(D_CROSS)/$(PF)/share/info \
 		$(D_CROSS)/$(PF)/share/locale
 
EOF
	if test "$HOST_ARCH" = hppa; then
		echo "patching binutils to discard hppa64 ldscripts"
		# They cause file conflicts with binutils and the in-archive
		# cross binutils discard ldscripts as well.
		drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -1233,6 +1233,7 @@
 		$(d_hppa64)/$(PF)/lib/$(DEB_HOST_MULTIARCH)/.

 	: # Now get rid of just about everything in binutils-hppa64
+	rm -rf $(d_hppa64)/$(PF)/lib/ldscripts
 	rm -rf $(d_hppa64)/$(PF)/man
 	rm -rf $(d_hppa64)/$(PF)/info
 	rm -rf $(d_hppa64)/$(PF)/include
EOF
	fi
	echo "fix honouring of nocheck option #990794"
	drop_privs sed -i -e 's/ifeq (\(,$(filter $(DEB_HOST_ARCH),\)/ifneq ($(DEB_BUILD_ARCH)\1/' debian/rules
	case "$HOST_ARCH" in nios2|sparc|riscv32)
		echo "enabling uncommon architectures in debian/control"
		drop_privs sed -i -e "/^#NATIVE_ARCHS +=/aNATIVE_ARCHS += $HOST_ARCH" debian/rules
		drop_privs ./debian/rules ./stamps/control
		drop_privs rm -f ./stamps/control
	;; esac
	echo "fix undefined symbol ldlex_defsym #992318"
	rm -f ld/ldlex.c
}

add_automatic blt
add_automatic bsdmainutils

builddep_build_essential() {
	# g++ dependency needs cross translation
	apt_get_install debhelper python3
}

add_automatic bzip2
add_automatic c-ares
add_automatic coreutils
add_automatic curl
add_automatic dash
add_automatic db-defaults
add_automatic debianutils

add_automatic diffutils
buildenv_diffutils() {
	if dpkg-architecture "-a$1" -ignu-any-any; then
		export gl_cv_func_getopt_gnu=yes
	fi
}

add_automatic dpkg
patch_dpkg() {
	if test "$HOST_ARCH" = riscv32; then
        	echo "patching dpkg to support riscv32"
               	drop_privs patch -p1  <<'EOF'
--- a/data/cputable
+++ b/data/cputable
@@ -45,6 +45,7 @@
 powerpcel	powerpcle	powerpcle		32	little
 ppc64		powerpc64	(powerpc|ppc)64		64	big
 ppc64el		powerpc64le	powerpc64le		64	little
+riscv32		riscv32		riscv32			32	little
 riscv64		riscv64		riscv64			64	little
 s390		s390		s390			32	big
 s390x		s390x		s390x			64	big
EOF
        	echo "patching dpkg to support riscv32"
               	drop_privs patch -p1  <<'EOF'
--- a/scripts/Dpkg/Vendor/Debian.pm
+++ b/scripts/Dpkg/Vendor/Debian.pm
@@ -238,6 +238,7 @@
         powerpc
         ppc64
         ppc64el
+        riscv32
         riscv64
         s390x
         sparc
EOF
        	echo "patching dpkg to support riscv32"
               	drop_privs patch -p1  <<'EOF'
--- a/scripts/Dpkg/Shlibs/Objdump.pm
+++ b/scripts/Dpkg/Shlibs/Objdump.pm
@@ -104,6 +104,7 @@
     EM_XTENSA               => 94,
     EM_MICROBLAZE           => 189,
     EM_ARCV2                => 195,
+    EM_RISCV                => 243,
     EM_LOONGARCH            => 258,
     EM_AVR_OLD              => 0x1057,
     EM_OR1K_OLD             => 0x8472,
@@ -128,6 +129,12 @@
     EF_ARM_EABI_MASK        => 0xff000000,
 
     EF_IA64_ABI64           => 0x00000010,
+    EF_RISCV_FLOAT_ABI_SOFT     => 0x0000,
+    EF_RISCV_FLOAT_ABI_SINGLE   => 0x0002,
+    EF_RISCV_FLOAT_ABI_DOUBLE   => 0x0004,
+    EF_RISCV_FLOAT_ABI_QUAD     => 0x0006,
+    EF_RISCV_FLOAT_ABI_MASK     => 0x0006,
+    EF_RISCV_RVE                => 0x0008,
 
     EF_LOONGARCH_SOFT_FLOAT     => 0x00000001,
     EF_LOONGARCH_SINGLE_FLOAT   => 0x00000002,
@@ -170,6 +177,7 @@
     EM_LOONGARCH()          => EF_LOONGARCH_ABI_MASK,
     EM_MIPS()               => EF_MIPS_ABI_MASK | EF_MIPS_ABI2,
     EM_PPC64()              => EF_PPC64_ABI64,
+    EM_RISCV()              => EF_RISCV_FLOAT_ABI_MASK | EF_RISCV_RVE,
 );
 
 sub get_format {
EOF
	fi
}

add_automatic e2fsprogs
add_automatic expat
add_automatic file
add_automatic findutils
add_automatic flex
add_automatic fontconfig
add_automatic freetype
add_automatic fribidi
add_automatic fuse

patch_gcc_default_pie_everywhere()
{
	echo "enabling pie everywhere #892281"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.defs
+++ a/debian/rules.defs
@@ -1250,9 +1250,7 @@
     pie_archs += armhf arm64 i386
   endif
 endif
-ifneq (,$(filter $(DEB_TARGET_ARCH),$(pie_archs)))
-  with_pie := yes
-endif
+with_pie := yes
 ifeq ($(trunk_build),yes)
   with_pie := disabled for trunk builds
 endif
EOF
}
patch_gcc_limits_h_test() {
	echo "fix LIMITS_H_TEST again https://gcc.gnu.org/bugzilla/show_bug.cgi?id=80677"
	drop_privs tee debian/patches/limits-h-test.diff >/dev/null <<'EOF'
--- a/src/gcc/limitx.h
+++ b/src/gcc/limitx.h
@@ -29,7 +29,7 @@
 #ifndef _GCC_LIMITS_H_  /* Terminated in limity.h.  */
 #define _GCC_LIMITS_H_

-#ifndef _LIBC_LIMITS_H_
+#if !defined(_LIBC_LIMITS_H_) && __has_include_next(<limits.h>)
 /* Use "..." so that we find syslimits.h only in this same directory.  */
 #include "syslimits.h"
 #endif
--- a/src/gcc/limity.h
+++ b/src/gcc/limity.h
@@ -3,7 +3,7 @@

 #else /* not _GCC_LIMITS_H_ */

-#ifdef _GCC_NEXT_LIMITS_H
+#if defined(_GCC_NEXT_LIMITS_H) && __has_include_next(<limits.h>)
 #include_next <limits.h>		/* recurse down to the real one */
 #endif

--- a/src/gcc/Makefile.in
+++ b/src/gcc/Makefile.in
@@ -3139,11 +3139,7 @@
 	  sysroot_headers_suffix=`echo $${ml} | sed -e 's/;.*$$//'`; \
 	  multi_dir=`echo $${ml} | sed -e 's/^[^;]*;//'`; \
 	  include_dir=include$${multi_dir}; \
-	  if $(LIMITS_H_TEST) ; then \
-	    cat $(srcdir)/limitx.h $(T_GLIMITS_H) $(srcdir)/limity.h > tmp-xlimits.h; \
-	  else \
-	    cat $(T_GLIMITS_H) > tmp-xlimits.h; \
-	  fi; \
+	  cat $(srcdir)/limitx.h $(T_GLIMITS_H) $(srcdir)/limity.h > tmp-xlimits.h; \
 	  $(mkinstalldirs) $${include_dir}; \
 	  chmod a+rx $${include_dir} || true; \
 	  $(SHELL) $(srcdir)/../move-if-change \
EOF
	if test "$GCC_VER" -le 12; then
		drop_privs sed -i -e 's/include_dir=include/fix_dir=include-fixed/' -e 's/{include_dir}/{fix_dir}/' debian/patches/limits-h-test.diff
	fi
	echo "debian_patches += limits-h-test" | drop_privs tee -a debian/rules.patch >/dev/null
}
patch_gcc_unapplicable_ada() {
	echo "fix patch application failure #993205"
	drop_privs sed -i -e /ada-armel-libatomic/d debian/rules.patch
}
patch_gcc_crypt_h() {
	echo "fix libsanitizer failing to find crypt.h #1014375"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules2
+++ b/debian/rules2
@@ -1251,6 +1251,13 @@
 	  mkdir -p $(builddir)/sys-include; \
 	  ln -sf /usr/include/$(DEB_TARGET_MULTIARCH)/asm $(builddir)/sys-include/asm; \
 	fi
+	: # Fall back to the host crypt.h when target is unavailable as the sizeof(struct crypt_data) is unlikely to change, needed by libsanitizer.
+	if [ ! -f /usr/include/crypt.h ] && \
+		[ ! -f /usr/include/$(DEB_TARGET_MULTIARCH)/crypt.h ] && \
+		[ -f /usr/include/$(DEB_HOST_MULTIARCH)/crypt.h ]; then \
+	  mkdir -p $(builddir)/sys-include; \
+	  ln -sf /usr/include/$(DEB_HOST_MULTIARCH)/crypt.h $(builddir)/sys-include/crypt.h; \
+	fi

 	touch $(configure_stamp)

EOF
}
patch_gcc_has_include_next() {
	dpkg-architecture "-a$HOST_ARCH" -ihurd-any || return 0
	echo "fix __has_include_next https://gcc.gnu.org/bugzilla/show_bug.cgi?id=80755"
	drop_privs tee debian/patches/has_include_next.diff >/dev/null <<EOF
--- a/src/libcpp/files.cc
+++ b/src/libcpp/files.cc
@@ -1042,7 +1042,7 @@
      path use the normal search logic.  */
   if (type == IT_INCLUDE_NEXT && file->dir
       && file->dir != &pfile->no_search_path)
-    dir = file->dir->next;
+    return file->dir->next;
   else if (angle_brackets)
     dir = pfile->bracket_include;
   else if (type == IT_CMDLINE)
@@ -2145,6 +2145,8 @@
 		 enum include_type type)
 {
   cpp_dir *start_dir = search_path_head (pfile, fname, angle_brackets, type);
+  if (!start_dir)
+    return false;
   _cpp_file *file = _cpp_find_file (pfile, fname, start_dir, angle_brackets,
 				    _cpp_FFK_HAS_INCLUDE, 0);
   return file->err_no != ENOENT;
EOF
	echo "debian_patches += has_include_next" | drop_privs tee -a debian/rules.patch >/dev/null
}
patch_gcc_loong64() {
	test "$HOST_ARCH" = loong64 || return 0
	echo "revert loong64 tuple #1031850"
	drop_privs tee debian/patches/loong64_tuple.diff >/dev/null <<'EOF'
--- a/src/gcc/config/loongarch/t-linux
+++ b/src/gcc/config/loongarch/t-linux
@@ -32,14 +32,14 @@ ifneq ($(call if_multiarch,yes),yes)
 else
     # Only define MULTIARCH_DIRNAME when multiarch is enabled,
     # or it would always introduce ${target} into the search path.
-    MULTIARCH_DIRNAME = $(call if_multiarch,loongarch64-linux-gnuf64)
+    MULTIARCH_DIRNAME = $(LA_MULTIARCH_TRIPLET)
 endif

 # Don't define MULTILIB_OSDIRNAMES if multilib is disabled.
 ifeq ($(filter LA_DISABLE_MULTILIB,$(tm_defines)),)

     MULTILIB_OSDIRNAMES = \
-      mabi.lp64d=../lib$(call if_multiarch,:loongarch64-linux-gnuf64)
+      mabi.lp64d=../lib$(call if_multiarch,:loongarch64-linux-gnu)

     MULTILIB_OSDIRNAMES += \
       mabi.lp64f=../lib/f32$(call if_multiarch,:loongarch64-linux-gnuf32)
EOF
	echo "debian_patches += loong64_tuple" | drop_privs tee -a debian/rules.patch >/dev/null
}
patch_gcc_wdotap() {
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		echo "applying patches for with_deps_on_target_arch_pkgs"
		drop_privs rm -Rf .pc
		drop_privs QUILT_PATCHES="/usr/share/cross-gcc/patches/gcc-$GCC_VER" quilt push -a
		drop_privs rm -Rf .pc
	fi
}

patch_gcc_riscv32() {
        test "$HOST_ARCH" = riscv32 || return 0
        echo "riscv32 no multilib"
        drop_privs patch -p1 <<'EOF'
--- a/debian/rules2
+++ b/debian/rules2
@@ -564,6 +564,11 @@ ifneq (,$(findstring riscv64-linux,$(DEB_TARGET_GNU_TYPE)))
   CONFARGS += --with-arch=rv64gc --with-abi=lp64d
 endif

+ifneq (,$(findstring riscv32-linux,$(DEB_TARGET_GNU_TYPE)))
+  CONFARGS += --disable-multilib
+  CONFARGS += --with-arch=rv32gc --with-abi=ilp32d
+endif
+
 ifneq (,$(findstring s390x-linux,$(DEB_TARGET_GNU_TYPE)))
   ifeq ($(derivative),Ubuntu)
     ifneq (,$(filter $(distrelease),xenial bionic focal))
EOF
}
patch_gcc_12() {
	patch_gcc_limits_h_test
	patch_gcc_default_pie_everywhere
	patch_gcc_unapplicable_ada
	patch_gcc_crypt_h
	patch_gcc_has_include_next
	patch_gcc_loong64
	patch_gcc_wdotap
	patch_gcc_riscv32
}
patch_gcc_13() {
	patch_gcc_limits_h_test
	patch_gcc_wdotap
}

buildenv_gdbm() {
	if dpkg-architecture "-a$1" -ignu-any-any; then
		export ac_cv_func_mmap_fixed_mapped=yes
	fi
}

add_automatic glib2.0
patch_glib2_0() {
	dpkg-architecture "-a$HOST_ARCH" -ix32-any-any-any || return 0
	# https://github.com/mesonbuild/meson/issues/9845
	echo "working around wrong cc_can_run on x32"
	drop_privs tee -a debian/meson/libc-properties.ini >/dev/null <<EOF
needs_exe_wrapper=true
EOF
}

builddep_glibc() {
	test "$1" = "$HOST_ARCH"
	apt_get_install gettext file quilt autoconf gawk debhelper rdfind symlinks binutils bison netbase "gcc-$GCC_VER$HOST_ARCH_SUFFIX"
	case "$(dpkg-architecture "-a$1" -qDEB_HOST_ARCH_OS)" in
		linux)
			if test "$ENABLE_MULTIARCH_GCC" = yes; then
				apt_get_install "linux-libc-dev:$HOST_ARCH"
			else
				apt_get_install "linux-libc-dev-$HOST_ARCH-cross"
			fi
		;;
		hurd)
			apt_get_install "gnumach-dev:$1" "hurd-headers-dev:$1" "mig$HOST_ARCH_SUFFIX"
		;;
		*)
			echo "rebootstrap-error: unsupported kernel"
			exit 1
		;;
	esac
}
patch_glibc() {
	echo "patching glibc to pass -l to dh_shlibdeps for multilib"
	drop_privs patch -p1 <<'EOF'
diff -Nru glibc-2.19/debian/rules.d/debhelper.mk glibc-2.19/debian/rules.d/debhelper.mk
--- glibc-2.19/debian/rules.d/debhelper.mk
+++ glibc-2.19/debian/rules.d/debhelper.mk
@@ -109,7 +109,7 @@
 	./debian/shlibs-add-udebs $(curpass)
 
 	dh_installdeb -p$(curpass)
-	dh_shlibdeps -p$(curpass)
+	dh_shlibdeps $(if $($(lastword $(subst -, ,$(curpass)))_slibdir),-l$(CURDIR)/debian/$(curpass)/$($(lastword $(subst -, ,$(curpass)))_slibdir)) -p$(curpass)
 	dh_gencontrol -p$(curpass)
 	if [ $(curpass) = nscd ] ; then \
 		sed -i -e "s/\(Depends:.*libc[0-9.]\+\)-[a-z0-9]\+/\1/" debian/nscd/DEBIAN/control ; \
EOF
	echo "patching glibc to find standard linux headers"
	drop_privs patch -p1 <<'EOF'
diff -Nru glibc-2.19/debian/sysdeps/linux.mk glibc-2.19/debian/sysdeps/linux.mk
--- glibc-2.19/debian/sysdeps/linux.mk
+++ glibc-2.19/debian/sysdeps/linux.mk
@@ -16,7 +16,7 @@
 endif

 ifndef LINUX_SOURCE
-  ifeq ($(DEB_HOST_GNU_TYPE),$(DEB_BUILD_GNU_TYPE))
+  ifeq ($(shell dpkg-query --status linux-libc-dev-$(DEB_HOST_ARCH)-cross 2>/dev/null),)
     LINUX_HEADERS := /usr/include
   else
     LINUX_HEADERS := /usr/$(DEB_HOST_GNU_TYPE)/include
EOF
	if ! sed -n '/^libc6_archs *:=/,/[^\\]$/p' debian/rules.d/control.mk | grep -qw "$HOST_ARCH"; then
		echo "adding $HOST_ARCH to libc6_archs"
		drop_privs sed -i -e "s/^libc6_archs *:= /&$HOST_ARCH /" debian/rules.d/control.mk
		drop_privs ./debian/rules debian/control
	fi
	echo "patching glibc to drop dev package conflict"
	sed -i -e '/^Conflicts: @libc-dev-conflict@$/d' debian/control.in/libc
	echo "patching glibc to move all headers to multiarch locations #798955"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.d/build.mk
+++ b/debian/rules.d/build.mk
@@ -4,12 +4,16 @@
 xx=$(if $($(curpass)_$(1)),$($(curpass)_$(1)),$($(1)))
 define generic_multilib_extra_pkg_install
 set -e; \
-mkdir -p debian/$(1)/usr/include/sys; \
-ln -sf $(DEB_HOST_MULTIARCH)/bits debian/$(1)/usr/include/; \
-ln -sf $(DEB_HOST_MULTIARCH)/gnu debian/$(1)/usr/include/; \
-ln -sf $(DEB_HOST_MULTIARCH)/fpu_control.h debian/$(1)/usr/include/; \
-for i in `ls debian/tmp/usr/include/$(DEB_HOST_MULTIARCH)/sys`; do \
-	ln -sf ../$(DEB_HOST_MULTIARCH)/sys/$$i debian/$(1)/usr/include/sys/$$i; \
+mkdir -p debian/$(1)/usr/include; \
+for i in `ls debian/tmp/usr/include/$(DEB_HOST_MULTIARCH)`; do \
+	if test -d "debian/tmp/usr/include/$(DEB_HOST_MULTIARCH)/$$i" && ! test "$$i" = bits -o "$$i" = gnu; then \
+		mkdir -p "debian/$(1)/usr/include/$$i"; \
+		for j in `ls debian/tmp/usr/include/$(DEB_HOST_MULTIARCH)/$$i`; do \
+			ln -sf "../$(DEB_HOST_MULTIARCH)/$$i/$$j" "debian/$(1)/usr/include/$$i/$$j"; \
+		done; \
+	else \
+		ln -sf "$(DEB_HOST_MULTIARCH)/$$i" "debian/$(1)/usr/include/$$i"; \
+	fi; \
 done
 mkdir -p debian/$(1)/usr/include/finclude; \
 for i in `ls debian/tmp/usr/include/finclude/$(DEB_HOST_MULTIARCH)`; do \
@@ -270,15 +272,11 @@
 	    echo "/lib/$(DEB_HOST_GNU_TYPE)" >> $$conffile; \
 	    echo "/usr/lib/$(DEB_HOST_GNU_TYPE)" >> $$conffile; \
 	  fi; \
-	  mkdir -p $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/bits $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/gnu $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/sys $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/fpu_control.h $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/a.out.h $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/ieee754.h $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH); \
+	  mkdir -p $(debian-tmp)/usr/include.tmp; \
+	  mv $(debian-tmp)/usr/include $(debian-tmp)/usr/include.tmp/$(DEB_HOST_MULTIARCH); \
+	  mv $(debian-tmp)/usr/include.tmp $(debian-tmp)/usr/include; \
 	  mkdir -p $(debian-tmp)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
-	  mv $(debian-tmp)/usr/include/finclude/math-vector-fortran.h $(debian-tmp)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
+	  mv $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH)/finclude/math-vector-fortran.h $(debian-tmp)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
 	fi
 
 	ifeq ($(filter stage1,$(DEB_BUILD_PROFILES)),)
--- a/debian/sysdeps/hurd-i386.mk
+++ b/debian/sysdeps/hurd-i386.mk
@@ -18,9 +18,6 @@ endif
 define libc_extra_install
 mkdir -p $(debian-tmp)/lib
 ln -s ld.so.1 $(debian-tmp)/lib/ld.so
-mkdir -p $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH)/mach
-mv $(debian-tmp)/usr/include/mach/i386 $(debian-tmp)/usr/include/$(DEB_HOST_MULTIARCH)/mach/
-ln -s ../$(DEB_HOST_MULTIARCH)/mach/i386 $(debian-tmp)/usr/include/mach/i386
 endef
 
 # FIXME: We are having runtime issues with ifunc...
EOF
	# https://salsa.debian.org/glibc-team/glibc/-/merge_requests/16
	echo "patching glibc to support -Wno-error"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.d/build.mk
+++ b/debian/rules.d/build.mk
@@ -116,6 +116,7 @@ endif
 		$(if $(filter $(pt_chown),yes),--enable-pt_chown) \
 		$(if $(filter $(threads),no),--disable-nscd) \
 		$(if $(filter $(call xx,mvec),no),--disable-mathvec) \
+		$(if $(filter -Wno-error,$(shell dpkg-buildflags --get CFLAGS)),--disable-werror) \
 		$(call xx,with_headers) $(call xx,extra_config_options)
 	touch $@

EOF
	# disbale -fstack-protector-all for rv32
	echo "disable fstack-protectot-all"
	drop_privs patch -p1 <<'EOF'
--- glibc-2.36/debian/rules.d/build.mk	2022-11-30 07:21:33.000000000 -0500
+++ glibc-2.36/debian/rules.d/build.mk	2023-06-19 04:34:32.000000000 -0400
@@ -109,7 +109,6 @@
 		--without-selinux \
 		--disable-crypt \
 		--enable-stackguard-randomization \
-		--enable-stack-protector=strong \
 		--with-pkgversion="Debian GLIBC $(DEB_VERSION)" \
 		--with-bugurl="http://www.debian.org/Bugs/" \
 		--with-timeoutfactor="$(TIMEOUTFACTOR)" \


EOF
}
buildenv_glibc() {
	export DEB_GCC_VERSION="-$GCC_VER"
	# glibc passes -Werror by default as it uses a fixed gcc version. We change that version.
	export DEB_CFLAGS_APPEND="${DEB_CFLAGS_APPEND:-} -Wno-error"
}

add_automatic gmp

builddep_gnu_efi() {
	# binutils dependency needs cross translation
	apt_get_install debhelper
}

add_automatic gnupg2
add_automatic gpm
add_automatic grep
add_automatic groff

add_automatic guile-3.0
patch_guile_3_0() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-any-any || return 0
	echo "fixing libc dependency #1008712"
	drop_privs sed -i -e s/libc6-dev/libc-dev/ debian/control
}
builddep_guile_3_0() {
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P cross ./
	if test "$HOST_ARCH" = loong64; then
		echo "add loong64 support #1024295"
		# https://git.savannah.gnu.org/gitweb/?p=guile.git;a=commit;h=f3ea8f7fa1d84a559c7bf834fe5b675abe0ae7b8
		sed -i -e 's/"riscv/"loongarch/' /usr/share/guile/3.0/system/base/target.scm
	fi
}

add_automatic gzip
patch_gzip() {
	test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_BITS)" = 32 || return 0
	echo "fixing time_t ftcbfs #1009893"
	drop_privs sed -i -e '/CONFIGURE_ARGS.*--host/s/$/ --build=${DEB_BUILD_GNU_TYPE}/' debian/rules
}
buildenv_gzip() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-linux-any || return 0
	# this avoids replacing fseeko with a variant that is broken
	echo gl_cv_func_fflush_stdin exported
	export gl_cv_func_fflush_stdin=yes
}

add_automatic hostname
add_automatic icu
add_automatic isl-0.18
add_automatic jansson
add_automatic jemalloc
add_automatic keyutils
add_automatic kmod

add_automatic krb5
buildenv_krb5() {
	export krb5_cv_attr_constructor_destructor=yes,yes
	export ac_cv_func_regcomp=yes
	export ac_cv_printf_positional=yes
}

add_automatic libassuan
add_automatic libatomic-ops

add_automatic libbsd
patch_libbsd() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-any-any || return 0
	echo "fix musl FTBFS #1032159"
	drop_privs patch -p1 <<'EOF'
--- a/debian/libbsd-dev.install
+++ b/debian/libbsd-dev.install
@@ -1,4 +1,3 @@
-usr/lib/*/libbsd-ctor.a
 usr/lib/*/libbsd.a
 usr/lib/*/libbsd.so
 usr/lib/*/pkgconfig/*.pc
--- a/debian/rules
+++ b/debian/rules
@@ -6,8 +6,15 @@
 export DEB_BUILD_MAINT_OPTIONS = hardening=+all
 export DEB_CFLAGS_MAINT_PREPEND = -Wall

+include /usr/share/dpkg/architecture.mk
+
 %:
 	dh $@

 override_dh_installchangelogs:
 	dh_installchangelogs --no-trim
+
+ifneq ($(DEB_HOST_ARCH_LIBC),musl)
+execute_after_dh_install:
+	dh_install -plibbsd-dev usr/lib/*/libbsd-ctor.a
+endif
EOF
}

add_automatic libcap2
add_automatic libdebian-installer
add_automatic libev
add_automatic libevent

add_automatic libffi
patch_libffi() {
	echo "fix symbols for loong64 #1024359"
	drop_privs sed -i '/)LIBFFI_COMPLEX_8\.0 /s/)/ !loong64)/' debian/libffi8.symbols
	echo "fix symbols for riscv32 "
	drop_privs sed -i '/)LIBFFI_COMPLEX_8\.0 /s/)/ !riscv32)/' debian/libffi8.symbols
}

add_automatic libgc
buildenv_libgc() {
	if dpkg-architecture "-a$1" -imusl-linux-any; then
		echo "ignoring symbol differences for musl for now"
		export DPKG_GENSYMBOLS_CHECK_LEVEL=0
	fi
	if test "$1" = arc; then
		echo "ignoring symbol differences for arc #994211"
		export DPKG_GENSYMBOLS_CHECK_LEVEL=0
	fi
}

add_automatic libgcrypt20
buildenv_libgcrypt20() {
	export ac_cv_sys_symbol_underscore=no
}

add_automatic libgpg-error
add_automatic libice
add_automatic libidn

add_automatic libidn2
patch_libidn2() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-linux-any || return 0
	echo "patching gettext version for musl support #999510"
	drop_privs rm -f m4/gettext.m4
	drop_privs patch -p1 <<'EOF'
--- a/configure.ac
+++ b/configure.ac
@@ -90,7 +90,8 @@
 ])

 AM_GNU_GETTEXT([external])
-AM_GNU_GETTEXT_VERSION([0.19.3])
+AM_GNU_GETTEXT_REQUIRE_VERSION([0.19.8])
+AM_GNU_GETTEXT_VERSION([0.19.6])

 AX_CODE_COVERAGE

EOF
	# must be newer than configure.ac
	drop_privs touch doc/idn2.1
}

add_automatic libksba
add_automatic libmd
add_automatic libnsl
add_automatic libonig
add_automatic libpipeline
add_automatic libpng1.6

# riscv32
add_automatic libprelude
buildenv_libprelude() {
	case $(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_SYSTEM) in *gnu*)
		echo "glibc does not return NULL for malloc(0)"
		export ac_cv_func_malloc_0_nonnull=yes
	;; esac
}
patch_libprelude() {
	dpkg-architecture "-a$HOST_ARCH" -iriscv32 || return 0
	echo "update symbols for riscv32"
	drop_privs patch -p1 <<'EOF'
--- a/debian/libpreludecpp12.symbols
+++ b/debian/libpreludecpp12.symbols
@@ -225,8 +225,8 @@
  _ZN7Prelude9IDMEFTime12setGmtOffsetEi@Base 4.1
  _ZN7Prelude9IDMEFTime3setEPK7timeval@Base 4.1
  _ZN7Prelude9IDMEFTime3setEPKc@Base 4.1
- (arch=!x32 !arc)_ZN7Prelude9IDMEFTime3setEPKl@Base 4.1
- (arch=x32 arc)_ZN7Prelude9IDMEFTime3setEPKx@Base 4.1
+#MISSING: 5.2.0-5+b7# (arch=!x32 !arc)_ZN7Prelude9IDMEFTime3setEPKl@Base 4.1
+ _ZN7Prelude9IDMEFTime3setEPKx@Base 4.1
  _ZN7Prelude9IDMEFTime3setEv@Base 4.1
  _ZN7Prelude9IDMEFTime6setSecEj@Base 4.1
  _ZN7Prelude9IDMEFTime7setUSecEj@Base 4.1
@@ -234,17 +234,17 @@
  _ZN7Prelude9IDMEFTimeC1EPK7timeval@Base 4.1
  _ZN7Prelude9IDMEFTimeC1EPKc@Base 4.1
  _ZN7Prelude9IDMEFTimeC1ERKS0_@Base 4.1
- (arch=!x32 !arc)_ZN7Prelude9IDMEFTimeC1El@Base 4.1
+#MISSING: 5.2.0-5+b7# (arch=!x32 !arc)_ZN7Prelude9IDMEFTimeC1El@Base 4.1
  _ZN7Prelude9IDMEFTimeC1Ev@Base 4.1
- (arch=x32 arc)_ZN7Prelude9IDMEFTimeC1Ex@Base 4.1
+ _ZN7Prelude9IDMEFTimeC1Ex@Base 4.1
  _ZN7Prelude9IDMEFTimeC2EP10idmef_time@Base 4.1
  _ZN7Prelude9IDMEFTimeC2EPK7timeval@Base 4.1
  _ZN7Prelude9IDMEFTimeC2EPKc@Base 4.1
  _ZN7Prelude9IDMEFTimeC2ERKS0_@Base 4.1
  _ZN7Prelude9IDMEFTimeC2El@Base 4.1
- (arch=!x32 !arc)_ZN7Prelude9IDMEFTimeC2El@Base 4.1
+#MISSING: 5.2.0-5+b7# (arch=!x32 !arc)_ZN7Prelude9IDMEFTimeC2El@Base 4.1
  _ZN7Prelude9IDMEFTimeC2Ev@Base 4.1
- (arch=x32 arc)_ZN7Prelude9IDMEFTimeC2Ex@Base 4.1
+ _ZN7Prelude9IDMEFTimeC2Ex@Base 4.1
  _ZN7Prelude9IDMEFTimeD1Ev@Base 4.1
  _ZN7Prelude9IDMEFTimeD2Ev@Base 4.1
  _ZN7Prelude9IDMEFTimeaSERKS0_@Base 4.1
@@ -292,7 +292,7 @@
  _ZNK7Prelude13IDMEFCriteria5cloneEv@Base 4.1
  _ZNK7Prelude13IDMEFCriteria5matchEPNS_5IDMEFE@Base 4.1
  _ZNK7Prelude13IDMEFCriteria8toStringB5cxx11Ev@Base 4.1
- (optional)_ZNK7Prelude13IDMEFCriteriacvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
+#MISSING: 5.2.0-5+b7# (optional)_ZNK7Prelude13IDMEFCriteriacvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
  _ZNK7Prelude13IDMEFCriteriacvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEEv@Base 4.1
  _ZNK7Prelude13IDMEFCriteriacvP14idmef_criteriaEv@Base 4.1
  _ZNK7Prelude14ConnectionPool17getConnectionListEv@Base 4.1
@@ -303,7 +303,7 @@
  _ZNK7Prelude5IDMEF5getIdEv@Base 4.1
  _ZNK7Prelude5IDMEF6toJSONB5cxx11Ev@Base 4.1
  _ZNK7Prelude5IDMEF8toStringB5cxx11Ev@Base 4.1
- (optional)_ZNK7Prelude5IDMEFcvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
+#MISSING: 5.2.0-5+b7# (optional)_ZNK7Prelude5IDMEFcvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
  _ZNK7Prelude5IDMEFcvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEEv@Base 4.1
  _ZNK7Prelude5IDMEFcvP12idmef_objectEv@Base 4.1
  _ZNK7Prelude6Client17getConfigFilenameEv@Base 4.1
@@ -344,7 +344,7 @@
  _ZNK7Prelude9IDMEFTime6getSecEv@Base 4.1
  _ZNK7Prelude9IDMEFTime7getUSecEv@Base 4.1
  _ZNK7Prelude9IDMEFTime8toStringB5cxx11Ev@Base 4.1
- (optional)_ZNK7Prelude9IDMEFTimecvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
+#MISSING: 5.2.0-5+b7# (optional)_ZNK7Prelude9IDMEFTimecvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEB5cxx11Ev@Base 4.1
  _ZNK7Prelude9IDMEFTimecvKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEEv@Base 4.1
  _ZNK7Prelude9IDMEFTimecvP10idmef_timeEv@Base 4.1
  _ZNK7Prelude9IDMEFTimecvdEv@Base 4.1
@@ -360,19 +360,21 @@
  (optional)_ZNSt12_Vector_baseIN7Prelude10IDMEFClass14IDMEFClassElemESaIS2_EED2Ev@Base 5.1.1
  (optional)_ZNSt6vectorIN7Prelude10ConnectionESaIS1_EE17_M_realloc_insertIJS1_EEEvN9__gnu_cxx17__normal_iteratorIPS1_S3_EEDpOT_@Base 4.1
  (optional)_ZNSt6vectorIN7Prelude10IDMEFClass14IDMEFClassElemESaIS2_EE17_M_realloc_insertIJRKS2_EEEvN9__gnu_cxx17__normal_iteratorIPS2_S4_EEDpOT_@Base 4.1
- (optional)_ZNSt6vectorIN7Prelude10IDMEFClass14IDMEFClassElemESaIS2_EEaSERKS4_@Base 4.1
+#MISSING: 5.2.0-5+b7# (optional)_ZNSt6vectorIN7Prelude10IDMEFClass14IDMEFClassElemESaIS2_EEaSERKS4_@Base 4.1
  (optional)_ZNSt6vectorIN7Prelude10IDMEFValueESaIS1_EE17_M_realloc_insertIJS1_EEEvN9__gnu_cxx17__normal_iteratorIPS1_S3_EEDpOT_@Base 4.1
  (optional)_ZNSt6vectorINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESaIS5_EE17_M_realloc_insertIJS5_EEEvN9__gnu_cxx17__normal_iteratorIPS5_S7_EEDpOT_@Base 4.1
- (optional)_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE12_M_constructIPKcEEvT_S8_St20forward_iterator_tag@Base 4.1
+#MISSING: 5.2.0-5+b7# (optional)_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE12_M_constructIPKcEEvT_S8_St20forward_iterator_tag@Base 4.1
  (optional)_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC1IS3_EEPKcRKS3_@Base 5.2.0
  (optional)_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC2IS3_EEPKcRKS3_@Base 5.2.0
  _ZNSt7__cxx1115basic_stringbufIcSt11char_traitsIcESaIcEED0Ev@Base 5.0.0
  _ZNSt7__cxx1115basic_stringbufIcSt11char_traitsIcESaIcEED1Ev@Base 5.0.0
  _ZNSt7__cxx1115basic_stringbufIcSt11char_traitsIcESaIcEED2Ev@Base 5.0.0
- (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE22_M_emplace_hint_uniqueIJRKSt21piecewise_construct_tSt5tupleIJOS5_EESJ_IJEEEEESt17_Rb_tree_iteratorIS8_ESt23_Rb_tree_const_iteratorIS8_EDpOT_@Base 5.0.0
+#MISSING: 5.2.0-5+b7# (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE22_M_emplace_hint_uniqueIJRKSt21piecewise_construct_tSt5tupleIJOS5_EESJ_IJEEEEESt17_Rb_tree_iteratorIS8_ESt23_Rb_tree_const_iteratorIS8_EDpOT_@Base 5.0.0
  (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE24_M_get_insert_unique_posERS7_@Base 5.0.0
  (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE29_M_get_insert_hint_unique_posESt23_Rb_tree_const_iteratorIS8_ERS7_@Base 5.0.0
- (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE8_M_eraseEPSt13_Rb_tree_nodeIS8_E@Base 5.0.0
+#MISSING: 5.2.0-5+b7# (optional)_ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE8_M_eraseEPSt13_Rb_tree_nodeIS8_E@Base 5.0.0
+ _ZSt16__do_uninit_copyIPKN7Prelude10ConnectionEPS1_ET0_T_S6_S5_@Base 5.2.0-5+b7
+ _ZSt16__do_uninit_copyIPKN7Prelude10IDMEFValueEPS1_ET0_T_S6_S5_@Base 5.2.0-5+b7
  _ZTIN7Prelude12PreludeErrorE@Base 4.1
  _ZTSN7Prelude12PreludeErrorE@Base 4.1
  _ZTVN7Prelude12PreludeErrorE@Base 4.1
EOF
}
add_automatic libpsl
add_automatic libpthread-stubs
add_automatic libsepol
add_automatic libsm
add_automatic libsodium
add_automatic libssh
add_automatic libssh2
add_automatic libsystemd-dummy
add_automatic libtasn1-6
add_automatic libtextwrap
add_automatic libtirpc

builddep_libtool() {
	assert_built "zlib"
	test "$1" = "$HOST_ARCH"
	# gfortran dependency needs cross-translation
	# gnulib dependency lacks M-A:foreign
	apt_get_install debhelper file "gfortran-$GCC_VER$HOST_ARCH_SUFFIX" automake autoconf autotools-dev help2man texinfo "zlib1g-dev:$HOST_ARCH" gnulib
}

add_automatic libunistring
buildenv_libunistring() {
	if dpkg-architecture "-a$HOST_ARCH" -ignu-any-any; then
		echo "glibc does not prefer rwlock writers to readers"
		export gl_cv_pthread_rwlock_rdlock_prefer_writer=no
	fi
	echo "memchr and strstr generally work"
	export gl_cv_func_memchr_works=yes
	export gl_cv_func_strstr_works_always=yes
	export gl_cv_func_strstr_linear=yes
	if dpkg-architecture "-a$HOST_ARCH" -imusl-any-any; then
		echo "setting malloc/realloc do not return 0"
		export ac_cv_func_malloc_0_nonnull=yes
		export ac_cv_func_realloc_0_nonnull=yes
	fi
}
patch_libunistring() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-any-any || return 0
	echo "update symbols for musl #1022846"
	drop_privs patch -p1 <<'EOF'
--- a/debian/libunistring2.symbols
+++ b/debian/libunistring2.symbols
@@ -162,10 +162,18 @@
  libunistring_gl_uninorm_decomp_chars_table@Base 0.9.7
  libunistring_gl_uninorm_decomp_index_table@Base 0.9.7
  libunistring_gl_uninorm_decompose_merge_sort_inplace@Base 0.9.7
- libunistring_glthread_once_multithreaded@Base 1.0
+ (arch=gnu-any-any)libunistring_glthread_once_multithreaded@Base 1.0
  libunistring_glthread_once_singlethreaded@Base 0.9.7
+ (arch=musl-any-any)libunistring_glthread_recursive_lock_destroy_multithreaded@Base 1.0-2
  libunistring_glthread_recursive_lock_init_multithreaded@Base 0.9.7
+ (arch=musl-any-any)libunistring_glthread_recursive_lock_lock_multithreaded@Base 1.0-2
+ (arch=musl-any-any)libunistring_glthread_recursive_lock_unlock_multithreaded@Base 1.0-2
+ (arch=musl-any-any)libunistring_glthread_rwlock_destroy_multithreaded@Base 1.0-2
  (arch=gnu-any-any)libunistring_glthread_rwlock_init_for_glibc@Base 0.9.8
+ (arch=musl-any-any)libunistring_glthread_rwlock_init_multithreaded@Base 1.0-2
+ (arch=musl-any-any)libunistring_glthread_rwlock_rdlock_multithreaded@Base 1.0-2
+ (arch=musl-any-any)libunistring_glthread_rwlock_unlock_multithreaded@Base 1.0-2
+ (arch=musl-any-any)libunistring_glthread_rwlock_wrlock_multithreaded@Base 1.0-2
  libunistring_hard_locale@Base 0.9.7
  libunistring_iconveh_close@Base 0.9.7
  libunistring_iconveh_open@Base 0.9.7
EOF
}

add_automatic libusb
add_automatic libusb-1.0
add_automatic libverto

add_automatic libx11
buildenv_libx11() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxau
add_automatic libxaw
add_automatic libxcb

add_automatic libxcrypt
patch_libxcrypt() {
	echo "do not abuse Important and Protected fields #1024616"
	drop_privs sed -i -e '/\(Important\|Protected\):/d' debian/control
	if test "$HOST_ARCH" = riscv32; then
        	echo "patching libxcrypt to support riscv32"
               	drop_privs patch -p1  <<'EOF'
--- /dev/null
+++ b/debian/libcrypt1.symbols.riscv32
@@ -0,0 +1,10 @@
+libcrypt.so.1 libcrypt1 #MINVER#
+#include "libcrypt1.symbols.common"
+ GLIBC_2.33@GLIBC_2.33 1:4.4.33-2
+ crypt@GLIBC_2.33 1:4.4.33-2
+ crypt_r@GLIBC_2.33 1:4.4.33-2
+ encrypt@GLIBC_2.33 1:4.4.33-2
+ encrypt_r@GLIBC_2.33 1:4.4.33-2
+ fcrypt@GLIBC_2.33 1:4.4.33-2
+ setkey@GLIBC_2.33 1:4.4.33-2
+ setkey_r@GLIBC_2.33 1:4.4.33-2
EOF
	fi
}

add_automatic libxdmcp

add_automatic libxext
buildenv_libxext() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxmu
add_automatic libxpm

add_automatic libxrender
buildenv_libxrender() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxss
buildenv_libxss() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxt
buildenv_libxt() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libzstd

patch_linux() {
	local kernel_arch comment regen_control
	kernel_arch=
	comment="just building headers yet"
	regen_control=
	case "$HOST_ARCH" in
		arc|csky|ia64|nios2)
			kernel_arch=$HOST_ARCH
		;;
		loong64) kernel_arch=loongarch ;;
		mipsr6|mipsr6el|mipsn32r6|mipsn32r6el|mips64r6|mips64r6el)
			kernel_arch=defines-only
		;;
		powerpcel) kernel_arch=powerpc; ;;
		riscv64) kernel_arch=riscv; ;;
		# https://salsa.debian.org/kernel-team/linux/-/merge_requests/703/diffs
		riscv32) kernel_arch=riscv; ;;
		*-linux-*)
			if ! test -d "debian/config/$HOST_ARCH"; then
				kernel_arch=$(sed 's/^kernel-arch: //;t;d' < "debian/config/${HOST_ARCH#*-linux-}/defines")
				comment="$HOST_ARCH must be part of a multiarch installation with a ${HOST_ARCH#*-linux-*} kernel"
			fi
		;;
	esac
	if test -n "$kernel_arch"; then
		if test "$kernel_arch" != defines-only; then
			echo "patching linux for $HOST_ARCH with kernel-arch $kernel_arch"
			drop_privs mkdir -p "debian/config/$HOST_ARCH"
			drop_privs tee "debian/config/$HOST_ARCH/defines" >/dev/null <<EOF
[base]
kernel-arch: $kernel_arch
featuresets:
# empty; $comment
EOF
		else
			echo "patching linux to enable $HOST_ARCH"
		fi
		drop_privs sed -i -e "/^arches:/a\\ $HOST_ARCH" debian/config/defines
		regen_control=yes
	fi
	test "$regen_control" = yes || return 0
	apt_get_install kernel-wedge python3-jinja2
	drop_privs ./debian/rules debian/rules.gen || : # intentionally exits 1 to avoid being called automatically. we are doing it wrong
}

add_automatic lz4
add_automatic make-dfsg
add_automatic man-db
add_automatic mawk
add_automatic mpclib3
add_automatic mpfr4

builddep_ncurses() {
	if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
		assert_built gpm
		apt_get_install "libgpm-dev:$1"
	fi
	# g++-multilib dependency unsatisfiable
	apt_get_install debhelper pkg-config autoconf-dickey
	case "$ENABLE_MULTILIB:$HOST_ARCH" in
		yes:amd64|yes:i386|yes:powerpc|yes:ppc64|yes:s390|yes:sparc)
			test "$1" = "$HOST_ARCH"
			apt_get_install "g++-$GCC_VER-multilib$HOST_ARCH_SUFFIX"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
	esac
}

add_automatic nettle
add_automatic nghttp2
add_automatic npth
add_automatic nspr

add_automatic nss
patch_nss() {
	if dpkg-architecture "-a$HOST_ARCH" -iany-ppc64el; then
		echo "fix FTCBFS for ppc64el #948523"
		drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -40,7 +40,8 @@
 ifeq ($(origin RANLIB),default)
 TOOLCHAIN += RANLIB=$(DEB_HOST_GNU_TYPE)-ranlib
 endif
-TOOLCHAIN += OS_TEST=$(DEB_HOST_GNU_CPU)
+OS_TYPE_map_powerpc64le = ppc64le
+TOOLCHAIN += OS_TEST=$(or $(OS_TYPE_map_$(DEB_HOST_GNU_CPU)),$(DEB_HOST_GNU_CPU))
 TOOLCHAIN += KERNEL=$(DEB_HOST_ARCH_OS)
 endif

EOF
	fi
	echo "work around FTBFS #984258"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -110,6 +110,7 @@
 		NSPR_LIB_DIR=/usr/lib/$(DEB_HOST_MULTIARCH) \
 		BUILD_OPT=1 \
 		NS_USE_GCC=1 \
+		NSS_ENABLE_WERROR=0 \
 		OPTIMIZER="$(CFLAGS) $(CPPFLAGS)" \
 		LDFLAGS='$(LDFLAGS) $$(ARCHFLAG) $$(ZDEFS_FLAG)' \
 		DSO_LDOPTS='-shared $$(LDFLAGS)' \
EOF
}

buildenv_openldap() {
	export ol_cv_pthread_select_yields=yes
	export ac_cv_func_memcmp_working=yes
}

add_automatic openssl
patch_openssl() {
	if test "$HOST_ARCH" = riscv32; then
        	echo "patching openssl to support riscv32"
               	drop_privs patch -p1  <<'EOF'
--- a/Configurations/20-debian.conf
+++ b/Configurations/20-debian.conf
@@ -124,6 +124,9 @@ my %targets = (
 	"debian-ppc64el" => {
 		inherit_from => [ "linux-ppc64le", "debian" ],
 	},
+	"debian-riscv32" => {
+		inherit_from => [ "linux-generic32", "debian" ],
+	},
 	"debian-riscv64" => {
 		inherit_from => [ "linux-generic64", "debian" ],
 	},
EOF
	fi
}

add_automatic openssl1.0
add_automatic p11-kit
add_automatic patch

add_automatic pcre2
patch_pcre2() {
	if test "$HOST_ARCH" = sparc; then
		echo "fixing FTBFS on sparc #1034779"
		drop_privs sed -i -e 's/ sparc / /' debian/rules
	fi
}

add_automatic pcre3

patch_perl() {
	echo "add missing libcrypt-dev dependency #1029753"
	drop_privs sed -i -e '/^Build-Depends:/s/$/libcrypt-dev,/' debian/control
}

add_automatic pkgconf
add_automatic popt

builddep_readline() {
	assert_built "ncurses"
	# gcc-multilib dependency unsatisfiable
	apt_get_install debhelper "libtinfo-dev:$1" "libncursesw5-dev:$1" mawk texinfo autotools-dev
	case "$ENABLE_MULTILIB:$HOST_ARCH" in
		yes:amd64|yes:ppc64)
			test "$1" = "$HOST_ARCH"
			apt_get_install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX" "lib32tinfo-dev:$1" "lib32ncursesw5-dev:$1"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$1 -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
		yes:i386|yes:powerpc|yes:sparc|yes:s390)
			test "$1" = "$HOST_ARCH"
			apt_get_install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX" "lib64ncurses5-dev:$1"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$1 -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
	esac
}

add_automatic rtmpdump

add_automatic sed
patch_sed() {
	dpkg-architecture "-a$HOST_ARCH" -imusl-any-any || return 0
	echo "musl FTBFS #1010224"
	drop_privs sed -i -e '1ainclude /usr/share/dpkg/architecture.mk' debian/rules
	drop_privs sed -i -e 's/--without-included-regex/--with$(if $(filter musl,$(DEB_HOST_ARCH_LIBC)),,out)-included-regex/' debian/rules
}

add_automatic shadow
add_automatic slang2
add_automatic spdylay
add_automatic sqlite3
add_automatic sysvinit

add_automatic tar
buildenv_tar() {
	case $(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_SYSTEM) in *gnu*)
		echo "struct dirent contains working d_ino on glibc systems"
		export gl_cv_struct_dirent_d_ino=yes
	;; esac
	if ! dpkg-architecture "-a$HOST_ARCH" -ilinux-any; then
		echo "forcing broken posix acl check to fail on non-linux #850668"
		export gl_cv_getxattr_with_posix_acls=no
	fi
	case "$HOST_ARCH" in arm64ilp32|x32)
		echo "work around time64 inconsistency FTBFS to be fixed via #1030159"
		export DEB_CPPFLAGS_APPEND="${DEB_CPPFLAGS_APPEND:+$DEB_CPPFLAGS_APPEND }-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
	esac
}

add_automatic tcl8.6
buildenv_tcl8_6() {
	export tcl_cv_strtod_buggy=ok
	export tcl_cv_strtoul_unbroken=ok
}

add_automatic tcltk-defaults
add_automatic tcp-wrappers

add_automatic tk8.6
buildenv_tk8_6() {
	export tcl_cv_strtod_buggy=ok
}

add_automatic uchardet
add_automatic ustr

buildenv_util_linux() {
	export scanf_cv_type_modifier=ms
}

add_automatic xft
add_automatic xxhash

add_automatic xz-utils
buildenv_xz_utils() {
	if dpkg-architecture "-a$1" -imusl-linux-any; then
		echo "ignoring symbol differences for musl for now"
		export DPKG_GENSYMBOLS_CHECK_LEVEL=0
	fi
}

builddep_zlib() {
	# gcc-multilib dependency unsatisfiable
	apt_get_install debhelper binutils dpkg-dev
}

# choosing libatomic1 arbitrarily here, cause it never bumped soname
BUILD_GCC_MULTIARCH_VER=`apt-cache show --no-all-versions libatomic1 | sed 's/^Source: gcc-\([0-9.]*\)$/\1/;t;d'`
if test "$GCC_VER" != "$BUILD_GCC_MULTIARCH_VER"; then
	echo "host gcc version ($GCC_VER) and build gcc version ($BUILD_GCC_MULTIARCH_VER) mismatch. need different build gcc"
if dpkg --compare-versions "$GCC_VER" gt "$BUILD_GCC_MULTIARCH_VER"; then
	echo "deb [ arch=$(dpkg --print-architecture) ] $MIRROR experimental main" > /etc/apt/sources.list.d/tmp-experimental.list
	$APT_GET update
	$APT_GET -t experimental install g++ g++-$GCC_VER
	rm -f /etc/apt/sources.list.d/tmp-experimental.list
	$APT_GET update
elif test -f "$REPODIR/stamps/gcc_0"; then
	echo "skipping rebuild of build gcc"
	$APT_GET --force-yes dist-upgrade # downgrade!
else
	cross_build_setup "gcc-$GCC_VER" gcc0
	apt_get_build_dep --arch-only ./
	# dependencies for common libs no longer declared
	apt_get_install doxygen graphviz ghostscript texlive-latex-base xsltproc docbook-xsl-ns
	(
		export gcc_cv_libc_provides_ssp=yes
		nolang=$(set_add "${GCC_NOLANG:-}" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS nostrap nolang=$(join_words , $nolang)"
		drop_privs_exec dpkg-buildpackage -B -uc -us
	)
	cd ..
	ls -l
	reprepro include rebootstrap-native ./*.changes
	drop_privs rm -fv ./*-plugin-dev_*.deb ./*-dbg_*.deb
	dpkg -i *.deb
	touch "$REPODIR/stamps/gcc_0"
	cd ..
	drop_privs rm -Rf gcc0
fi
progress_mark "build compiler complete"
else
echo "host gcc version and build gcc version match. good for multiarch"
fi

if test -f "$REPODIR/stamps/cross-binutils"; then
	echo "skipping rebuild of binutils-target"
else
	cross_build_setup binutils
	check_binNMU
	apt_get_build_dep --arch-only -Pnocheck ./
	drop_privs TARGET=$HOST_ARCH dpkg-buildpackage -B -Pnocheck --target=stamps/control
	drop_privs TARGET=$HOST_ARCH dpkg-buildpackage -B -uc -us -Pnocheck
	cd ..
	ls -l
	pickup_packages *.changes
	apt_get_install "binutils$HOST_ARCH_SUFFIX"
	assembler="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-as"
	if ! command -v "$assembler" >/dev/null; then echo "$assembler missing in binutils package"; exit 1; fi
	if ! drop_privs "$assembler" -o test.o /dev/null; then echo "binutils fail to execute"; exit 1; fi
	if ! test -f test.o; then echo "binutils fail to create object"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	touch "$REPODIR/stamps/cross-binutils"
	cd ..
	drop_privs rm -Rf binutils
fi
progress_mark "cross binutils"

if test "$HOST_ARCH" = hppa && ! test -f "$REPODIR/stamps/cross-binutils-hppa64"; then
	cross_build_setup binutils binutils-hppa64
	check_binNMU
	apt_get_build_dep --arch-only -Pnocheck ./
	drop_privs with_hppa64=yes DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS nocross nomult nopgo" dpkg-buildpackage -B -Pnocheck --target=stamps/control
	drop_privs with_hppa64=yes DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS nocross nomult nopgo" dpkg-buildpackage -B -uc -us -Pnocheck
	cd ..
	ls -l
	pickup_additional_packages binutils-hppa64-linux-gnu_*.deb
	apt_get_install binutils-hppa64-linux-gnu
	if ! command -v hppa64-linux-gnu-as >/dev/null; then echo "hppa64-linux-gnu-as missing in binutils package"; exit 1; fi
	if ! drop_privs hppa64-linux-gnu-as -o test.o /dev/null; then echo "binutils-hppa64 fail to execute"; exit 1; fi
	if ! test -f test.o; then echo "binutils-hppa64 fail to create object"; exit 1; fi
	check_arch test.o hppa64
	touch "$REPODIR/stamps/cross-binutils-hppa64"
	cd ..
	drop_privs rm -Rf binutils-hppa64-linux-gnu
	progress_mark "cross binutils-hppa64"
fi

if test "`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS`" = "linux"; then
if test -f "$REPODIR/stamps/linux_1"; then
	echo "skipping rebuild of linux-libc-dev"
else
	cross_build_setup linux
	check_binNMU
	if dpkg-architecture -ilinux-any && test "$(dpkg-query -W -f '${Version}' "linux-libc-dev:$(dpkg --print-architecture)")" != "$(dpkg-parsechangelog -SVersion)"; then
		echo "rebootstrap-warning: working around linux-libc-dev m-a:same skew"
		apt_get_build_dep --arch-only -Pstage1 ./
		drop_privs KBUILD_VERBOSE=1 dpkg-buildpackage -B -Pstage1 -uc -us
	fi
	apt_get_build_dep --arch-only "-a$HOST_ARCH" -Pstage1 ./
	drop_privs KBUILD_VERBOSE=1 dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	ls -l
	if test "$ENABLE_MULTIARCH_GCC" != yes; then
		drop_privs dpkg-cross -M -a "$HOST_ARCH" -b ./*"_$HOST_ARCH.deb"
	fi
	pickup_packages *.deb
	touch "$REPODIR/stamps/linux_1"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf linux
fi
progress_mark "linux-libc-dev cross build"
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/gnumach_1"; then
	echo "skipping rebuild of gnumach stage1"
else
	cross_build_setup gnumach gnumach_1
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -Pstage1 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	pickup_packages ./*.deb
	touch "$REPODIR/stamps/gnumach_1"
	cd ..
	drop_privs rm -Rf gnumach_1
fi
progress_mark "gnumach stage1 cross build"
fi

GCC_AUTOCONF=autoconf2.69

if test -f "$REPODIR/stamps/gcc_1"; then
	echo "skipping rebuild of gcc stage1"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" time
	if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			apt_get_install "linux-libc-dev:$HOST_ARCH"
		else
			apt_get_install "linux-libc-dev-${HOST_ARCH}-cross"
		fi
	fi
	if test "$HOST_ARCH" = hppa; then
		apt_get_install binutils-hppa64-linux-gnu
	fi
	cross_build_setup "gcc-$GCC_VER" gcc1
	check_binNMU
	dpkg-checkbuilddeps || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_STAGE=stage1
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		drop_privs dpkg-buildpackage -d -T control
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	pickup_packages *.changes
	apt_get_remove gcc-multilib
	if test "$ENABLE_MULTILIB" = yes && ls | grep -q multilib; then
		apt_get_install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX"
	else
		rm -vf ./*multilib*.deb
		apt_get_install "gcc-$GCC_VER$HOST_ARCH_SUFFIX"
	fi
	compiler="`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-gcc-$GCC_VER"
	if ! command -v "$compiler" >/dev/null; then echo "$compiler missing in stage1 gcc package"; exit 1; fi
	if ! drop_privs "$compiler" -x c -c /dev/null -o test.o; then echo "stage1 gcc fails to execute"; exit 1; fi
	if ! test -f test.o; then echo "stage1 gcc fails to create binaries"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	touch "$REPODIR/stamps/gcc_1"
	cd ..
	drop_privs rm -Rf gcc1
fi
progress_mark "cross gcc stage1 build"

# replacement for cross-gcc-defaults
for prog in c++ cpp g++ gcc gcc-ar gcc-ranlib gfortran; do
	ln -fs "`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-$prog-$GCC_VER" "/usr/bin/`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-$prog"
done

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/hurd_1"; then
	echo "skipping rebuild of hurd stage1"
else
	cross_build_setup hurd hurd_1
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P stage1 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/hurd_1"
	cd ..
	drop_privs rm -Rf hurd_1
fi
progress_mark "hurd stage1 cross build"
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/mig_1"; then
	echo "skipping rebuild of mig cross"
else
	cross_build_setup mig mig_1
	apt_get_install dpkg-dev debhelper dh-exec dh-autoreconf "gnumach-dev:$HOST_ARCH" flex libfl-dev bison
	drop_privs dpkg-buildpackage -d -B "--target-arch=$HOST_ARCH" -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/mig_1"
	cd ..
	drop_privs rm -Rf mig_1
fi
progress_mark "cross mig build"
fi

# we'll have to remove build arch multilibs to be able to install host arch multilibs
apt_get_remove $(dpkg-query -W "libc[0-9]*-*:$(dpkg --print-architecture)" | sed "s/\\s.*//;/:$(dpkg --print-architecture)/d")

case "$HOST_ARCH" in
	musl-linux-*) LIBC_NAME=musl ;;
	*) LIBC_NAME=glibc ;;
esac
if test -f "$REPODIR/stamps/${LIBC_NAME}_2"; then
	echo "skipping rebuild of $LIBC_NAME stage2"
else
	cross_build_setup "$LIBC_NAME" "${LIBC_NAME}_2"
	if dpkg-architecture "-a$HOST_ARCH" -ignu-any-any; then
		"$(get_hook builddep glibc)" "$HOST_ARCH" stage2
	else
		apt_get_build_dep "-a$HOST_ARCH" --arch-only ./
	fi
	(
		profiles=$(join_words , $DEFAULT_PROFILES)
		if dpkg-architecture "-a$HOST_ARCH" -ignu-any-any; then
			profiles="$profiles,stage2"
			test "$ENABLE_MULTILIB" != yes && profiles="$profiles,nobiarch"
			buildenv_glibc
		fi
		# tell unmet build depends
		drop_privs dpkg-checkbuilddeps -B "-a$HOST_ARCH" "-P$profiles" || :
		drop_privs_exec dpkg-buildpackage -B -uc -us "-a$HOST_ARCH" -d "-P$profiles" || buildpackage_failed "$?"
	)
	cd ..
	ls -l
	if dpkg-architecture "-a$HOST_ARCH" -imusl-any-any; then
		pickup_packages *.changes
		dpkg -i musl*.deb
	else
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			pickup_packages *.changes
			dpkg -i libc[0-9]*.deb
		else
			for pkg in libc[0-9]*.deb; do
				# dpkg-cross cannot handle these
				test "${pkg%%_*}" = "libc6-xen" && continue
				test "${pkg%%_*}" = "libc6.1-alphaev67" && continue
				drop_privs dpkg-cross -M -a "$HOST_ARCH" -X tzdata -X libc-bin -X libc-dev-bin -X multiarch-support -b "$pkg"
			done
			pickup_packages *.changes ./*-cross_*.deb
			dpkg -i libc[0-9]*-cross_*.deb
		fi
	fi
	touch "$REPODIR/stamps/${LIBC_NAME}_2"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf "${LIBC_NAME}_2"
fi
progress_mark "$LIBC_NAME stage2 cross build"

if test -f "$REPODIR/stamps/gcc_3"; then
	echo "skipping rebuild of gcc stage3"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev dejagnu systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" time
	if test "$HOST_ARCH" = hppa; then
		apt_get_install binutils-hppa64-linux-gnu
	fi
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		apt_get_install "libc-dev:$HOST_ARCH" $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1:$HOST_ARCH/g")
	else
		if dpkg-architecture "-a$HOST_ARCH" -ignu-any-any; then
			apt_get_install "libc6-dev-$HOST_ARCH-cross" $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1-$HOST_ARCH-cross/g")
		elif dpkg-architecture "-a$HOST_ARCH" -imusl-any-any; then
			apt_get_install "musl-dev-$HOST_ARCH-cross"
		fi
	fi
	cross_build_setup "gcc-$GCC_VER" gcc3
	check_binNMU
	dpkg-checkbuilddeps -a$HOST_ARCH || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			export with_deps_on_target_arch_pkgs=yes
		else
			export WITH_SYSROOT=/
		fi
		export gcc_cv_libc_provides_ssp=yes
		export gcc_cv_initfini_array=yes
		drop_privs dpkg-buildpackage -d -T control
		drop_privs dpkg-buildpackage -d -T clean
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		drop_privs changestool ./*.changes dumbremove "gcc-${GCC_VER}-base_"*"_$(dpkg --print-architecture).deb"
		drop_privs rm "gcc-${GCC_VER}-base_"*"_$(dpkg --print-architecture).deb"
	fi
	pickup_packages *.changes
	# avoid file conflicts between differently staged M-A:same packages
	apt_get_remove "gcc-$GCC_VER-base:$HOST_ARCH"
	drop_privs rm -fv gcc-*-plugin-*.deb gcj-*.deb gdc-*.deb ./*objc*.deb ./*-dbg_*.deb
	dpkg -i *.deb
	compiler="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-gcc-$GCC_VER"
	if ! command -v "$compiler" >/dev/null; then echo "$compiler missing in stage3 gcc package"; exit 1; fi
	if ! drop_privs "$compiler" -x c -c /dev/null -o test.o; then echo "stage3 gcc fails to execute"; exit 1; fi
	if ! test -f test.o; then echo "stage3 gcc fails to create binaries"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	mkdir -p "/usr/include/$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_MULTIARCH)"
	touch /usr/include/`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_MULTIARCH`/include_path_test_header.h
	preproc="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-cpp-$GCC_VER"
	if ! echo '#include "include_path_test_header.h"' | drop_privs "$preproc" -E -; then echo "stage3 gcc fails to search /usr/include/<triplet>"; exit 1; fi
	touch "$REPODIR/stamps/gcc_3"
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		compare_native ./*.deb
	fi
	cd ..
	drop_privs rm -Rf gcc3
fi
progress_mark "cross gcc stage3 build"

if test "$ENABLE_MULTIARCH_GCC" != yes; then
if test -f "$REPODIR/stamps/gcc_f1"; then
	echo "skipping rebuild of gcc rtlibs"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev dejagnu systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" "libc-dev:$HOST_ARCH" time
	if test "$HOST_ARCH" = hppa; then
		apt_get_install binutils-hppa64-linux-gnu
	fi
	if test "$ENABLE_MULTILIB" = yes -a -n "$MULTILIB_NAMES"; then
		apt_get_install $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1-$HOST_ARCH-cross libc6-dev-\1:$HOST_ARCH/g")
	fi
	cross_build_setup "gcc-$GCC_VER" gcc_f1
	check_binNMU
	dpkg-checkbuilddeps || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		export DEB_STAGE=rtlibs
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		export WITH_SYSROOT=/
		drop_privs dpkg-buildpackage -d -T control
		cat debian/control
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	rm -vf "gcc-$GCC_VER-base_"*"_$(dpkg --print-architecture).deb"
	pickup_additional_packages *.deb
	$APT_GET dist-upgrade
	dpkg -i ./*.deb
	touch "$REPODIR/stamps/gcc_f1"
	cd ..
	drop_privs rm -Rf gcc_f1
fi
progress_mark "gcc cross rtlibs build"
fi

# install something similar to crossbuild-essential
apt_get_install "binutils$HOST_ARCH_SUFFIX" "gcc-$GCC_VER$HOST_ARCH_SUFFIX" "g++-$GCC_VER$HOST_ARCH_SUFFIX" "libc-dev:$HOST_ARCH"

apt_get_remove libc6-i386 # breaks cross builds

if dpkg-architecture "-a$HOST_ARCH" -ihurd-any; then
if test -f "$REPODIR/stamps/hurd_2"; then
	echo "skipping rebuild of hurd stage2"
else
	cross_build_setup hurd hurd_2
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P stage2 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage2 -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/hurd_2"
	cd ..
	drop_privs rm -Rf hurd_2
fi
apt_get_install "hurd-dev:$HOST_ARCH"
progress_mark "hurd stage3 cross build"
fi

apt_get_install dose-builddebcheck dctrl-tools

call_dose_builddebcheck() {
	local package_list source_list errcode
	package_list=`mktemp packages.XXXXXXXXXX`
	source_list=`mktemp sources.XXXXXXXXXX`
	cat /var/lib/apt/lists/*_Packages - > "$package_list" <<EOF
Package: crossbuild-essential-$HOST_ARCH
Version: 0
Architecture: $HOST_ARCH
Multi-Arch: foreign
Depends: libc-dev
Description: fake crossbuild-essential package for dose-builddebcheck

EOF
	sed -i -e '/^Conflicts:.* libc[0-9][^ ]*-dev\(,\|$\)/d' "$package_list" # also make dose ignore the glibc conflict
	apt-cache show "gcc-${GCC_VER}-base=installed" libgcc-s1=installed libstdc++6=installed libatomic1=installed >> "$package_list" # helps when pulling gcc from experimental
	cat /var/lib/apt/lists/*_Sources > "$source_list"
	errcode=0
	dose-builddebcheck --deb-tupletable=/usr/share/dpkg/tupletable --deb-cputable=/usr/share/dpkg/cputable "--deb-native-arch=$(dpkg --print-architecture)" "--deb-host-arch=$HOST_ARCH" "$@" "$package_list" "$source_list" || errcode=$?
	if test "$errcode" -gt 1; then
		echo "dose-builddebcheck failed with error code $errcode" 1>&2
		exit 1
	fi
	rm -f "$package_list" "$source_list"
}

# determine whether a given binary package refers to an arch:all package
# $1 is a binary package name
is_arch_all() {
	grep-dctrl -P -X "$1" -a -F Architecture all -s /var/lib/apt/lists/*_Packages
}

# determine which source packages build a given binary package
# $1 is a binary package name
# prints a set of source packages
what_builds() {
	local newline pattern source
	newline='
'
	pattern=`echo "$1" | sed 's/[+.]/\\\\&/g'`
	pattern="$newline $pattern "
	# exit codes 0 and 1 signal successful operation
	source=`grep-dctrl -F Package-List -e "$pattern" -s Package -n /var/lib/apt/lists/*_Sources || test "$?" -eq 1`
	set_create "$source"
}

# determine a set of source package names which are essential to some
# architecture
discover_essential() {
	set_create "$(grep-dctrl -F Package-List -e '\bessential=yes\b' -s Package -n /var/lib/apt/lists/*_Sources)"
}

need_packages=
add_need() { need_packages=`set_add "$need_packages" "$1"`; }
built_packages=
mark_built() {
	need_packages=`set_discard "$need_packages" "$1"`
	built_packages=`set_add "$built_packages" "$1"`
}

for pkg in $(discover_essential); do
	if set_contains "$automatic_packages" "$pkg"; then
		echo "rebootstrap-debug: automatically scheduling essential package $pkg"
		add_need "$pkg"
	else
		echo "rebootstrap-debug: not scheduling essential package $pkg"
	fi
done
add_need acl # by coreutils, systemd
add_need apt # almost essential
add_need attr # by coreutils, libcap-ng
add_need blt # by pythonX.Y
add_need bsdmainutils # for man-db
add_need bzip2 # by perl
add_need db-defaults # by perl, python3.X
add_need expat # by unbound
add_need file # by gcc-6, for debhelper
add_need flex # by pam
add_need fribidi # by newt
add_need gnupg2 # for apt
test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux && add_need gpm # by ncurses
add_need groff # for man-db
test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux && add_need kmod # by systemd
add_need icu # by libxml2
add_need krb5 # by audit
test "$HOST_ARCH" = ia64 && add_need libatomic-ops # by gcc-VER
dpkg-architecture "-a$HOST_ARCH" -ilinux-any && add_need libcap2 # by systemd
add_need libdebian-installer # by cdebconf
add_need libevent # by unbound
add_need libidn2 # by gnutls28
add_need libgcrypt20 # by libprelude, cryptsetup
dpkg-architecture "-a$HOST_ARCH" -ilinux-any && add_need libsepol # by libselinux
if dpkg-architecture "-a$HOST_ARCH" -ihurd-any; then
	add_need libsystemd-dummy # by nghttp2
fi
add_need libtasn1-6 # by gnutls28
add_need libtextwrap # by cdebconf
add_need libunistring # by gnutls28
add_need libxcrypt # by cyrus-sasl2, pam, shadow, systemd
add_need libxrender # by cairo
add_need libzstd # by systemd
add_need lz4 # by systemd
add_need make-dfsg # for build-essential
add_need man-db # for debhelper
add_need mawk # for base-files (alternatively: gawk)
add_need mpclib3 # by gcc-VER
add_need mpfr4 # by gcc-VER
add_need nettle # by unbound, gnutls28
add_need openssl # by cyrus-sasl2
add_need p11-kit # by gnutls28
add_need patch # for dpkg-dev
add_need pcre2 # by libselinux
add_need popt # by newt
add_need slang2 # by cdebconf, newt
add_need sqlite3 # by python3.X
add_need tcl8.6 # by newt
add_need tcltk-defaults # by python3.X
add_need tcp-wrappers # by audit
add_need xz-utils # by libxml2

automatically_cross_build_packages() {
	local dosetmp profiles buildable new_needed line pkg missing source
	while test -n "$need_packages"; do
		echo "checking packages with dose-builddebcheck: $need_packages"
		dosetmp=`mktemp -t doseoutput.XXXXXXXXXX`
		profiles="$DEFAULT_PROFILES"
		if test "$ENABLE_MULTILIB" = no; then
			profiles=$(set_add "$profiles" nobiarch)
		fi
		call_dose_builddebcheck --successes --failures --explain --latest=1 --deb-drop-b-d-indep "--deb-profiles=$(join_words , $profiles)" "--checkonly=$(join_words , $need_packages)" >"$dosetmp"
		buildable=
		new_needed=
		while IFS= read -r line; do
			case "$line" in
				"  package: "*)
					pkg=${line#  package: }
					pkg=${pkg#src:} # dose3 << 4.1
				;;
				"  status: ok")
					buildable=`set_add "$buildable" "$pkg"`
				;;
				"      unsat-dependency: "*)
					missing=${line#*: }
					missing=${missing%% | *} # drop alternatives
					missing=${missing% (* *)} # drop version constraint
					missing=${missing%:$HOST_ARCH} # skip architecture
					if is_arch_all "$missing"; then
						echo "rebootstrap-warning: $pkg misses dependency $missing which is arch:all"
					else
						source=`what_builds "$missing"`
						case "$source" in
							"")
								echo "rebootstrap-warning: $pkg transitively build-depends on $missing, but no source package could be determined"
							;;
							*" "*)
								echo "rebootstrap-warning: $pkg transitively build-depends on $missing, but it is build from multiple source packages: $source"
							;;
							*)
								if set_contains "$built_packages" "$source"; then
									echo "rebootstrap-warning: $pkg transitively build-depends on $missing, which is built from $source, which is supposedly already built"
								elif set_contains "$need_packages" "$source"; then
									echo "rebootstrap-debug: $pkg transitively build-depends on $missing, which is built from $source and already scheduled for building"
								elif set_contains "$automatic_packages" "$source"; then
									new_needed=`set_add "$new_needed" "$source"`
								else
									echo "rebootstrap-warning: $pkg transitively build-depends on $missing, which is built from $source but not automatic"
								fi
							;;
						esac
					fi
				;;
			esac
		done < "$dosetmp"
		rm "$dosetmp"
		echo "buildable packages: $buildable"
		echo "new packages needed: $new_needed"
		test -z "$buildable" -a -z "$new_needed" && break
		for pkg in $buildable; do
			echo "cross building $pkg"
			cross_build "$pkg"
			mark_built "$pkg"
		done
		need_packages=`set_union "$need_packages" "$new_needed"`
	done
	echo "done automatically cross building packages. left: $need_packages"
}

assert_built() {
	local missing_pkgs profiles
	missing_pkgs=`set_difference "$1" "$built_packages"`
	test -z "$missing_pkgs" && return 0
	echo "rebootstrap-error: missing asserted packages: $missing_pkgs"
	missing_pkgs=`set_union "$missing_pkgs" "$need_packages"`
	profiles="$DEFAULT_PROFILES"
	if test "$ENABLE_MULTILIB" = no; then
		profiles=$(set_add "$profiles" nobiarch)
	fi
	call_dose_builddebcheck --failures --explain --latest=1 --deb-drop-b-d-indep "--deb-profiles=$(join_words , $profiles)" "--checkonly=$(join_words , $missing_pkgs)"
	return 1
}

automatically_cross_build_packages

cross_build zlib "$(if test "$ENABLE_MULTILIB" != yes; then echo stage1; fi)"
mark_built zlib
# needed by dpkg, file, gnutls28, libpng1.6, libtool, libxml2, perl, slang2, tcl8.6, util-linux

automatically_cross_build_packages

cross_build libtool
mark_built libtool
# needed by guile-X.Y, libffi

automatically_cross_build_packages

cross_build ncurses
mark_built ncurses
# needed by bash, bsdmainutils, dpkg, guile-X.Y, readline, slang2

automatically_cross_build_packages

cross_build readline
mark_built readline
# needed by gnupg2, guile-X.Y, libxml2

automatically_cross_build_packages

if dpkg-architecture "-a$HOST_ARCH" -ilinux-any; then
	assert_built "libsepol pcre2"
	cross_build libselinux "nopython noruby" libselinux_1
	mark_built libselinux
# needed by coreutils, dpkg, findutils, glibc, sed, tar, util-linux

automatically_cross_build_packages
fi # $HOST_ARCH matches linux-any

dpkg-architecture "-a$HOST_ARCH" -ilinux-any && assert_built libselinux
assert_built "ncurses zlib"
cross_build util-linux "stage1 pkg.util-linux.noverity" util-linux_1
mark_built util-linux
# essential, needed by e2fsprogs

automatically_cross_build_packages

cross_build db5.3 "pkg.db5.3.notcl nojava" db5.3_1
mark_built db5.3
# needed by perl, python3.X, needed for db-defaults

automatically_cross_build_packages

cross_build libxml2 nopython libxml2_1
mark_built libxml2
# needed by nghttp2

automatically_cross_build_packages

cross_build cracklib2 nopython cracklib2_1
mark_built cracklib2
# needed by pam

automatically_cross_build_packages

cross_build build-essential
mark_built build-essential
# build-essential

automatically_cross_build_packages

cross_build pam stage1 pam_1
mark_built pam
# needed by shadow

automatically_cross_build_packages

assert_built "db-defaults db5.3 pam sqlite3 openssl"
cross_build cyrus-sasl2 "pkg.cyrus-sasl2.nogssapi pkg.cyrus-sasl2.noldap pkg.cyrus-sasl2.nosql" cyrus-sask2_1
mark_built cyrus-sasl2
# needed by openldap

automatically_cross_build_packages

assert_built "libevent expat nettle"
dpkg-architecture "-a$HOST_ARCH" -ilinux-any || assert_built libbsd
cross_build unbound pkg.unbound.libonly unbound_1
mark_built unbound
# needed by gnutls28

automatically_cross_build_packages

mark_built gmp
assert_built "gmp libidn2 p11-kit libtasn1-6 unbound libunistring nettle"
cross_build gnutls28 noguile gnutls28_1
mark_built gnutls28
# needed by libprelude, openldap, curl

automatically_cross_build_packages

assert_built "gnutls28 cyrus-sasl2"
cross_build openldap pkg.openldap.noslapd openldap_1
mark_built openldap
# needed by curl

automatically_cross_build_packages

if apt-cache showsrc systemd | grep -q "^Build-Depends:.*gnu-efi[^,]*[[ ]$HOST_ARCH[] ]"; then
cross_build gnu-efi
mark_built gnu-efi
# needed by systemd

automatically_cross_build_packages
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
if apt-cache showsrc man-db systemd | grep -q "^Build-Depends:.*libseccomp-dev[^,]*[[ ]$HOST_ARCH[] ]"; then
	cross_build libseccomp nopython libseccomp_1
	mark_built libseccomp
# needed by man-db, systemd

	automatically_cross_build_packages
fi


assert_built "libcap2 pam libselinux acl xz-utils libgcrypt20 kmod util-linux libzstd"
if apt-cache showsrc systemd | grep -q "^Build-Depends:.*libseccomp-dev[^,]*[[ ]$HOST_ARCH[] ]" debian/control; then
	assert_built libseccomp
fi
cross_build systemd stage1 systemd_1
mark_built systemd
# needed by util-linux

automatically_cross_build_packages

assert_built attr
cross_build libcap-ng nopython libcap-ng_1
mark_built libcap-ng
# needed by audit

automatically_cross_build_packages

assert_built "gnutls28 libgcrypt20 libtool"
cross_build libprelude "nolua noperl nopython noruby" libprelude_1
mark_built libprelude
# needed by audit

automatically_cross_build_packages

assert_built "zlib bzip2 xz-utils"
cross_build elfutils pkg.elfutils.nodebuginfod
mark_built elfutils
# needed by glib2.0

automatically_cross_build_packages

assert_built "libcap-ng krb5 openldap libprelude tcp-wrappers"
cross_build audit nopython audit_1
mark_built audit
# needed by libsemanage

automatically_cross_build_packages

assert_built "audit bzip2 libselinux libsepol"
cross_build libsemanage "nocheck nopython noruby" libsemanage_1
mark_built libsemanage
# needed by shadow

automatically_cross_build_packages
fi # $HOST_ARCH matches linux-any

dpkg-architecture "-a$HOST_ARCH" -ilinux-any && assert_built "audit libcap-ng libselinux systemd"
assert_built "ncurses zlib"
cross_build util-linux "pkg.util-linux.noverity"
# essential

automatically_cross_build_packages

cross_build brotli nopython brotli_1
mark_built brotli
# needed by curl

automatically_cross_build_packages

cross_build gdbm pkg.gdbm.nodietlibc gdbm_1
mark_built gdbm
# needed by man-db, perl, python3.X

# rv32 
mark_built perl

automatically_cross_build_packages

cross_build newt nopython newt_1
mark_built newt
# needed by cdebconf

automatically_cross_build_packages

cross_build cdebconf pkg.cdebconf.nogtk cdebconf_1
mark_built cdebconf
# needed by base-passwd

automatically_cross_build_packages

if test -f "$REPODIR/stamps/binutils_2"; then
	echo "skipping cross rebuild of binutils"
else
	cross_build_setup binutils binutils_2
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P nocheck ./
	check_binNMU
	DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS nocross nomult" drop_privs dpkg-buildpackage "-a$HOST_ARCH" -Pnocheck -B -uc -us
	rm -Rf /tmp/nodebugedit
	cd ..
	ls -l
	drop_privs sed -i -e '/^ .* binutils-for-host_.*deb$/d' ./*.changes
	pickup_additional_packages *.changes
	touch "$REPODIR/stamps/binutils_2"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf binutils_2
fi
progress_mark "cross build binutils"
mark_built binutils
# needed for build-essential

automatically_cross_build_packages

assert_built "$need_packages"

echo "checking installability of build-essential with dose"
apt_get_install botch
package_list=$(mktemp -t packages.XXXXXXXXXX)
grep-dctrl --exact --field Architecture '(' "$HOST_ARCH" --or all ')' /var/lib/apt/lists/*_Packages > "$package_list"
botch-distcheck-more-problems "--deb-native-arch=$HOST_ARCH" --successes --failures --explain --checkonly "build-essential:$HOST_ARCH" "--bg=deb://$package_list" "--fg=deb://$package_list" || :
rm -f "$package_list"
