######################################################
# Setup some high-level global settings.

#XXX Need targets for checking for debian and kernel security vulns, respin image.

#XXX Add support for (cross) building patched upstream, patched tar.gz, and
#    and local git trees.  Perhaps a list of things to build in ../?
#XXX Do we even need to cross build anything other than containers?  How
#    valuable is the seperation between build env and run env provided by .deb?

#XXX Turn the http:// URLs into https:// if we can fix apt-cacher-ng to work with them.

SHELL=/bin/bash #tarfile signature checking uses process redirection.

DEBIAN_RELEASE := stretch

KERNEL_VERSION = 5.8.13
FIRMWARE_VERSION = 20200918
UBOOT_VERSION = 2020.10
BOOTFW_VERSION = 1.20200902
BUSYBOX_VERSION = 1.28.0-uclibc
ZEROTIER1_VERSION = 1.2.12

KERNEL_URL=http://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$(KERNEL_VERSION).tar.xz
FIRMWARE_URL=https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-$(FIRMWARE_VERSION).tar.xz
UBOOT_URL=http://ftp.denx.de/pub/u-boot/u-boot-$(UBOOT_VERSION).tar.bz2
BOOTFW_URL=http://github.com/raspberrypi/firmware/archive/$(BOOTFW_VERSION).tar.gz
ZEROTIER1_URL=http://github.com/zerotier/ZeroTierOne/archive/$(ZEROTIER1_VERSION).tar.gz

######################################################
# Pick/validate what target architectures we're building for.

#If we're building a specific image, automatically set the ARCH based on that.
ARCHS := #Needed so ARCHS+=$(ARCH) expands $(ARCH) immediately, not recursively.
ARM_TARGETS:=rpi3_img rpi3_zip rpi3_img_clean rpi3_zip_clean
ifneq ($(filter $(ARM_TARGETS), $(MAKECMDGOALS)),)
override ARCH:=arm64
ARCHS+=$(ARCH)
endif
AMD64_TARGETS:=pc_img pc_zip pc_img_clean pc_zip_clean
ifneq ($(filter $(AMD64_TARGETS), $(MAKECMDGOALS)),)
override ARCH:=amd64
ARCHS+=$(ARCH)
endif

ifeq ($(ARCH),)
$(error ARCH not set, either implicitly by an PLATFORM_img goal, or explicitly)
else ifeq ($(ARCH), armhf)
KERNEL_ARCH=arm
KERNEL_IMG=zImage
KERNEL_EXTRAS=dtbs
UBOOT_ARCH=arm
UBOOT_IMG=u-boot.bin
CROSS_PREFIX=arm-linux-gnueabihf-
FROM_PREFIX=arm32v7/
QEMU_ARCH=arm
else ifeq ($(ARCH), arm64)
KERNEL_ARCH=arm64
KERNEL_IMG=Image
KERNEL_EXTRAS=dtbs
UBOOT_ARCH=arm
UBOOT_IMG=u-boot.bin
CROSS_PREFIX=aarch64-linux-gnu-
FROM_PREFIX=arm64v8/
QEMU_ARCH=aarch64
else ifeq ($(ARCH), amd64)
KERNEL_ARCH=x86
KERNEL_IMG=bzImage
KERNEL_EXTRAS=
CROSS_PREFIX=
FROM_PREFIX=
else
$(error ARCH $(ARCH) is not supported)
endif

#Catch trying to build multiple architectures at a time.  This works because
# sort removes duplicates, so multiples of the same arch gets collapsed.
NARCHS=$(words $(sort $(ARCHS)))
ifeq ($(shell test $(NARCHS) -gt 1; echo $$?),0)
$(error Trying to build multiple architectures: $(ARCHS))
endif

#################################
# Detect cache, and set env vars.

CACHE_CONTAINER=apt-cacher-ng
PROXY_PORT=3142
PROXY_IP=$(shell docker inspect --format '{{.NetworkSettings.IPAddress}}' $(CACHE_CONTAINER) 2>/dev/null)
ifneq ($(PROXY_IP),)
export http_proxy=http://$(PROXY_IP):$(PROXY_PORT)
DOCKER_BUILD_PROXY=--build-arg http_proxy=http://$(PROXY_IP):$(PROXY_PORT)
endif

