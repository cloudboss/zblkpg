//! A library to call Linux blkpg ioctls.
//!
//! Note: only the `BLKPG_RESIZE_PARTITION` operation is implemented.

const std = @import("std");
const linux = std.os.linux;

const BLKPG = 0x1269;
const BLKPG_RESIZE_PARTITION: c_int = 3;

/// Ioctl argument structure for blkpg operations.
/// Corresponds to `struct blkpg_ioctl_arg` in linux/blkpg.h.
const BlkpgIoctlArg = extern struct {
    op: c_int,
    flags: c_int,
    datalen: c_int,
    data: *const anyopaque,
};

/// Partition information structure.
/// Corresponds to `struct blkpg_partition` in linux/blkpg.h.
const BlkpgPartition = extern struct {
    start: c_longlong,
    length: c_longlong,
    pno: c_int,
    devname: [64]u8,
    volname: [64]u8,
};

pub const ResizeError = error{
    /// Access to the device was denied.
    AccessDenied,
    /// The file descriptor is not valid or not open for writing.
    InvalidFileDescriptor,
    /// Invalid argument (e.g., partition number, start, or length).
    InvalidArgument,
    /// The partition does not exist.
    NoSuchPartition,
    /// The device does not support this operation.
    NotSupported,
    /// An unexpected error occurred.
    Unexpected,
};

/// Resizes a partition while it is mounted.
///
/// This calls the blkpg ioctl with the `BLKPG_RESIZE_PARTITION` operation,
/// which enables resizing a partition without unmounting it.
///
/// Parameters:
/// - `fd`: The open file descriptor of the disk device (e.g., /dev/nvme0n1).
/// - `part_num`: The number of the partition to be modified.
/// - `start_sector`: The start sector of the partition.
/// - `end_sector`: The end sector of the partition.
/// - `sector_size`: The size of the sectors in bytes.
///
/// Example:
/// ```
/// const std = @import("std");
/// const zblkpg = @import("zblkpg");
///
/// pub fn main() !void {
///     const file = try std.fs.openFileAbsolute("/dev/nvme0n1", .{ .mode = .read_write });
///     defer file.close();
///     try zblkpg.resizePartition(file.handle, 2, 456, 789, 512);
/// }
/// ```
pub fn resizePartition(
    fd: std.posix.fd_t,
    part_num: i32,
    start_sector: i64,
    end_sector: i64,
    sector_size: i64,
) ResizeError!void {
    const partition = BlkpgPartition{
        .start = start_sector * sector_size,
        .length = (end_sector - start_sector) * sector_size,
        .pno = part_num,
        .devname = [_]u8{0} ** 64,
        .volname = [_]u8{0} ** 64,
    };

    const arg = BlkpgIoctlArg{
        .op = BLKPG_RESIZE_PARTITION,
        .flags = 0,
        .datalen = 0, // Ignored by kernel; it uses sizeof(struct blkpg_partition).
        .data = &partition,
    };

    const result = linux.ioctl(fd, BLKPG, @intFromPtr(&arg));
    if (result != 0) {
        const err = std.posix.errno(result);
        return switch (err) {
            .ACCES => error.AccessDenied,
            .BADF => error.InvalidFileDescriptor,
            .INVAL => error.InvalidArgument,
            .NXIO, .NOENT => error.NoSuchPartition,
            .NOTTY => error.NotSupported,
            else => error.Unexpected,
        };
    }
}

test "BlkpgPartition has correct size" {
    // struct blkpg_partition is 152 bytes on Linux
    try std.testing.expectEqual(152, @sizeOf(BlkpgPartition));
}

test "BlkpgIoctlArg has correct size" {
    // struct blkpg_ioctl_arg is 24 bytes on 64-bit Linux (with padding)
    try std.testing.expectEqual(24, @sizeOf(BlkpgIoctlArg));
}
