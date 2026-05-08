#!/bin/sh
cd $(dirname "$0")
#export DESC=`git describe --abbrev=0`
#export COUNT=`git rev-list $DESC..HEAD --count`
#export HASH=`git rev-parse --short HEAD`
#if [ $COUNT -eq 0 ] ; then
#	export GIT_VERSION=$DESC
#else
#	export GIT_VERSION=$DESC.$COUNT+$HASH
#fi
export BUILDINFO_BRANCH=`git rev-parse --abbrev-ref HEAD`
export BUILDINFO_COMMIT=`git rev-parse --short=8 HEAD`
export BUILDINFO_TIMESTAMP=`date +"%Y-%m-%d %H:%M:%S"`
echo "let BUILDINFO_BRANCH = \"$BUILDINFO_BRANCH\"\rlet BUILDINFO_COMMIT = \"$BUILDINFO_COMMIT\"\rlet BUILDINFO_TIMESTAMP = \"$BUILDINFO_TIMESTAMP\""

# xcrun agvtool new-marketing-version
# xcrun agvtool bump

