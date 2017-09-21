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

KERNEL_VERSION = 4.9.47
RPIFW_VERSION = 1.20170811

KERNEL_URL=http://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$(KERNEL_VERSION).tar.xz
QEMU_URL=http://download.qemu-project.org/qemu-2.10.0.tar.xz
UBOOT_URL=http://ftp.denx.de/pub/u-boot/u-boot-2017.09.tar.bz2
RPIFW_URL=http://github.com/raspberrypi/firmware/archive/$(RPIFW_VERSION).tar.gz

DOCKER_URL=https://download.docker.com/linux/debian/dists/stretch/pool/stable/$(ARCH)/docker-ce_17.06.2~ce-0~debian_$(ARCH).deb
EXTRA_DEB_URLS="$(DOCKER_URL)"

######################################################
# Pick/validate what target architectures we're building for.

#If we're building a specific image, automatically set the ARCH based on that.
ARCHS := #Needed so ARCHS+=$(ARCH) expands $(ARCH) immediately, not recursively.
ARM_TARGETS:=rpi3_img chip_img
ifneq ($(filter $(ARM_TARGETS), $(MAKECMDGOALS)),)
override ARCH:=armhf
ARCHS+=$(ARCH)
endif
AMD64_TARGETS:=pc_img
ifneq ($(filter $(AMD64_TARGETS), $(MAKECMDGOALS)),)
override ARCH:=amd64
ARCHS+=$(ARCH)
endif

ifeq ($(ARCH),)
$(error ARCH not set, either implicitly by an PLATFORM_img goal, or explicitly)
else ifeq ($(ARCH), armhf)
QEMU_ARCH=arm
QEMU_MACH=virt
KERNEL_ARCH=arm
KERNEL_IMG=zImage
KERNEL_EXTRAS=dtbs
SERIAL_TTY=ttyAMA0
UBOOT_ARCH=arm
UBOOT_IMG=u-boot.bin
CROSS_PREFIX=arm-linux-gnueabihf-
else ifeq ($(ARCH), amd64)
QEMU_ARCH=x86_64
QEMU_MACH=pc
KERNEL_ARCH=x86
KERNEL_IMG=bzImage
KERNEL_EXTRAS=
SERIAL_TTY=ttyS0
CROSS_PREFIX=
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
endif

test_cache:
	@printenv | egrep '^http[s]?_proxy='

#########################
# Setup some directories.

SRCDIR := $(realpath $(CURDIR))
SCRIPTDIR := $(SRCDIR)/script
PATCHDIR := $(SRCDIR)/patches
KCONFIGDIR := $(SRCDIR)/kconfig

BUILDDIR := $(SRCDIR)/build/$(ARCH)
ROOTFSDIR := $(BUILDDIR)/rootfs
KERNELDIR := $(BUILDDIR)/linux
QEMUDIR := $(BUILDDIR)/qemu
MISCDIR := $(BUILDDIR)/misc
IMAGESDIR := $(BUILDDIR)/images

ifeq ($(ARCH), armhf)
UBOOTDIR := $(BUILDDIR)/uboot
RPIFWDIR := $(BUILDDIR)/rpifw
endif

###########################
#Validate some assumptions.

#XXX Make sure the CROSS_PREFIX (or native) toolchain exists.
#XXX Make sure qemu builddeps are installed.
#XXX new enough cross tools, etc.

#########
# Targets

PHONY += buildinfo
buildinfo:
	@echo Foo: $(ARCH) $(QEMU_ARCH) $(SRCDIR) $(BUILDDIR)

PHONY += all-clean
all_clean:
	@rm -rf $(BUILDDIR)/..

PHONY += clean
clean:
	@rm -rf $(BUILDDIR)

KERNEL_SRC := $(KERNELDIR)/Makefile
kernel_src: $(KERNEL_SRC)
$(KERNEL_SRC):
	@mkdir -p $(KERNELDIR)
	wget -qO- $(KERNEL_URL) | tar --strip-components=1 -xJ -C $(KERNELDIR)

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

KERNEL_MOD_INSTALL := $(ROOTFSDIR)/lib/modules/$(KERNEL_VERSION)/modules.symbols
kernel_mod_install: $(KERNEL_MOD_INSTALL)
$(KERNEL_MOD_INSTALL): $(KERNEL) $(ROOTFS_BOOTSTRAP)
	( cd $(KERNELDIR); \
	  $(MAKE) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) \
	          INSTALL_MOD_PATH=$(ROOTFSDIR) \
	          modules_install )

PHONY += kernel_clean
kernel_clean:
	rm -rf $(KERNELDIR)

#Need a newer qemu that has working VirtFS.
QEMU_SRC := $(QEMUDIR)/configure
qemu_src: $(QEMU_SRC)
$(QEMU_SRC):
	@mkdir -p $(QEMUDIR)
	wget -qO- $(QEMU_URL) | tar --strip-components=1 -xJ -C $(QEMUDIR)