test_cache:
	@printenv | egrep '^http[s]?_proxy='

#########################
# Setup some directories.

SRCDIR := $(realpath $(CURDIR))
SCRIPTDIR := $(SRCDIR)/script
PATCHDIR := $(SRCDIR)/patches
KCONFIGDIR := $(SRCDIR)/kconfig
ROOTSRCDIR := $(SRCDIR)/rootsrc
INITRDSRCDIR := $(SRCDIR)/initrdsrc
DEVELDIR := $(SRCDIR)/devel
CONTAINERDIR := $(SRCDIR)/containers
SIGDIR := $(SRCDIR)/sigs

BUILDDIR := $(SRCDIR)/build/$(ARCH)
INITRDDIR := $(BUILDDIR)/initrd
FSDIR := $(BUILDDIR)/fs
OSFSDIR := $(FSDIR)/rootfs
KERNELDIR := $(BUILDDIR)/linux
FIRMWAREDIR := $(BUILDDIR)/firmware
ZEROTIER1DIR := $(BUILDDIR)/zerotier-one
IMGFSDIR := $(BUILDDIR)/imgfs
IMAGESDIR := $(BUILDDIR)/images

ifeq ($(ARCH:arm%=),)
UBOOTDIR := $(BUILDDIR)/uboot
BOOTFWDIR := $(BUILDDIR)/bootfw
endif

FAKEROOT := $(SCRIPTDIR)/lockedfakeroot

###########################
#Validate some assumptions.

#XXX Make sure the CROSS_PREFIX (or native) toolchain exists.
#XXX new enough cross tools, u-boot-tools (mkenvimage), mtools, grub (EFI and pc),
#    docker, syslinux, gpg2, etc.

#Make sure binfmt is configured properly for cross-builds
ifneq ($(shell mkdir -p $(BUILDDIR); echo 'int main(){}' | $(CROSS_PREFIX)gcc -x c -static -o $(BUILDDIR)/binfmt_test - && $(BUILDDIR)/binfmt_test; echo $$?),0)
$(error Run "sudo script/qemu-arm-static.sh")
endif

#Make sure docker experimental is enabled for "docker build --squash"
ifneq ($(shell docker info 2>/dev/null | grep -c '^\s*Experimental: true'),1)
$(error Enable "experimental" in /etc/docker/daemon.json)
endif

#########
# Targets

PHONY += buildinfo
buildinfo:
	@echo Foo: $(ARCH) $(SRCDIR) $(BUILDDIR)

PHONY += all-clean
all_clean:
	@rm -rf $(BUILDDIR)/..

PHONY += clean
clean: fs_clean initrd_clean
	rm -rf $(BUILDDIR)

KERNEL_SRC := $(KERNELDIR)/Makefile
kernel_src: $(KERNEL_SRC)
$(KERNEL_SRC):
	@mkdir -p $(KERNELDIR)
	wget -qO- $(KERNEL_URL) | xz -cd | \
	  tee >(tar --strip-components=1 -x -C $(KERNELDIR)) | \
	  gpg2 --no-default-keyring --keyring $(SIGDIR)/pubring.gpg \
	  --verify $(SIGDIR)/linux-$(KERNEL_VERSION).tar.sign - && \
	  [ `echo "$${PIPESTATUS[@]}" | tr -s ' ' + | bc` -eq 0 ] || \
	  ( rm -rf $(KERNELDIR) && false )

KERNEL_PATCH := $(KERNELDIR)/.config
kernel_patch: $(KERNEL_PATCH)
$(KERNEL_PATCH): $(KERNEL_SRC) $(KCONFIGDIR)/$(ARCH)_kconfig
	$(SCRIPTDIR)/apply-patch-series $(PATCHDIR)/linux/series $(KERNELDIR)
	cp $(KCONFIGDIR)/$(ARCH)_kconfig $(KERNELDIR)/.config

KERNEL := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/$(KERNEL_IMG)
kernel: $(KERNEL)
$(KERNEL): $(KERNEL_PATCH)
	( cd $(KERNELDIR); $(MAKE) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	  $(KERNEL_IMG) modules $(KERNEL_EXTRAS) )
	@touch $(KERNEL) #So rule doesn't keep running.

