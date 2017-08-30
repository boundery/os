#!/bin/bash

#XXX This should add a changelog entry and add a ~WHATEVER1 to the version..

mkdir build
cd build

#XXX Needs fakeroot.
patch_and_build () {
    apt-get download $1
    mkdir $1
    dpkg-deb -R $1_*.deb $1

    #XXX Do we need to decross versions? all versions?
    #Decross the package name, dependencies and versions.
    sed -i 's/-arm-linux-gnueabihf//g' $1/DEBIAN/control
    sed -i 's/-armhf-cross//g' $1/DEBIAN/control
    sed -i 's/-cross-base/-base/g' $1/DEBIAN/control
    sed -i -E 's/cross[0-9]+//g' $1/DEBIAN/control

    #Change the arch
    sed -i 's/Architecture: amd64/Architecture: armhf/g' $1/DEBIAN/control

    #Symlink the non-cross bin names to the cross names.
    if [ -d $1/usr/bin ]; then
        for i in $1/usr/bin/*; do
            ln -sfr $i `echo $i | sed 's/arm-linux-gnueabihf-//g'`
        done
    fi

    #Merge the cross stuff with the host stuff, and leave a symlink back.
    if [ -d $1/usr/lib/gcc-cross/arm-linux-gnueabihf ]; then
        mkdir -p $1/usr/lib/gcc/
        mv $1/usr/lib/gcc-cross/arm-linux-gnueabihf $1/usr/lib/gcc/
        if [ $1 == gcc-6-arm-linux-gnueabihf ]; then
            ln -sfr $1/usr/lib/gcc/arm-linux-gnueabihf $1/usr/lib/gcc-cross/
        fi
    fi

    dpkg-deb -b $1 $1_*.deb
}

patch_and_build binutils-arm-linux-gnueabihf

patch_and_build cpp-arm-linux-gnueabihf
patch_and_build cpp-6-arm-linux-gnueabihf

patch_and_build gcc-arm-linux-gnueabihf
patch_and_build gcc-6-arm-linux-gnueabihf
patch_and_build gcc-6-arm-linux-gnueabihf-base
patch_and_build gcc-6-cross-base
