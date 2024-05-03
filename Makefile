GIT_TAG?=$(shell git describe --abbrev=0 --tags 2>/dev/null || echo "v0.0.0" )
VERSION?=$(shell echo $(GIT_TAG) | sed 's/[a-z]*\([0-9]\(\.[0-9]\)\{0,2\}\).*/\1/g')-dev

version:
	sed -i 's/^VERSION=.*/VERSION="$(VERSION)"/' elemental-*
	sed -i 's/^VERSION=.*/VERSION="$(VERSION)"/' leapmicrok3s.sh
