######################################################
# Setup some high-level global settings.

#XXX Need targets for checking for debian and kernel security vulns, respin image.

#XXX Add support for (cross) building patched upstream, patched tar.gz, and
#    and local git trees.  Perhaps a list of things to build in ../?
#XXX Do we even need to cross build anything other than containers?  How
#    valuable is the seperation between build env and run env provided by .deb?

#XXX Turn the http:// URLs into https:// if we can fix apt-cacher-ng to work with them.
#XXX Check signatures for downloads!

DEBIAN_RELEASE := stretch

KERNEL_VERSION = 4.13.4
BOOTFW_VERSION = 1.20170811

KERNEL_URL=http://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$(KERNEL_VERSION).tar.xz
UBOOT_URL=http://ftp.denx.de/pub/u-boot/u-boot-2017.09.tar.bz2
BOOTFW_URL=http://github.com/raspberrypi/firmware/archive/$(BOOTFW_VERSION).tar.gz
KERNFW_URL=http://github.com/RPi-Distro/firmware-nonfree/archive/master/brcm80211/brcm.tar.gz

######################################################
# Pick/validate what target architectures we're building for.

#If we're building a specific image, automatically set the ARCH based on that.
ARCHS := #Needed so ARCHS+=$(ARCH) expands $(ARCH) immediately, not recursively.
ARM_TARGETS:=rpi3_img rpi3_img_clean chip_img chip_img_clean
ifneq ($(filter $(ARM_TARGETS), $(MAKECMDGOALS)),)
override ARCH:=armhf
ARCHS+=$(ARCH)
endif
AMD64_TARGETS:=pc_img pc_img_clean
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
SERIAL_TTY=ttyAMA0
UBOOT_ARCH=arm
UBOOT_IMG=u-boot.bin
CROSS_PREFIX=arm-linux-gnueabihf-
DEBIAN_CONTAINER := arm32v7/debian:$(DEBIAN_RELEASE)-slim
BUSYBOX_CONTAINER := arm32v7/busybox
else ifeq ($(ARCH), amd64)
KERNEL_ARCH=x86
KERNEL_IMG=bzImage
KERNEL_EXTRAS=
SERIAL_TTY=ttyS0
CROSS_PREFIX=
DEBIAN_CONTAINER := debian:$(DEBIAN_RELEASE)-slim
BUSYBOX_CONTAINER := busybox
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
DEVELDIR := $(SRCDIR)/devel

BUILDDIR := $(SRCDIR)/build/$(ARCH)
INITRDDIR := $(BUILDDIR)/initrd
ROOTFSDIR := $(BUILDDIR)/rootfs
BASEFSDIR := $(ROOTFSDIR)/baseroot
OSFSDIR := $(ROOTFSDIR)/osroot
EXTRADEBDIR := $(BUILDDIR)/extradebs
KERNELDIR := $(BUILDDIR)/linux
IMGFSDIR := $(BUILDDIR)/imgfs
IMAGESDIR := $(BUILDDIR)/images

ifeq ($(ARCH), armhf)
UBOOTDIR := $(BUILDDIR)/uboot
BOOTFWDIR := $(BUILDDIR)/bootfw
KERNFWDIR := $(BUILDDIR)/kernfw
endif

BUILDROOTID := $(shell echo $(SRCDIR) | sha1sum | cut -b1-10)

FAKEROOT := $(SCRIPTDIR)/lockedfakeroot

###########################
#Validate some assumptions.

#XXX Make sure the CROSS_PREFIX (or native) toolchain exists.
#XXX new enough cross tools, u-boot-tools (mkenvimage), mtools, grub (EFI and pc),
#    docker, xorriso, etc.

#Make sure binfmt is configured properly.
ifneq ($(shell echo '50c12d79f40fc1cacc4819ae9bac6bb1  /proc/sys/fs/binfmt_misc/qemu-arm' | \
	md5sum -c --quiet; echo $$?),0)
$(error Run "sudo script/qemu-arm-static.sh")
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
clean: rootfs_clean initrd_clean
	@rm -rf $(BUILDDIR)

KERNEL_SRC := $(KERNELDIR)/Makefile
kernel_src: $(KERNEL_SRC)
$(KERNEL_SRC):
	@mkdir -p $(KERNELDIR)
	wget -qO- $(KERNEL_URL) | tar --strip-components=1 -xJ -C $(KERNELDIR)

