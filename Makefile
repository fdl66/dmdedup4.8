obj-m += dm-dedup.o
PWD=/home/dear/code/dmdedup4.8.5
dm-dedup-objs := dm-dedup-cbt.o dm-dedup-hash.o dm-dedup-ram.o  dm-dedup-rw.o dm-dedup-target.o


N_SIZE= 1024
G1G= $(shell expr 1024 \* 1024 \* 1024 ) 
M1M= $(shell expr 1024 \* 1024 )
BUFSIZE= $(shell expr ${MIM} \* ${N_SIZE})



EXTRA_CFLAGS := -Idrivers/md

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
	./ins_bufio_mod.sh $(shell expr 2 \* 1024 \* 1024 \* 1024 )
	modprobe dm_persistent_data
	insmod dm-dedup.ko
	dmesg -c >> dmdedup.log
	./dmdedup.sh
	dmesg -c >> dmdedup.log
	mkfs.ext4 /dev/mapper/mydedup
	dmesg -c >> dmdedup.log
	mount /dev/mapper/mydedup /mnt
	dmesg -c >> dmdedup.log
	sync /dev/mapper/mydedup
	dmesg -c >> dmdedup.log
	
clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
	rm -rf dmdedup.log
	umount /mnt
	dmsetup remove mydedup
	rmmod dm-dedup
	rmmod dm_persistent_data
	rmmod dm_bufio
