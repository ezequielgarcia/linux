#!/bin/bash
# Based on a test script from avsm/ocaml repo https://github.com/avsm/ocaml
#
#CHROOT_DIR=/tmp/arm-chroot
#MIRROR=http://archive.raspbian.org/raspbian
#VERSION=wheezy
#CHROOT_ARCH=armhf
#
## Debian package dependencies for the host
#HOST_DEPENDENCIES="debootstrap qemu-user-static binfmt-support sbuild"
#
## Debian package dependencies for the chrooted environment
#GUEST_DEPENDENCIES="build-essential git m4 sudo python"
#
## Command used to run the tests
#TEST_COMMAND="make test"
#
#function setup_arm_chroot {
#    # Host dependencies
#    sudo apt-get install -qq -y ${HOST_DEPENDENCIES}
#
#    # Create chrooted environment
#    sudo mkdir ${CHROOT_DIR}
#    sudo debootstrap --foreign --no-check-gpg --include=fakeroot,build-essential \
#        --arch=${CHROOT_ARCH} ${VERSION} ${CHROOT_DIR} ${MIRROR}
#    sudo cp /usr/bin/qemu-arm-static ${CHROOT_DIR}/usr/bin/
#    sudo chroot ${CHROOT_DIR} ./debootstrap/debootstrap --second-stage
#    sudo sbuild-createchroot --arch=${CHROOT_ARCH} --foreign --setup-only \
#        ${VERSION} ${CHROOT_DIR} ${MIRROR}
#
#    # Create file with environment variables which will be used inside chrooted
#    # environment
#    echo "export ARCH=${ARCH}" > envvars.sh
#    echo "export TRAVIS_BUILD_DIR=${TRAVIS_BUILD_DIR}" >> envvars.sh
#    chmod a+x envvars.sh
#
#    # Install dependencies inside chroot
#    sudo chroot ${CHROOT_DIR} apt-get update
#    sudo chroot ${CHROOT_DIR} apt-get --allow-unauthenticated install \
#        -qq -y ${GUEST_DEPENDENCIES}
#
#    # Create build dir and copy travis build files to our chroot environment
#    sudo mkdir -p ${CHROOT_DIR}/${TRAVIS_BUILD_DIR}
#    sudo rsync -av ${TRAVIS_BUILD_DIR}/ ${CHROOT_DIR}/${TRAVIS_BUILD_DIR}/
#
#    # Indicate chroot environment has been set up
#    sudo touch ${CHROOT_DIR}/.chroot_is_done
#
#    # Call ourselves again which will cause tests to run
#    sudo chroot ${CHROOT_DIR} bash -c "cd ${TRAVIS_BUILD_DIR} && ./.travis-ci.sh"
#}
#
#if [ -e "/.chroot_is_done" ]; then
#  # We are inside ARM chroot
#  echo "Running inside chrooted environment"
#
#  . ./envvars.sh
#else
#  if [ "${ARCH}" = "arm" ]; then
#    # ARM test run, need to set up chrooted environment first
#    echo "Setting up chrooted ARM environment"
#    setup_arm_chroot
#  fi
#fi
#
#echo "Running tests"
#echo "Environment: $(uname -a)"
#
#${TEST_COMMAND}

fill_rootfs()
{
	MSG=${1-""}
	# Add busybox and init script
	if [ ! -f busybox ]; then
		wget https://busybox.net/downloads/binaries/1.21.1/busybox-x86_64 -O busybox
		chmod +x busybox
	fi
	sudo mkdir dm-mount/bin
	sudo cp busybox dm-mount/bin/busybox

	sudo bash -c 'cat > dm-mount/bin/init.sh' <<- EOF
	#!/bin/busybox sh
	busybox echo "System Booted $MSG"
	busybox poweroff -f
	EOF
	sudo chmod +x dm-mount/bin/init.sh
}

# Create a simple rootfs - target linear from 4 joined partitions
create_linear()
{
	# Create 1g disk
	DISK=$1
	PREFIX=$2
	DM_DEV=dm-linear
	if [ -f $DISK -a -f ${DISK}.info ]; then
		echo "$DISK already exist, not creating it"
		return
	else
		echo "creating $DISK"
	fi

	dd if=/dev/zero of=$DISK bs=512M count=2
	# Partition 1 - bootable
	sudo sgdisk -n 1:0:+16M -t 1:7f00 "$DISK"
	# Partition 2
	sudo sgdisk -n 2:0:+500M -t 2:7f01 "$DISK"
	# Partition 3
	sudo sgdisk -n 3:0:+100M -t 3:7f01 "$DISK"
	# Partition 4
	sudo sgdisk -n 4:0:+250M -t 4:7f01 "$DISK"

	# Create linear device
	LOOP_DEV=$(sudo losetup -fP --show $DISK)
	S1=$(sudo blockdev --getsz ${LOOP_DEV}p1)
	S2=$(sudo blockdev --getsz ${LOOP_DEV}p2)
	S3=$(sudo blockdev --getsz ${LOOP_DEV}p3)
	S4=$(sudo blockdev --getsz ${LOOP_DEV}p4)

	bash -c "cat > ${DISK}.info" <<- EOF
	P1_START=0
	P1_SIZE=$S1
	P2_START=$S1
	P2_SIZE=$S2
	P3_START=$(($S1 + $S2))
	P3_SIZE=$S3
	P4_START=$(($S1 + $S2 + $S3))
	P4_SIZE=$S4
	EOF

	source ${DISK}.info

	# Add prefix to variables in file
	sed -i -e "s/^/$PREFIX/" ${DISK}.info

	table="$P1_START $P1_SIZE linear ${LOOP_DEV}p1 0
	$P2_START $P2_SIZE linear ${LOOP_DEV}p2 0
	$P3_START $P3_SIZE linear ${LOOP_DEV}p3 0
	$P4_START $P4_SIZE linear ${LOOP_DEV}p4 0"
	echo "$table" | sudo dmsetup create $DM_DEV

	echo "concise table (with loopback device)"
	sudo dmsetup table --concise /dev/mapper/$DM_DEV

	# Format
	sudo mkfs.ext4 -L ROOT-LINEAR /dev/mapper/$DM_DEV
	mkdir -p dm-mount
	sudo mount /dev/mapper/$DM_DEV dm-mount

	fill_rootfs  "linear disk $DISK"

	# Umount disk/dm/loopback
	sudo umount dm-mount
	rm -r dm-mount
	sudo dmsetup remove $DM_DEV
	sudo losetup -d $LOOP_DEV
}

make x86_64_defconfig
make

create_linear disk-linear-1.img DL1_
source disk-linear-1.info

./vmlinux ubda=./disk-linear-1.img root=/dev/dm-4 dm-mod.create=\"dm-linear,,4,rw,0 32768 linear 98:1 0,32768 1024000 linear 98:2 0,1056768 204800 linear 98:3 0,1261568 512000 linear 98:4 0\" init=/bin/init.sh
