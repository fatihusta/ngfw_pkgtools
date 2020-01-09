# default shell
SHELL := /bin/bash
shell := /bin/bash

# pwd of this Makefile
PKGTOOLS_DIR := $(shell dirname $(MAKEFILE_LIST))

# overridables
DISTRIBUTION ?= $(USER)
DISTRIBUTION_FROM ?= $(DISTRIBUTION)
ARCH ?= $(shell dpkg-architecture -qDEB_BUILD_ARCH)
PACKAGE_SERVER ?= package-server
REPOSITORY ?= stretch
TIMESTAMP ?= $(shell date "+%Y-%m-%dT%H%M%S_%N")
DPUT_METHOD ?= ftp

# binary upload
ifneq ($(origin RECURSIVE), undefined)
  REC := -a
endif

# debuild/dpkg-buildpackage options
DEBUILD_OPTIONS := 
DPKGBUILDPACKAGE_OPTIONS := -i -us -uc
ifeq ($(origin BINARY_UPLOAD), undefined)
  DPKGBUILDPACKAGE_OPTIONS += -sa
else
  DPKGBUILDPACKAGE_OPTIONS += -B
endif

# CC options
CCACHE_DISABLE := true
export CCACHE_DISABLE
CCACHE_DIR := /tmp
export CCACHE_DIR

# cwd
CUR_DIR := $(shell basename `pwd`)

# destination dir for the debian files (dsc, changes, etc)
DEST_DIR := $(shell echo /tmp/$(REPOSITORY)-$${PPID})

# current package to build
SOURCE_NAME := $(shell dpkg-parsechangelog 2> /dev/null | awk '/^Source:/{print $$2}')
VERSION_FILE := debian/version
DESTDIR_FILE := debian/destdir

# new-style source package
SOURCE_CONF := source.conf

# chroot stuff
CHROOT_DIR := /var/cache/pbuilder
CHROOT_BUILD_KERNEL_MODULE := $(PKGTOOLS_DIR)/chroot-build-kernel-module.sh
CHROOT_UPDATE_SCRIPT := $(PKGTOOLS_DIR)/chroot-update.sh
CHROOT_UPDATE_EXISTENCE_SCRIPT := $(PKGTOOLS_DIR)/chroot-update-existence.sh
CHROOT_CHECK_PACKAGE_VERSION_SCRIPT := $(PKGTOOLS_DIR)/chroot-check-for-package-version.sh
CHROOT_BASE := $(CHROOT_DIR)/$(REPOSITORY)+untangle_$(ARCH)
CHROOT_ORIG := $(CHROOT_BASE).cow
CHROOT_WORK := $(CHROOT_BASE)_$(TIMESTAMP).cow
CHROOT_EXISTENCE := $(CHROOT_BASE)_$(TIMESTAMP)_existence.cow

########################################################################
# Rules
.PHONY: checkroot create-dest-dir revert-changelog parse-changelog move-debian-files clean-debian-files clean-chroot-files clean-build clean version-real version check-existence source pkg-real pkg pkg-chroot-real pkg-chroot release release-deb create-existence-chroot remove-existence-chroot remove-chroot create-chroot upgrade-base-chroot get-upstream-source

checkroot:
	@if [ "$$UID" = "0" ] ; then \
	  echo "You can't be root to build packages"; \
	fi

create-dest-dir:
	@mkdir -p $(DEST_DIR)
	@rm -fr $(DEST_DIR)/*
	@echo $(DEST_DIR) >| $(DESTDIR_FILE)

revert-changelog: # do not leave it locally modified
	@svn revert debian/changelog > /dev/null 2>&1 || git checkout -- debian/changelog 2>&1 || true

parse-changelog: # store version so we can use that later for uploading
	@dpkg-parsechangelog | awk '/Version:/{print $$2}' >| $(VERSION_FILE)

move-debian-files:
	@find .. -maxdepth 1 -name "*`perl -pe 's/^.+://' $(VERSION_FILE)`*" -regex '.*\.\(upload\|changes\|udeb\|deb\|upload\|dsc\|build\|diff\.gz\|debian\.tar\.xz\|buildinfo\)' -exec mv "{}" `cat $(DESTDIR_FILE)` \;
	@find .. -maxdepth 1 -name "*`perl -pe 's/^.+:// ; s/-.*//' $(VERSION_FILE)`*orig.tar.gz" -exec mv "{}" `cat $(DESTDIR_FILE)` \;

clean-build: checkroot
	@fakeroot debian/rules clean
	@quilt pop -a || true
	@echo "Attempting to remove older *.deb files"
	find . -type f -regex '\(.*-modules?-3.\(2\|16\).0-4.*\.deb\|core\)' -exec rm -f "{}" \;

clean-untangle-files: revert-changelog
	@rm -fr `cat $(DESTDIR_FILE) 2> /dev/null`
	@rm -f $(VERSION_FILE) $(DESTDIR_FILE)
clean-debian-files:
	@if [ -f $(DESTDIR_FILE) ] && [ -d `cat $(DESTDIR_FILE)` ] ; then \
	  find `cat $(DESTDIR_FILE)` -maxdepth 1 -name "*`perl -pe 's/^.+://' $(VERSION_FILE)`*" -regex '.*\.\(changes\|deb\|upload\|dsc\|build\|diff\.gz\)' -exec rm -f "{}" \; ; \
	  find `cat $(DESTDIR_FILE)` -maxdepth 1 -name "*`perl -pe 's/^.+:// ; s/-.*//' $(VERSION_FILE)`*orig.tar.gz" -exec rm -f "{}" \; ; \
	fi

