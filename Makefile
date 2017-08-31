######################################################
# Setup some high-level global settings.

#XXX Need targets for checking for debian/kernel security vulns, respin image.

#XXX Add support for (cross) building patched upstream, patched tar.gz, and
#    and local git trees.  Perhaps a list of things to build in ../?
#XXX Do we even need to cross build anything other than containers?  How
#    valuable is the seperation between build env and run env provided by .deb?

DEBIAN_RELEASE := stretch
KERNEL_VER := v4.9 #Stretch kernel.

KERNEL_GIT=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux-2.6.git

######################################################
# Pick/validate what target architectures we're building for.

#If we're building a specific image, automatically set the ARCH based on that.
ARCHS := #Needed so ARCHS+=$(ARCH) expands $(ARCH) immediately, not recursively.
ARM_TARGETS:=rpi2_img chip_img
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
KERNEL_ARCH=arm
#CROSS_PREFIX=arm-none-eabi-
CROSS_PREFIX=arm-linux-gnueabihf-
else ifeq ($(ARCH), amd64)
QEMU_ARCH=x86_64
KERNEL_ARCH=x86
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
export https_proxy=http://$(PROXY_IP):$(PROXY_PORT)
endif

test_cache:
	@printenv | egrep '^http[s]?_proxy='

#########################
# Setup some directories.

SRCDIR := $(realpath $(CURDIR))
SCRIPTDIR := $(SRCDIR)/script
KCONFIGDIR := $(SRCDIR)/kconfig

BUILDDIR := $(SRCDIR)/build/$(ARCH)
ROOTFSDIR := $(BUILDDIR)/rootfs
KERNELDIR := $(BUILDDIR)/linux

###########################
#Validate some assumptions.

#XXX Make sure the CROSS_PREFIX (or native) toolchain exists.
#XXX new enough qemu, cross tools, etc.

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
	@mkdir -p $(BUILDDIR)
	#XXX Just pull the .tar.xz from kernel.org?  It is smaller...
	git clone --branch=$(KERNEL_VER) --depth=1 $(KERNEL_GIT) $(KERNELDIR)

KERNEL_PATCH := $(KERNELDIR)/.config
kernel_patch: $(KERNEL_PATCH)
$(KERNEL_PATCH): $(KERNEL_SRC)
	cp $(KCONFIGDIR)/$(ARCH)_kconfig $(KERNELDIR)/.config

KERNEL := $(KERNELDIR)/arch/$(KERNEL_ARCH)/boot/zImage
kernel: $(KERNEL)
$(KERNEL): $(KERNEL_PATCH)
	( cd $(KERNELDIR); make ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(CROSS_PREFIX) zImage dtbs )

ROOTFS_STAGE1 := $(ROOTFSDIR)/etc/apt/sources.list
rootfs_stage1: $(ROOTFS_STAGE1)
$(ROOTFS_STAGE1):
	@mkdir -p $(ROOTFSDIR)
	fakeroot -i $(BUILDDIR)/rootfs.fakeroot -s $(BUILDDIR)/rootfs.fakeroot \
	  $(SCRIPTDIR)/mkdebroot -a $(ARCH) $(DEBIAN_RELEASE) $(ROOTFSDIR)

ROOTFS_STAGE2 := $(BUILDDIR)/rootfs/etc/.image_finished
rootfs_stage2: $(ROOTFS_STAGE2)
$(ROOTFS_STAGE2): $(ROOTFS_STAGE1) $(KERNEL)
	fakeroot -i $(BUILDDIR)/rootfs.fakeroot -s $(BUILDDIR)/rootfs.fakeroot \
	  qemu-system-arm -M virt -kernel $(KERNELDIR)/arch/arm/boot/zImage \
	  -fsdev local,id=r,path=$(ROOTFSDIR),security_model=passthrough \
	  -device virtio-9p-pci,fsdev=r,mount_tag=/dev/root \
	  -append "root=/dev/root rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=262144 console=ttyAMA0,115200 panic=1 init=/debootstrap/finish" \
	  -no-reboot -nographic -monitor none

###############
# Image Targets

RPI2_IMG := $(BUILDDIR)/rpi2image.bin
rpi2_img: $(RPI2_IMG)
$(RPI2_IMG): $(ROOTFS_STAGE2)
	$(error WRITEME rootfs install kernel modules)
	$(error WRITEME bootimage) #XXX Put "enable_uart=1" in config.txt for pi3

PC_IMG := $(BUILDDIR)/pcimage.bin
pc_img: $(PC_IMG)
$(PC_IMG): $(ROOTFS_STAGE2) $(KERNEL)
	$(error WRITEME rootfs install kernel + modules)
	$(error WRITEME bootimage)

.PHONY: $(PHONY)