#XXX This doesn't rebuild kernel if ARCH_kconfig file changes.
KERNEL_PATCH := $(KERNELDIR)/.config
kernel_patch: $(KERNEL_PATCH)
$(KERNEL_PATCH): $(KERNEL_SRC)
	cp $(KCONFIGDIR)/$(ARCH)_kconfig $(KERNELDIR)/.config
	$(SCRIPTDIR)/apply-patch-series $(PATCHDIR)/linux/series $(KERNELDIR)

KERNEL := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/$(KERNEL_IMG)
kernel: $(KERNEL)
$(KERNEL): $(KERNEL_PATCH)
	( cd $(KERNELDIR); $(MAKE) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	  $(KERNEL_IMG) modules $(KERNEL_EXTRAS) )

ifeq ($(ARCH), armhf)
KERNEL_DTB := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/dts/bcm2837-rpi-3-b.dtb
kernel_dtb: $(KERNEL_DTB)
$(KERNEL_DTB): $(KERNEL)
endif

KERNEL_MOD_INSTALL := $(OSFSDIR)/lib/modules/$(KERNEL_VERSION)/modules.symbols
kernel_mod_install: $(KERNEL_MOD_INSTALL)
$(KERNEL_MOD_INSTALL): $(KERNEL) # see below for additional deps
	( cd $(KERNELDIR); \
	  $(FAKEROOT) -s $(ROOTFSDIR)/fakeroot \
	  $(MAKE) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	          INSTALL_MOD_PATH=$(OSFSDIR) \
	          modules_install )

PHONY += kernel_clean
kernel_clean:
	rm -rf $(KERNELDIR)

ifeq ($(ARCH), armhf) # {

UBOOT_SRC := $(UBOOTDIR)/Makefile
uboot_src: $(UBOOT_SRC)
$(UBOOT_SRC):
	@mkdir -p $(UBOOTDIR)
	wget -qO- $(UBOOT_URL) | tar --strip-components=1 -xj -C $(UBOOTDIR)

UBOOT_PATCH := $(UBOOTDIR)/.config
uboot_patch: $(UBOOT_PATCH)
$(UBOOT_PATCH): $(UBOOT_SRC)
	cp $(KCONFIGDIR)/$(ARCH)_uconfig $(UBOOTDIR)/.config
	$(SCRIPTDIR)/apply-patch-series $(PATCHDIR)/uboot/series $(UBOOTDIR)