get-upstream-source:
	source $(SOURCE_CONF) ; \
	rm -fr $${package}* ; \
	apt-get source $${binary_package} ; \
	dir=$$(ls -d $${package}*/) ; \
	touch $${dir}/$${versioning}

clean-chroot-files: clean-debian-files clean-untangle-files

clean: clean-chroot-files clean-build remove-chroot remove-existence-chroot

version-real: checkroot
	bash $(PKGTOOLS_DIR)/set-version.sh $(DISTRIBUTION) VERSION=$(VERSION) REPOSITORY=$(REPOSITORY)
version: version-real parse-changelog

create-existence-chroot:
	if [ ! -d $(CHROOT_EXISTENCE) ] ; then \
	  sudo cp -a $(CHROOT_ORIG) $(CHROOT_EXISTENCE) ; \
	  sudo /usr/sbin/cowbuilder --execute --save-after-exec --basepath $(CHROOT_EXISTENCE) -- $(CHROOT_UPDATE_EXISTENCE_SCRIPT) $(REPOSITORY) $(DISTRIBUTION) ; \
	  sudo cp -f $(CHROOT_CHECK_PACKAGE_VERSION_SCRIPT) $(CHROOT_EXISTENCE) ; \
        fi
remove-existence-chroot:
	sudo rm -fr $(CHROOT_EXISTENCE)
check-existence: create-existence-chroot
	if [ $(ARCH) = "amd64" ] ; then \
	  dh_switch="" ; \
	else \
	  dh_switch="-a" ; \
	fi ; \
	packageName=`dh_listpackages $${dh_switch} | tail -1` ;\
	sudo /usr/sbin/chroot $(CHROOT_EXISTENCE) /$(shell basename $(CHROOT_CHECK_PACKAGE_VERSION_SCRIPT)) "$${packageName}" $(shell cat $(VERSION_FILE)) $(REPOSITORY) $(DISTRIBUTION)

source: checkroot parse-changelog
	quilt pop -a || true
	tar cz --exclude="*stamp*.txt" \
	       --exclude="*-stamp" \
	       --exclude=".svn" --exclude="./debian" \
	       --exclude="todo" --exclude="staging" --exclude=".git" \
	       -f ../$(SOURCE_NAME)_`dpkg-parsechangelog | awk '/^Version:/{gsub(/(^.+:|-.*)/, "", $$2) ; print $$2}'`.orig.tar.gz ../$(CUR_DIR)

pkg-real: checkroot parse-changelog
	/usr/bin/debuild $(DEBUILD_OPTIONS) $(DPKGBUILDPACKAGE_OPTIONS)
pkg: create-dest-dir pkg-real move-debian-files

upgrade-base-chroot:
	sudo /usr/sbin/cowbuilder --execute --basepath $(CHROOT_ORIG) --save-after-exec -- $(CHROOT_UPDATE_SCRIPT)

create-chroot:
	if [ ! -d $(CHROOT_WORK) ] ; then \
          sudo rm -fr $(CHROOT_WORK) ; \
          sudo cp -a $(CHROOT_ORIG) $(CHROOT_WORK) ; \
          sudo /usr/sbin/cowbuilder --execute --save-after-exec --basepath $(CHROOT_WORK) -- $(CHROOT_UPDATE_SCRIPT) $(REPOSITORY) $(DISTRIBUTION) ; \
          touch ~/.pbuilderrc ; \
        fi
remove-chroot:
	sudo rm -fr $(CHROOT_WORK)
pkg-chroot-real: checkroot parse-changelog create-dest-dir
	# if we depend on an untangle-* package, or on
	# libdebconfclient0-dev, or on libpixman-1-dev, or on
	# libnetfilter-queue-dev, or on libnftnl-dev, we want to apt-get update to get the
	# latest available version (that might have been uploaded
	# during the current make-build.sh run)
	if grep-dctrl -s Build-Depends -e '(untangle|libdebconfclient0-dev|libpixman-1-dev|libnetfilter-queue-dev|libdaq-dev|libnftnl-dev)' debian/control ; then \
          sudo /usr/sbin/cowbuilder --execute --save-after-exec --basepath $(CHROOT_WORK) -- $(CHROOT_UPDATE_SCRIPT) $(REPOSITORY) $(DISTRIBUTION) ; \
        fi
	pdebuild --pbuilder /usr/sbin/cowbuilder \
		 --buildresult `cat $(DESTDIR_FILE)` \
	         --debbuildopts "$(DPKGBUILDPACKAGE_OPTIONS)" -- \
	         --basepath $(CHROOT_WORK)

pkg-chroot: create-dest-dir create-chroot pkg-chroot-real # move-debian-files

kernel-module-chroot-real: checkroot parse-changelog create-dest-dir
	sudo /usr/sbin/cowbuilder --execute --save-after-exec --basepath $(CHROOT_WORK) -- $(CHROOT_BUILD_KERNEL_MODULE) $(SOURCE_NAME)
	cp -f $(CHROOT_WORK)/usr/src/*deb .
kernel-module-chroot: create-dest-dir create-chroot kernel-module-chroot-real

release:
	dput -c $(PKGTOOLS_DIR)/dput.cf $(PACKAGE_SERVER)_$(REPOSITORY)_$(DPUT_METHOD) `cat $(DESTDIR_FILE)`/$(SOURCE_NAME)_`perl -pe 's/^.+://' $(VERSION_FILE)`*.changes

release-deb:
	$(PKGTOOLS_DIR)/release-binary-packages.sh -A $(ARCH) -r $(REPOSITORY) -d $(DISTRIBUTION) $(REC)

copy-src:
	$(PKGTOOLS_DIR)/copy-src-package.sh -r $(REPOSITORY) -p $(SOURCE_NAME) $(DISTRIBUTION_FROM) $(DISTRIBUTION)
