# dm-dedup

简介
====

Device-mapper's dedup target provides transparent data deduplication of block devices. 
每次对dm-dedup实例的写入都会根据之前的写入进行数据重删。对于包含了很多分散在磁盘上的重复数据集（如：虚拟机的磁盘镜像集体, 备份, 主目录服务器）数据重删节省了大量空间。

指令参数
========

```
<meta_dev> <data_dev> <block_size> <hash_algo> <backend> <flushrq>
```

`<meta_dev>`
    元数据所在的设备。
    元数据通常包括散列索引、块映射和引用计数器。这里应该指定一个路径，如"/dev/sdaX"
    
`<data_dev>`
    存储实际数据的设备。
    这里应该指定一个具体路径，如"/dev/sdaX"

`<block_size>`
    数据设备上单个块的大小。
    块是进行重复数据删除和数据存储的单位。该参数范围在4096～1048576（1MB）之间，而且应该是2的幂次。

`<hash_algo>`
    指定dm-dedup用来检测相同块的算法。如 md5、sha256. 
    任何内核支持的算法都可以使用（参考 /proc/crypto 文件）

`<backend>`
    这是dm-dedup将用于存储元数据的后端。
    目前支持的值是“cowbtree”和“inram”。
	Cowbtree后端使用持久的Copy-on-Write(COW) B-Trees来存储元数据。
	Inram后端将所以元数据存储在RAM中（重启会丢失）。所以，inram 通常用于实验环境。
	注：虽然 inram 不使用元数据设备，但你依然应该在命令行中提供`<meta_dev>`参数

`<flushrq>`
    此参数指定在dm-dedup将缓冲的元数据刷新到元数据设备之前，应对目标进行多少次写入。
	In other words, in an event of power failure, one can loose up to this	number of most recent writes.  
	注意：当在I/O请求中看到`REQ_FLUSH`或`REQ_FUA`标志时，dm-dedup也会刷新其元数据。特别地，这些标志由文件系统在适当的时间点设置，以确保文件系统的一致性。
	在构建期间，dm-dedup检查元数据设备的前4096个字节是否等于零。 如果是，那么将初始化一个全新的dm-dedup实例（元数据设备和实际数据设备被认为是“Empty”）。如果这4096个起始字节不为零，dm-dedup将根据元数据和数据设备上的当前信息尝试重建目标。


操作理论
========

本节提供了dm-dedup设计的概述。 详细的设计和性能评估可以在以下论文中找到：

V. Tarasov and D. Jain and G. Kuenning and S. Mandal and K. Palanisami and P.
Shilane and S. Trehan. Dmdedup: Device Mapper Target for Data Deduplication.
Ottawa Linux Symposium, 2014.
http://www.fsl.cs.stonybrook.edu/docs/ols-dmdedup/dmdedup-ols14.pdf

为了快速识别重复项，dm-dedup为所有写入的块维护了一个散列索引。 “块”是用户可配置的进行重复数据删除和存储的单元。 Dm-dedup索引以及其他用来数据重删的元数据，存放在单独的块设备上，我们将这个块设备称为元数据设备。 实际的“块”存储在数据设备上。 虽然元数据设备可以是任何块设备，例如HDD或其分区，但是为了提高性能，我们建议使用SSD设备来存储元数据。

对于写入目标的每个块，dm-dedup使用`<hash_algo>`参数提供的算法来计算其哈希值。 然后，它在散列索引中查找生成的散列。 如果发现匹配，则写入被认为是重复的。

Dm-Dedup的散列索引本质上是`散列`和`数据设备中块的物理地址`之间的映射。 
除此，dm-dedup维护了`目标上的逻辑块地址`址和`数据设备上的物理块地址`（LBN-PBN映射）的映射。

当检测到重复时，不需要将实际数据写入到磁盘，而只需要更新LBN-PBN映射。
检测到非重复的数据时，在数据设备上分配新的物理块并写入数据，向索引中添加相应的散列。
在读取时，LBN-PBN映射允许在数据设备上快速定位所需的块。 如果以前没有写入LBN，则返回零块。


