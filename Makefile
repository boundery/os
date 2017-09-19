######################################################
# Setup some high-level global settings.

#XXX Need targets for checking for debian and kernel security vulns, respin image.

#XXX Add support for (cross) building patched upstream, patched tar.gz, and
#    and local git trees.  Perhaps a list of things to build in ../?
#XXX Do we even need to cross build anything other than containers?  How
#    valuable is the seperation between build env and run env provided by .deb?

#XXX Check signatures for HTTP downloads!

DEBIAN_RELEASE := stretch

KERNEL_URL=http://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.9.47.tar.xz
QEMU_URL=http://download.qemu-project.org/qemu-2.10.0.tar.xz
UBOOT_URL=ftp://ftp.denx.de/pub/u-boot/u-boot-2017.09.tar.bz2

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
UBOOTDIR := $(BUILDDIR)/uboot
QEMUDIR := $(BUILDDIR)/qemu

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
	  $(KERNEL_IMG) $(KERNEL_EXTRAS) )

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

endif

ROOTFS_STAGE1 := $(ROOTFSDIR)/etc/apt/sources.list
rootfs_stage1: $(ROOTFS_STAGE1)
$(ROOTFS_STAGE1):
	@mkdir -p $(ROOTFSDIR)
	fakeroot -i $(BUILDDIR)/rootfs.fakeroot -s $(BUILDDIR)/rootfs.fakeroot \
	  $(SCRIPTDIR)/mkdebroot -a $(ARCH) $(DEBIAN_RELEASE) $(ROOTFSDIR)

ROOTFS_STAGE2 := $(BUILDDIR)/rootfs/etc/.image_finished
rootfs_stage2: $(ROOTFS_STAGE2)
$(ROOTFS_STAGE2): $(ROOTFS_STAGE1) $(QEMU) $(KERNEL)
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

###############
# Image Targets

RPI3_IMG := $(BUILDDIR)/rpi3image.bin
rpi3_img: $(RPI3_IMG)
$(RPI3_IMG): $(UBOOT) $(ROOTFS_STAGE2) $(KERNEL)
	$(error WRITEME rootfs install kernel modules)
	$(error WRITEME bootimage) #XXX Put "enable_uart=1" in config.txt for pi3

PC_IMG := $(BUILDDIR)/pcimage.bin
pc_img: $(PC_IMG)
$(PC_IMG): $(ROOTFS_STAGE2) $(KERNEL)
	$(error WRITEME rootfs install kernel + modules)
	$(error WRITEME bootimage)

.PHONY: $(PHONY)