UBOOT := $(UBOOTDIR)/$(UBOOT_IMG)
uboot: $(UBOOT)
$(UBOOT): $(UBOOT_PATCH)
	( cd $(UBOOTDIR); \
	  $(MAKE) ARCH=$(UBOOT_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	          $(UBOOT_IMG) )

PHONY += uboot_clean
uboot_clean:
	rm -rf $(UBOOTDIR)

BOOTFW_SRC := $(BOOTFWDIR)/COPYING.linux
bootfw_src: $(BOOTFW_SRC)
$(BOOTFW_SRC):
	@mkdir -p $(BOOTFWDIR)
	wget -qO- $(BOOTFW_URL) | \
	    tar --strip-components=2 -xz -C $(BOOTFWDIR) \
		firmware-$(BOOTFW_VERSION)/boot

BOOTFW := \
	$(BOOTFWDIR)/bcm2710-rpi-3-b.dtb \
	$(BOOTFWDIR)/bcm2710-rpi-cm3.dtb \
	$(BOOTFWDIR)/bootcode.bin \
	$(BOOTFWDIR)/start.elf \
	$(BOOTFWDIR)/fixup.dat
bootfw: $(BOOTFW)
$(BOOTFW): $(BOOTFW_SRC)

PHONY += bootfw_clean
bootfw_clean:
	rm -rf $(BOOTFWDIR)

KERNFW_SRC := $(KERNFWDIR)/LICENSE
kernfw_src: $(KERNFW_SRC)
$(KERNFW_SRC):
	@mkdir -p $(KERNFWDIR)
	wget -qO- $(KERNFW_URL) | \
	    tar --strip-components=2 -xz -C $(KERNFWDIR) \
		firmware-nonfree-master/brcm80211

KERNFW_INSTALL_DIR := $(OSFSDIR)/lib/firmware/brcm
KERNFW_INSTALL := $(KERNFW_INSTALL_DIR)/bcm43xx-0.fw-610.812
kernfw_install: $(KERNFW_INSTALL)
$(KERNFW_INSTALL): $(KERNFW_SRC) # see below for additional deps
	$(FAKEROOT) -s $(ROOTFSDIR)/fakeroot \
	    sh -ce 'mkdir -p $(KERNFW_INSTALL_DIR); \
	            cp -rT $(KERNFWDIR)/brcm $(KERNFW_INSTALL_DIR); \
	            find $(KERNFW_INSTALL_DIR) \
			 -type d -exec chmod 755 {} \; -o \
	                 -type f -exec chmod 644 {} \;'

PHONY += kernfw_clean
kernfw_clean:
	rm -rf $(KERNFWDIR)

UBOOT_ENV := $(IMGFSDIR)/uboot.env
uboot_env: $(UBOOT_ENV)
$(UBOOT_ENV): $(SRCDIR)/rpi/ubootenv
	@mkdir -p $(IMGFSDIR)
	mkenvimage -o$(UBOOT_ENV) -s16384 -p0 $<

PHONY += uboot_env_clean
uboot_env_clean:
	rm -f $(UBOOT_ENV)

endif # }

EXTRA_DEB_URLS=$(SRCDIR)/extra_deb_urls
EXTRA_DEBS := $(shell $(SCRIPTDIR)/urls-to-files $(ARCH) $(EXTRADEBDIR) <$(EXTRA_DEB_URLS))
extra_debs: $(EXTRA_DEBS)
$(EXTRA_DEBS): $(EXTRA_DEB_URLS)
	@mkdir -p $(EXTRADEBDIR)
	@rm -f $(EXTRADEBDIR)/*
	wget -qcP $(EXTRADEBDIR)/ \
	  $(shell sed 's/XARCHX/$(ARCH)/g' <$(EXTRA_DEB_URLS))
	@touch $(EXTRA_DEBS)

PHONY += extra_debs_clean
extra_debs_clean:
	rm -rf $(EXTRADEBDIR)

#XXX If "docker save" doesn't pull images, this actually must depend on $(ROOTFS)
CONTAINERS := $(IMGFSDIR)/debian.off
containers: $(CONTAINERS)
$(CONTAINERS): $(SCRIPTDIR)/docker-split-image
	mkdir -p $(IMGFSDIR)
	docker save $(DEBIAN_CONTAINER) | \
	  $(SCRIPTDIR)/docker-split-image $(IMGFSDIR)/debian

ROOTFS := $(OSFSDIR)/init
rootfs: $(ROOTFS)
$(ROOTFS): $(ROOTSRCDIR)/* $(EXTRA_DEBS) $(SCRIPTDIR)/untar-docker-image
	@rm -rf $(ROOTFSDIR)
	@mkdir -p $(ROOTFSDIR)
	tar zcf - -C $(ROOTSRCDIR) . -C $(EXTRADEBDIR) . | \
	  docker build $(DOCKER_BUILD_PROXY) \
	  --build-arg FROM_CONTAINER=$(DEBIAN_CONTAINER) \
	  --force-rm=true -t rootfs-$(BUILDROOTID) -
	docker save rootfs-$(BUILDROOTID) | \
	  $(FAKEROOT) -s $(ROOTFSDIR)/fakeroot \
	  $(SCRIPTDIR)/untar-docker-image $(ROOTFSDIR)
	$(FAKEROOT) -s $(ROOTFSDIR)/fakeroot \
	  $(SCRIPTDIR)/fixroot $(ROOTSRCDIR) $(OSFSDIR)
	touch $(ROOTFS)
ifndef KEEP_CONTAINER
	-docker rmi rootfs-$(BUILDROOTID)
endif
	@[ ! -d $(DEVELDIR)/rootfs ] || \
	  $(FAKEROOT) -s $(ROOTFSDIR)/fakeroot \
	    cp -r $(DEVELDIR)/rootfs/. $(OSFSDIR)

$(KERNEL_MOD_INSTALL): $(ROOTFS)
$(KERNFW_INSTALL): $(ROOTFS)

PHONY += rootfs_clean
rootfs_clean:
	-docker rmi rootfs-$(BUILDROOTID) || true
ifneq ($(shell docker images -f "dangling=true" -q),)
	-docker rmi `docker images -f "dangling=true" -q`
endif
	rm -rf $(ROOTFSDIR)

INITRD := $(IMGFSDIR)/initrd
initrd: $(INITRD)
$(INITRD): $(ROOTSRCDIR)/init $(ROOTSRCDIR)/fstab
	@mkdir -p $(IMGFSDIR)
	@rm -rf $(INITRDDIR) $(INITRDDIR).fakeroot
	@mkdir -p $(INITRDDIR)
	docker container create --name=initrd-$(BUILDROOTID) \
	  $(BUSYBOX_CONTAINER)
	docker export initrd-$(BUILDROOTID) | \
	  $(FAKEROOT) -s $(INITRDDIR).fakeroot tar xpf - -C$(INITRDDIR)
	$(FAKEROOT) -s $(INITRDDIR).fakeroot \
	  sh -ce 'cd $(INITRDDIR); \
		  cp $(ROOTSRCDIR)/init .; \
	          cp $(ROOTSRCDIR)/fstab etc; \
	          mknod dev/console c 5 1; \
		  mkdir boot'
	( cd $(INITRDDIR) ; \
	  find . | \
	    $(FAKEROOT) $(INITRDDIR).fakeroot cpio -o -H newc) | \
	    gzip > $(INITRD)
	docker rm initrd-$(BUILDROOTID)

PHONY += initrd_clean
initrd_clean:
	rm -rf $(INITRD) $(INITRDDIR) $(INITRDDIR).fakeroot
	docker rm initrd-$(BUILDROOTID) || true

BASESQUASHFS := $(IMGFSDIR)/baseroot.sqfs
basesquashfs: $(BASESQUASHFS)
$(BASESQUASHFS): $(ROOTFS)
	@mkdir -p $(IMGFSDIR)
	@mkdir -p $(IMGFSDIR)/baseroot
	@rm -rf $(BASESQUASHFS)
	$(FAKEROOT) $(ROOTFSDIR)/fakeroot \
	  mksquashfs $(BASEFSDIR) $(BASESQUASHFS)

PHONY += basesquashfs_clean
basesquashfs_clean:
	rm -f $(BASESQUASHFS)

OSSQUASHFS := $(IMGFSDIR)/osroot.sqfs
ossquashfs: $(OSSQUASHFS)
$(OSSQUASHFS): $(ROOTFS) $(KERNEL_MOD_INSTALL) $(KERNFW_INSTALL)
	@mkdir -p $(IMGFSDIR)
	@mkdir -p $(IMGFSDIR)/osroot
	@rm -rf $(OSSQUASHFS)
	$(FAKEROOT) $(ROOTFSDIR)/fakeroot \
	  mksquashfs $(OSFSDIR) $(OSSQUASHFS)

PHONY += ossquashfs_clean
ossquashfs_clean:
	rm -f $(OSSQUASHFS)

###############
# Image Targets

IMG_DEPS = \
	$(INITRD) \
	$(BASESQUASHFS) \
	$(OSSQUASHFS) \
	$(KERNEL) \
	$(CONTAINERS)
ifeq ($(ARCH), armhf)
IMG_DEPS += \
	$(KERNEL_DTB) \
	$(UBOOT) \
	$(UBOOT_ENV) \
	$(BOOTFW)
endif

RPI3_IMG := $(IMAGESDIR)/rpi3image.bin
rpi3_img: $(RPI3_IMG)
$(RPI3_IMG): $(IMG_DEPS) $(SCRIPTDIR)/mkfatimg
	@mkdir -p $(IMAGESDIR)
	cp -r $(KERNEL) $(KERNEL_DTB) $(UBOOT) \
	  $(SRCDIR)/rpi/config.txt $(BOOTFW) \
	  $(filter-out %/. %.., $(wildcard $(DEVELDIR)/imgfs/.*)) \
	  $(wildcard $(DEVELDIR)/imgfs/*) $(IMGFSDIR)
	$(SCRIPTDIR)/mkfatimg $(RPI3_IMG) 192 $(IMGFSDIR)/*

PHONY += rpi3_img_clean
rpi3_img_clean:
	rm $(RPI3_IMG)

PC_IMG := $(IMAGESDIR)/pcimage.bin
pc_img: $(PC_IMG)
$(PC_IMG): $(IMG_DEPS)
	@mkdir -p $(IMAGESDIR)
	cp -r $(KERNEL) $(SRCDIR)/pc/grub.cfg \
	  $(filter-out %/. %.., $(wildcard $(DEVELDIR)/imgfs/.*)) \
	  $(wildcard $(DEVELDIR)/imgfs/*) $(IMGFSDIR)
	mkdir -p $(IMGFSDIR)/boot/grub
	cp $(IMGFSDIR)/grub.cfg $(IMGFSDIR)/boot/grub/
	grub-mkrescue -o $(PC_IMG) $(IMGFSDIR)

PHONY += pc_img_clean
pc_img_clean:
	rm $(PC_IMG)

.PHONY: $(PHONY)