目标大小
-----------

使用设备映射时，需要提前指定目标的大小。为了更好的效果，目标大小应该大于数据设备的大小（或者直接使用数据设备）。
因为数据重删率不是预先知道的，所以必须使用估计。

通常，低于1.5的数据重删率的估计是安全的。但是对于备份数据，这个值可能高达100.
使用fs-hasher包来估计特定数据集的数据重删率是一个不错的起点。

如果超估了重复数据删除率，数据设备可能会耗尽可用空间。 可以使用dmsetup status命令（如下所述）监视这种情况。 
数据设备已满后，dm-dedup将停止接受写入，直到数据设备上的可用空间再次可用。

后端
--------

Dm-dedup的核心逻辑将索引和LDN-PBN映射当成具有外部API（drivers/md/dm-dedup-backend.h）的普通的键-值对。
不同的后端提供不同的键-值存储API。我们实现的个cowbtree后端使用设备映射的持久性元数据框架来永久存储元数据。
框架和磁盘布局的详细信息请参考：

> Documentation/device-mapper/persistent-data.txt

通过使用持久性的 COW B-Trees，cowbtree后端保证了断电情形下的一致性。

此外，我们还提供将所有元数据存储在RAM中的inram后端。
线性探测的哈希表用于存储索引和LBN-PBN映射。
Inram后端不会持久存储元数据，通常只能用于实验。

Dmsetup 状态
==============

Dm-dedup通过dmsetup status命令输出各种统计信息。由dmsetup状态返回的行将按顺序包含以下值：

```
<name> <start> <end> <type> <dtotal> <dfree> <dused> <dactual> <dblock> <ddisk> <mddisk> <writes><uniqwrites> <dupwrites> <readonwrites> <overwrites> <newwrites>
```

`<name>, <start>, <end>` 和 `<type>` 是dmsetup为任何目标都打印的通用字段。

`<dtotal>`       - 数据设备上的所有块的数目
`<dfree>`        - 数据设备上空闲（没有分配）的块数
`<dused>`        - 数据设备上已使用（已分配）的块数
`<dactual>`      - 分配的逻辑块（至少被写一次）数
`<dblock>`       - 块大小，单位 bytes
`<ddisk>`        - data disk's major:minor
`<mddisk>`       - metadata disk's major:minor
`<writes>`       - total number of writes to the target
`<uniqwrites>`   - the number of writes that weren't duplicates (were unique)
`<dupwrites>`    - the number of writes that were duplicates
`<readonwrites>` - the number of times dm-dedup had to read data from the data device because a write was misaligned (read-on-write effect)
`<overwrites>`   - the number of writes to a logical block that was written before at least once
`<newwrites>`    - the number of writes to a logical address that was not written before even once

为了计算重复数据删除率，我们需要通过dused来设置dactual。

示例
=======

设置元数据设备和数据设备：
```
# META_DEV=/dev/sdX
# DATA_DEV=/dev/sdY
```

计算目标大小，假设1.5的数据重删率：
```
# DATA_DEV_SIZE=`blockdev --getsz $DATA_DEV`
# TARGET_SIZE=`expr $DATA_DEV_SIZE \* 15 / 10`
```

重置元数据设备：
```
# dd if=/dev/zero of=$META_DEV bs=4096 count=1
```

设置目标：
```
echo "0 $TARGET_SIZE dedup $META_DEV $DATA_DEV 4096 md5 cowbtree 100" | dmsetup create mydedup
```

作者
=======
dm-dedup由`纽约州立大学石溪分校`计算机科学系的文件系统和存储实验室（FSL）与哈维·泥德学院和EMC公司合作开发。

参与该项目的主要人物有 Vasily Tarasov, Geoff Kuenning, Sonam Mandal, Karthikeyani Palanisami, Philip Shilane, Sagar Trehan, 和 Erez Zadok.

以下几名学生也帮助了该项目： Teo Asinari, Deepak Jain, Mandar Joshi, Atul Karmarkar, Meg O'Keefe, Gary Lent, Amar Mudrankit, Ujwala Tulshigiri, and Nabil Zaman.