ifeq ($(ARCH:arm%=),)
ifeq ($(ARCH),armhf)
KERNEL_DTB := $(IMGFSDIR)/bcm2837-rpi-3-b-linux.dtb \
	      $(IMGFSDIR)/bcm2837-rpi-3-b-plus-linux.dtb \
	      $(IMGFSDIR)/bcm2837-rpi-cm3-io3-linux.dtb
KERNEL_DTB_DIR := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/dts
else
KERNEL_DTB := $(IMGFSDIR)/bcm2837-rpi-3-b-linux.dtb \
	      $(IMGFSDIR)/bcm2837-rpi-3-b-plus-linux.dtb \
	      $(IMGFSDIR)/bcm2837-rpi-cm3-io3-linux.dtb \
	      $(IMGFSDIR)/bcm2711-rpi-4-b-linux.dtb
KERNEL_DTB_DIR := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/dts/broadcom
endif
kernel_dtb: $(KERNEL_DTB)
$(KERNEL_DTB:$(IMGFSDIR)%-linux.dtb=$(KERNEL_DTB_DIR)%.dtb): $(KERNEL)
$(KERNEL_DTB): $(IMGFSDIR)/%-linux.dtb: $(KERNEL_DTB_DIR)/%.dtb
	cp $< $@
endif

KERNEL_MOD_INSTALL := $(OSFSDIR)/lib/modules/$(KERNEL_VERSION)/modules.symbols
kernel_mod_install: $(KERNEL_MOD_INSTALL)
$(KERNEL_MOD_INSTALL): $(KERNEL) # see below for additional deps
	$(FAKEROOT) -s $(FSDIR).fakeroot \
		    rm -rf $(OSFSDIR)/lib/modules/$(KERNEL_VERSION)
	( cd $(KERNELDIR); \
	  $(FAKEROOT) -s $(FSDIR).fakeroot \
	  $(MAKE) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	          INSTALL_MOD_PATH=$(OSFSDIR) \
	          modules_install )

PHONY += kernel_clean
kernel_clean:
	rm -rf $(KERNELDIR)

FIRMWARE_SRC := $(FIRMWAREDIR)/Makefile
firmware_src: $(FIRMWARE_SRC)
$(FIRMWARE_SRC):
	@mkdir -p $(FIRMWAREDIR)
	wget -qO- $(FIRMWARE_URL) | xz -cd | \
	  tee >(tar --strip-components=1 -x -C $(FIRMWAREDIR)) | \
	  gpg2 --no-default-keyring --keyring $(SIGDIR)/pubring.gpg \
	  --verify $(SIGDIR)/linux-firmware-$(FIRMWARE_VERSION).tar.sign - && \
	  [ `echo "$${PIPESTATUS[@]}" | tr -s ' ' + | bc` -eq 0 ] || \
	  ( rm -rf $(FIRMWAREDIR) && false )

ifeq ($(ARCH:arm%=),)
FIRMWARE := \
	$(FIRMWAREDIR)/brcm/brcmfmac43430-sdio.bin \
	$(FIRMWAREDIR)/brcm/brcmfmac43430-sdio.raspberrypi,3-model-b.txt \
	$(FIRMWAREDIR)/brcm/brcmfmac43455-sdio.bin \
	$(FIRMWAREDIR)/brcm/brcmfmac43455-sdio.raspberrypi,3-model-b-plus.txt \
	$(FIRMWAREDIR)/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt

endif
firmware: $(FIRMWARE)
ifneq ($(FIRMWARE),)
$(FIRMWARE): $(FIRMWARE_SRC)
endif

FIRMWARE_INSTALL := $(FIRMWARE:$(FIRMWAREDIR)/%=$(OSFSDIR)/lib/firmware/%)
firmware_install: $(FIRMWARE_INSTALL)
$(FIRMWARE_INSTALL): $(OSFSDIR)/lib/firmware/%: $(FIRMWAREDIR)/%
	@mkdir -p $(dir $@)
	cp $< $@

PHONY += firmware_clean
firmware_clean:
	rm -rf $(FIRMWAREDIR)

ifeq ($(ARCH:arm%=),) # {