QEMU := $(QEMUDIR)/$(QEMU_ARCH)-softmmu/qemu-system-$(QEMU_ARCH)
qemu: $(QEMU)
$(QEMU): $(QEMU_SRC)
	( cd $(QEMUDIR); ./configure --target-list=$(QEMU_ARCH)-softmmu; $(MAKE) )

PHONY += qemu_clean
qemu_clean:
	rm -rf $(QEMUDIR)

ifeq ($(ARCH), armhf)

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

RPIFW_SRC := $(RPIFWDIR)/.complete
rpifw_src: $(RPIFW_SRC)
$(RPIFW_SRC):
	@mkdir -p $(RPIFWDIR)
	wget -qO- $(RPIFW_URL) | \
	    tar --strip-components=2 -xz -C $(RPIFWDIR) \
		firmware-$(RPIFW_VERSION)/boot
	touch $(RPIFW_SRC)

RPIFW := \
	$(RPIFWDIR)/bcm2710-rpi-3-b.dtb \
	$(RPIFWDIR)/bcm2710-rpi-cm3.dtb \
	$(RPIFWDIR)/bootcode.bin \
	$(RPIFWDIR)/start.elf \
	$(RPIFWDIR)/fixup.dat
rpifw: $(RPIFW)
$(RPIFW): $(RPIFW_SRC)

PHONY += rpifw_clean
rpifw_clean:
	rm -rf $(RPIFWDIR)

UBOOT_ENV := $(MISCDIR)/uboot.env
uboot_env: $(UBOOT_ENV)
$(UBOOT_ENV): $(SCRIPTDIR)/mkubootenv
	@mkdir -p $(MISCDIR)
	$(SCRIPTDIR)/mkubootenv $(UBOOT_ENV) 16384

PHONY += uboot_env_clean
uboot_env_clean:
	rm -f $(UBOOT_ENV)

endif

ROOTFS_BOOTSTRAP := $(ROOTFSDIR)/etc/apt/sources.list
rootfs_bootstrap: $(ROOTFS_BOOTSTRAP)
$(ROOTFS_BOOTSTRAP):
	@mkdir -p $(ROOTFSDIR)
	fakeroot -i $(BUILDDIR)/rootfs.fakeroot -s $(BUILDDIR)/rootfs.fakeroot \
	  $(SCRIPTDIR)/mkdebroot -a $(ARCH) $(DEBIAN_RELEASE) $(ROOTFSDIR) $(EXTRA_DEB_URLS)

ROOTFS_STAGE2 := $(BUILDDIR)/rootfs/etc/.image_finished
rootfs_stage2: $(ROOTFS_STAGE2)
$(ROOTFS_STAGE2): $(QEMU) $(KERNEL) $(ROOTFS_BOOTSTRAP)
	fakeroot -i $(BUILDDIR)/rootfs.fakeroot -s $(BUILDDIR)/rootfs.fakeroot \
	  $(QEMU) -machine type=$(QEMU_MACH),accel=kvm:tcg -m 1024 -smp 2 \
	  -kernel $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/$(KERNEL_IMG) \
	  -fsdev local,id=r,path=$(ROOTFSDIR),security_model=passthrough \
	  -device virtio-9p-pci,fsdev=r,mount_tag=/dev/root \
	  -append "root=/dev/root rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=262144,cache=loose console=$(SERIAL_TTY),115200 panic=1 init=/debootstrap/finish" \
	  -no-reboot -nographic -monitor none
	@[ -f $(BUILDDIR)/rootfs/etc/.image_finished ] || ( \
	  echo "2nd stage build failed" >&2 ; false )

PHONY += rootfs_clean
rootfs_clean:
	rm -rf $(BUILDDIR)/rootfs*

INITRD := $(MISCDIR)/initrd
initrd: $(INITRD)
$(INITRD): $(ROOTFS_STAGE2)
	@mkdir -p $(MISCDIR)
	( cd $(ROOTFSDIR); \
	  find . | \
	  fakeroot -i $(BUILDDIR)/rootfs.fakeroot cpio -o -H newc | \
	  gzip > $(INITRD) )

PHONY += initrd_clean
initrd_clean:
	rm -f $(INITRD)

###############
# Image Targets

IMG_FILES = \
	$(INITRD) \
	$(KERNEL) \

ifeq ($(ARCH), armhf)
IMG_FILES += \
	$(KERNEL_DTB) \
	$(UBOOT) \
	$(UBOOT_ENV) \
	$(SRCDIR)/rpi/config.txt \
	$(RPIFW)

else ifeq ($(ARCH), amd64)
IMG_FILES += \

endif

RPI3_IMG := $(BUILDDIR)/rpi3image.bin
rpi3_img: $(RPI3_IMG)
$(RPI3_IMG): $(IMG_FILES) $(SCRIPTDIR)/mkfatimg
	$(SCRIPTDIR)/mkfatimg $(RPI3_IMG) 256 $(IMG_FILES)

PC_IMG := $(BUILDDIR)/pcimage.bin
pc_img: $(PC_IMG)
$(PC_IMG): $(IMG_FILES)
	$(error WRITEME rootfs install kernel)
	$(error WRITEME bootimage)

.PHONY: $(PHONY)