UBOOT_SRC := $(UBOOTDIR)/Makefile
uboot_src: $(UBOOT_SRC)
$(UBOOT_SRC):
	@mkdir -p $(UBOOTDIR)
	wget -qO- $(UBOOT_URL) | tee >(tar --strip-components=1 -xj -C $(UBOOTDIR)) | \
	  gpg2 --no-default-keyring --keyring $(SIGDIR)/pubring.gpg \
	  --verify $(SIGDIR)/u-boot-$(UBOOT_VERSION).tar.bz2.sig - && \
	  [ `echo "$${PIPESTATUS[@]}" | tr -s ' ' + | bc` -eq 0 ] || \
	  ( rm -rf $(UBOOTDIR) && false )

UBOOT_PATCH := $(UBOOTDIR)/.config
uboot_patch: $(UBOOT_PATCH)
$(UBOOT_PATCH): $(UBOOT_SRC) $(KCONFIGDIR)/$(ARCH)_uconfig
	$(SCRIPTDIR)/apply-patch-series $(PATCHDIR)/uboot/series $(UBOOTDIR)
	cp $(KCONFIGDIR)/$(ARCH)_uconfig $(UBOOTDIR)/.config

UBOOT := $(UBOOTDIR)/$(UBOOT_IMG)
uboot: $(UBOOT)
$(UBOOT): $(UBOOT_PATCH)
	( cd $(UBOOTDIR); \
	  $(MAKE) ARCH=$(UBOOT_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	          $(UBOOT_IMG) )

PHONY += uboot_clean
uboot_clean:
	rm -rf $(UBOOTDIR)

#XXX Should check signature of BOOTFW.  May be easier said than done.
BOOTFW_SRC := $(BOOTFWDIR)/COPYING.linux
bootfw_src: $(BOOTFW_SRC)
$(BOOTFW_SRC):
	@mkdir -p $(BOOTFWDIR)
	wget -qO- $(BOOTFW_URL) | \
	    tar --strip-components=2 -xz -C $(BOOTFWDIR) \
		firmware-$(BOOTFW_VERSION)/boot

BOOTFW := \
	$(BOOTFWDIR)/bcm2710-rpi-3-b.dtb \
	$(BOOTFWDIR)/bcm2710-rpi-3-b-plus.dtb \
	$(BOOTFWDIR)/bcm2710-rpi-cm3.dtb \
	$(BOOTFWDIR)/bootcode.bin \
	$(BOOTFWDIR)/start.elf \
	$(BOOTFWDIR)/fixup.dat
ifeq ($(ARCH:arm64=),)
BOOTFW := \
	$(BOOTFWDIR)/bcm2711-rpi-4-b.dtb \
	$(BOOTFWDIR)/start4.elf \
	$(BOOTFWDIR)/fixup4.dat \
	$(BOOTFW)
endif
bootfw: $(BOOTFW)
$(BOOTFW): $(BOOTFW_SRC)

PHONY += bootfw_clean
bootfw_clean:
	rm -rf $(BOOTFWDIR)

UBOOT_ENV := $(IMGFSDIR)/uboot.env
uboot_env: $(UBOOT_ENV)
$(UBOOT_ENV): $(SRCDIR)/rpi/$(ARCH)_ubootenv
	@mkdir -p $(IMGFSDIR)
	mkenvimage -o$(UBOOT_ENV) -s16384 -p0 $<

PHONY += uboot_env_clean
uboot_env_clean:
	rm -f $(UBOOT_ENV)

CONFIG_TXT := $(IMGFSDIR)/config.txt
config_txt: $(CONFIG_TXT)
$(CONFIG_TXT): $(SRCDIR)/rpi/$(ARCH)_config.txt
	@mkdir -p $(IMGFSDIR)
	cp $< $(CONFIG_TXT)

PHONY += config_txt_clean
config_txt_clean:
	rm -f $(CONFIG_TXT)

endif # }

ZEROTIER1_SRC := $(ZEROTIER1DIR)/Makefile
zerotier1_src: $(ZEROTIER1_SRC)
$(ZEROTIER1_SRC):
	@mkdir -p $(ZEROTIER1DIR)
	wget -qO- $(ZEROTIER1_URL) | \
	  tar --strip-components=1 -xz -C $(ZEROTIER1DIR)

ZEROTIER1 = $(ZEROTIER1DIR)/zerotier-one
zerotier1: $(ZEROTIER1)
$(ZEROTIER1): $(ZEROTIER1_SRC)
	( cd $(ZEROTIER1DIR); \
	  $(MAKE) CC=$(CROSS_PREFIX)gcc \
	          CXX=$(CROSS_PREFIX)g++ \
		  STRIP=$(CROSS_PREFIX)strip \
		  zerotier-one \
	)

PHONY += zerotier1_clean
zerotier1_clean:
	rm -rf $(ZEROTIER1DIR)

INITRD := $(IMGFSDIR)/initrd
initrd: $(INITRD)
$(INITRD): $(INITRDSRCDIR)/*
	@mkdir -p $(IMGFSDIR)
	@rm -rf $(INITRDDIR) $(INITRDDIR).fakeroot
	@mkdir -p $(INITRDDIR)
	docker build $(DOCKER_BUILD_PROXY) \
	  --build-arg FROM_PREFIX=$(FROM_PREFIX) \
	  -t $(FROM_PREFIX)initrd $(INITRDSRCDIR)
	docker container create --name=$(shell echo $(FROM_PREFIX) | tr -d '/')initrd \
	  $(FROM_PREFIX)initrd
	docker export $(shell echo $(FROM_PREFIX) | tr -d '/')initrd | \
	  $(FAKEROOT) -s $(INITRDDIR).fakeroot tar xpf - -C$(INITRDDIR)
	$(FAKEROOT) -s $(INITRDDIR).fakeroot \
	  mknod $(INITRDDIR)/dev/console c 5 1
	( cd $(INITRDDIR) ; \
	  find . | $(FAKEROOT) $(INITRDDIR).fakeroot cpio -o -H newc ) | \
	    gzip > $(INITRD)
ifndef KEEP_CONTAINER
	docker rm $(shell echo $(FROM_PREFIX) | tr -d '/')initrd
	docker rmi $(FROM_PREFIX)initrd
endif

PHONY += initrd_clean
initrd_clean:
	docker rm -f $(FROM_PREFIX)initrd >/dev/null 2>&1 || true
	docker rmi -f $(FROM_PREFIX)initrd >/dev/null 2>&1 || true
	rm -rf $(INITRD) $(INITRDDIR) $(INITRDDIR).fakeroot

ROOTFS := $(IMGFSDIR)/layers/rootfs.layers
rootfs: $(ROOTFS)
$(ROOTFS): $(ROOTSRCDIR)/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -r -aARCH=$(ARCH) \
		rootfs '$(FROM_PREFIX)' $(ROOTSRCDIR) \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
	$(FAKEROOT) -s $(FSDIR).fakeroot \
	  $(SCRIPTDIR)/fixroot $(ROOTSRCDIR) $(OSFSDIR)
	@[ ! -d $(DEVELDIR)/rootfs ] || \
	  $(FAKEROOT) -s $(FSDIR).fakeroot \
	  cp -r $(DEVELDIR)/rootfs/. $(OSFSDIR)
ifndef KEEP_CONTAINER
	-docker rmi $(FROM_PREFIX)rootfs
endif
CONTAINERS += $(ROOTFS)

$(KERNEL_MOD_INSTALL): $(ROOTFS)
$(FIRMWARE_INSTALL): $(ROOTFS)

PHONY += rootfs_clean
rootfs_clean:
	$(SCRIPTDIR)/mkcontainer -c rootfs '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers

PYTHON3 := $(IMGFSDIR)/layers/python3.off
python3: $(PYTHON3)
$(PYTHON3): $(CONTAINERDIR)/python3/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t python3 '$(FROM_PREFIX)' \
		$(CONTAINERDIR)/python3 \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(PYTHON3)

PHONY += python3_clean
python3_clean:
	$(SCRIPTDIR)/mkcontainer -c python3 '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers

STORAGEMGR := $(IMGFSDIR)/layers/storagemgr.off
storagemgr: $(STORAGEMGR)
$(STORAGEMGR): $(PYTHON3) $(CONTAINERDIR)/storagemgr/* \
               $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t storagemgr '$(FROM_PREFIX)' \
		$(CONTAINERDIR)/storagemgr \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(STORAGEMGR)

PHONY += storagemgr_clean
storagemgr_clean:
	$(SCRIPTDIR)/mkcontainer -c storagemgr '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers

ZEROTIER := $(IMGFSDIR)/layers/zerotier.off
zerotier: $(ZEROTIER)
$(ZEROTIER): $(PYTHON3) $(CONTAINERDIR)/zerotier/*  $(ZEROTIER1) \
             $(SCRIPTDIR)/untar-docker-image
	mkdir -p $(BUILDDIR)/zerotier
	rsync -a --delete \
	      $(CONTAINERDIR)/zerotier/. \
	      $(ZEROTIER1) \
	      $(BUILDDIR)/zerotier
	$(SCRIPTDIR)/mkcontainer -t zerotier '$(FROM_PREFIX)' \
	  $(BUILDDIR)/zerotier $(FSDIR) $(IMGFSDIR)/layers \
	  '$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(ZEROTIER)

PHONY += zerotier_clean
zerotier_clean:
	$(SCRIPTDIR)/mkcontainer -c zerotier '$(FROM_PREFIX)' \
	  $(FSDIR) $(IMGFSDIR)/layers
	rm -rf $(BUILDDIR)/zerotier

HAPROXY := $(IMGFSDIR)/layers/haproxy.off
haproxy: $(HAPROXY)
$(HAPROXY): $(PYTHON3) $(CONTAINERDIR)/haproxy/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t haproxy '$(FROM_PREFIX)' \
	  $(CONTAINERDIR)/haproxy $(FSDIR) $(IMGFSDIR)/layers '$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(HAPROXY)

PHONY += haproxy_clean
haproxy_clean:
	$(SCRIPTDIR)/mkcontainer -c haproxy '$(FROM_PREFIX)' \
	  $(FSDIR) $(IMGFSDIR)/layers

DNSD := $(IMGFSDIR)/layers/dnsd.off
dnsd: $(DNSD)
$(DNSD): $(PYTHON3) $(CONTAINERDIR)/dnsd/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t dnsd '$(FROM_PREFIX)' \
		$(CONTAINERDIR)/dnsd \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(DNSD)

PHONY += dnsd_clean
dnsd_clean:
	$(SCRIPTDIR)/mkcontainer -c dnsd '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers


CERTMGR := $(IMGFSDIR)/layers/certmgr.off
certmgr: $(CERTMGR)
$(CERTMGR): $(PYTHON3) $(CONTAINERDIR)/certmgr/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t certmgr '$(FROM_PREFIX)' \
		$(CONTAINERDIR)/certmgr \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(CERTMGR)

PHONY += certmgr_clean
certmgr_clean:
	$(SCRIPTDIR)/mkcontainer -c certmgr '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers

WEB := $(IMGFSDIR)/layers/web.off
web: $(WEB)
$(WEB): $(PYTHON3) $(CONTAINERDIR)/web/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t web '$(FROM_PREFIX)' \
	  $(CONTAINERDIR)/web $(FSDIR) $(IMGFSDIR)/layers '$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(WEB)

PHONY += web_clean
web_clean:
	$(SCRIPTDIR)/mkcontainer -c web '$(FROM_PREFIX)' \
	  $(FSDIR) $(IMGFSDIR)/layers

APPSTORE := $(IMGFSDIR)/layers/appstore.off
appstore: $(APPSTORE)
$(APPSTORE): $(PYTHON3) $(CONTAINERDIR)/appstore/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t appstore '$(FROM_PREFIX)' \
	  $(CONTAINERDIR)/appstore $(FSDIR) $(IMGFSDIR)/layers '$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(APPSTORE)

PHONY += appstore_clean
appstore_clean:
	$(SCRIPTDIR)/mkcontainer -c appstore '$(FROM_PREFIX)' \
	  $(FSDIR) $(IMGFSDIR)/layers

REGISTRATION := $(IMGFSDIR)/layers/registration.off
registration: $(REGISTRATION)
$(REGISTRATION): $(PYTHON3) $(CONTAINERDIR)/registration/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -t registration '$(FROM_PREFIX)' \
	  $(CONTAINERDIR)/registration $(FSDIR) $(IMGFSDIR)/layers '$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(REGISTRATION)

PHONY += registration_clean
registration_clean:
	$(SCRIPTDIR)/mkcontainer -c registration '$(FROM_PREFIX)' \
	  $(FSDIR) $(IMGFSDIR)/layers

SSHD := $(IMGFSDIR)/layers/sshd.off
sshd: $(SSHD)
$(SSHD): $(CONTAINERDIR)/sshd/* $(SCRIPTDIR)/untar-docker-image
	$(SCRIPTDIR)/mkcontainer -St sshd '$(FROM_PREFIX)' \
		$(CONTAINERDIR)/sshd \
		$(FSDIR) \
		$(IMGFSDIR)/layers \
		'$(DOCKER_BUILD_PROXY)'
CONTAINERS += $(SSHD)

PHONY += sshd_clean
sshd_clean:
	$(SCRIPTDIR)/mkcontainer -c sshd '$(FROM_PREFIX)' \
		$(FSDIR) \
		$(IMGFSDIR)/layers

PHONY += fs_clean
fs_clean: rootfs_clean python3_clean storagemgr_clean zerotier_clean \
          haproxy_clean dnsd_clean certmgr_clean web_clean appstore_clean \
	  registration_clean sshd_clean
	rm -rf $(FSDIR) $(FSDIR).fakeroot

SQUASHFS := $(IMGFSDIR)/layers/fs.sqfs
squashfs: $(SQUASHFS)
$(SQUASHFS): $(CONTAINERS) $(KERNEL_MOD_INSTALL) $(FIRMWARE_INSTALL)
	@rm -rf $(IMGFSDIR)/layers/fs.sqfs
	mkdir -p $(IMGFSDIR)/layers/fs
	$(FAKEROOT) $(FSDIR).fakeroot \
	  mksquashfs $(FSDIR) $(IMGFSDIR)/layers/fs.sqfs -noappend ; \

PHONY += squashfs_clean
squashfs_clean:
	rm -f $(IMGFSDIR)/layers/fs.sqfs
	rmdir $(IMGFSDIR)/layers/fs

###############
# Image Targets

IMG_DEPS = \
	$(INITRD) \
	$(KERNEL) \
	$(SQUASHFS) \
	$(filter-out %/. %.., $(wildcard $(DEVELDIR)/imgfs/.*)) \
	$(wildcard $(DEVELDIR)/imgfs/*)
ifeq ($(ARCH:arm%=),)
IMG_DEPS += \
	$(KERNEL_DTB) \
	$(UBOOT) \
	$(UBOOT_ENV) \
	$(BOOTFW) \
	$(CONFIG_TXT)
endif

RPI3_IMG := $(IMAGESDIR)/rpi3image.bin
rpi3_img: $(RPI3_IMG)
$(RPI3_IMG): $(IMG_DEPS) $(SCRIPTDIR)/mkfatimg
	@mkdir -p $(IMAGESDIR)
	cp -r $(filter-out $(IMGFSDIR)/%, $(IMG_DEPS)) $(IMGFSDIR)
	$(SCRIPTDIR)/mkfatimg $(RPI3_IMG) 256 $(IMGFSDIR)/*

PHONY += rpi3_img_clean
rpi3_img_clean:
	rm $(RPI3_IMG)

RPI3_ZIP := $(IMAGESDIR)/rpi3.zip
rpi3_zip: $(RPI3_ZIP)
$(RPI3_ZIP): $(IMG_DEPS)
	@mkdir -p $(IMAGESDIR)
	rm -f $(RPI3_ZIP)
	cp -r $(filter-out $(IMGFSDIR)/%, $(IMG_DEPS)) $(IMGFSDIR)
	( cd $(IMGFSDIR) && zip -r $(RPI3_ZIP) * -x pairingkey wifi.txt )

PHONY += rpi3_zip_clean
rpi3_zip_clean:
	rm $(RPI3_ZIP)

PC_IMG := $(IMAGESDIR)/pcimage.bin
pc_img: $(PC_IMG)
$(PC_IMG): $(IMG_DEPS) $(SRCDIR)/pc/grub.cfg
	@mkdir -p $(IMAGESDIR)
	cp -r $(filter-out $(IMGFSDIR)/%, $(IMG_DEPS)) $(IMGFSDIR)
	mkdir -p $(IMGFSDIR)/boot/grub
	cp $(SRCDIR)/pc/grub.cfg $(IMGFSDIR)/boot/grub/
	dd if=/dev/zero of=$(IMGFSDIR)/SPACER bs=4096 count=1024 #HACK to make room for apikey
	grub-mkrescue -o $(PC_IMG) $(IMGFSDIR)
	@rm $(IMGFSDIR)/SPACER

PHONY += pc_img_clean
pc_img_clean:
	rm $(PC_IMG)

PC_ZIP := $(IMAGESDIR)/pc.zip
pc_zip: $(PC_ZIP)
$(PC_ZIP): $(IMG_DEPS) $(SRCDIR)/pc/syslinux.cfg
	@mkdir -p $(IMAGESDIR)
	rm -f $(PC_ZIP)
	cp -r $(filter-out $(IMGFSDIR)/%, $(IMG_DEPS)) $(IMGFSDIR)
	mkdir -p $(IMGFSDIR)/EFI/boot
	cp $(SRCDIR)/pc/syslinux.cfg /usr/lib/syslinux/modules/efi64/ldlinux.e64 $(IMGFSDIR)/EFI/boot/
	cp /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi $(IMGFSDIR)/EFI/boot/bootx64.efi
	( cd $(IMGFSDIR) && zip -r $(PC_ZIP) * -x pairingkey wifi.txt )

PHONY += pc_zip_clean
pc_zip_clean:
	rm $(PC_ZIP)

PHONY += img zip
ifeq ($(ARCH:arm%=),)
img: rpi3_img
zip: rpi3_zip
else ifeq ($(ARCH), amd64)
img: pc_img
zip: pc_zip
endif

########################
# Deploy images

PHONY += deploy
ifeq ($(ARCH:arm%=),)
deploy: $(RPI3_ZIP)
	@test $(SERVER) || ( echo 'set SERVER' && false)
	scp $(RPI3_ZIP) root@$(SERVER):~/data/sslnginx/html/images/
else ifeq ($(ARCH), amd64)
deploy: $(PC_ZIP)
	@test $(SERVER) || ( echo 'set SERVER' && false)
	scp $(PC_ZIP) root@$(SERVER):~/data/sslnginx/html/images/
endif
########################
# Qemu emulation targets

TMP_USB_IMG=/tmp/usb.img
tmp-usb-img: $(TMP_USB_IMG)
$(TMP_USB_IMG):
	$(SCRIPTDIR)/mkfatimg $(TMP_USB_IMG) 512

ifeq ($(ARCH:arm%=),)
#XXX 2ndary storage is broken, since raspi3 doesn't have USB host or virtio. And
#    virt doesn't have sdcard.  Might be able to add some rename rules to mdev or
#    something to workaround sda vs mmcblk...
#XXX Try this with uboot for -kernel + no -initrd/-dtb/-append...
qemu-run: $(RPI3_IMG) $(TMP_USB_IMG)
	@echo -e "\nctrl-a x to exit qemu\n"
	qemu-system-$(QEMU_ARCH) -M raspi3 -nographic \
	  -kernel $(IMGFSDIR)/$(KERNEL_IMG) -initrd $(INITRD) \
	  -dtb $(IMGFSDIR)/bcm2837-rpi-3-b.dtb \
	  -m 1024 -no-reboot -append "8250.nr_uarts=1 console=tty1 console=ttyAMA0,115200" \
	  -drive file=$(RPI3_IMG),if=sd,format=raw #-drive file=$(TMP_USB_IMG),if=virtio,format=raw
else ifeq ($(ARCH), amd64)
qemu-run: $(PC_IMG) $(TMP_USB_IMG)
	@echo -e "\nctrl-a x to exit qemu\n"
	qemu-system-x86_64 -machine pc,accel=kvm:tcg -nographic -m 1024 \
	  -hda $(PC_IMG) -hdb $(TMP_USB_IMG)
endif
PHONY += qemu-run

########################
# Tests/QA/linters

PHONY += check
check:
	pyflakes3 `find . -name '*.py'`
#XXX This misses +x python scripts that use #! whose names don't end in .py.

.PHONY: $(PHONY)

print-%: ; @echo $*=$($*)
