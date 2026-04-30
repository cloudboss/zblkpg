//! Integration tests for zblkpg.
//!
//! These tests require root privileges to resize partitions.
//! Run with: sudo zig build test-integration

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;
const zblkpg = @import("zblkpg");
const zgpt = @import("zgpt");

const SECTOR_SIZE: u32 = 512;

/// Check if running as root
fn isRoot() bool {
    return linux.getuid() == 0;
}

/// Run a shell command and return stdout
fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("Command failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.CommandFailed;
    }

    return result.stdout;
}

/// Run a shell command, ignoring output
fn runCommandIgnoreOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !void {
    const stdout = try runCommand(allocator, io, argv);
    allocator.free(stdout);
}

/// Partition specification for createTestImageMulti
const PartitionSpec = struct {
    size_sectors: u64,
    name: []const u8,
};

/// Create a disk image with a GPT partition table and multiple partitions
fn createTestImageMulti(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    size_mb: u32,
    partitions: []const PartitionSpec,
) !void {
    // Create sparse file
    const size_str = try std.fmt.allocPrint(allocator, "{d}M", .{size_mb});
    defer allocator.free(size_str);
    try runCommandIgnoreOutput(allocator, io, &.{ "truncate", "-s", size_str, path });

    // Open the file and create GPT table
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const file_stat = try file.stat(io);
    const device_size = file_stat.size;
    const total_sectors = device_size / SECTOR_SIZE;

    // GPT layout constants
    const partition_entries_sectors: u64 = 32; // 128 entries * 128 bytes / 512
    const first_usable_lba: u64 = 1 + 1 + partition_entries_sectors; // MBR + Header + Entries = 34
    const backup_header_lba: u64 = total_sectors - 1;
    const backup_entries_lba: u64 = backup_header_lba - partition_entries_sectors;
    const last_usable_lba: u64 = backup_entries_lba - 1;

    // Create and initialize the GPT header
    var header = zgpt.gpt.GptHeader.init();
    header.my_lba = std.mem.nativeToLittle(u64, zgpt.gpt.GPT_PRIMARY_PARTITION_TABLE_LBA);
    header.alternate_lba = std.mem.nativeToLittle(u64, backup_header_lba);
    header.first_usable_lba = std.mem.nativeToLittle(u64, first_usable_lba);
    header.last_usable_lba = std.mem.nativeToLittle(u64, last_usable_lba);
    header.partition_entry_lba = std.mem.nativeToLittle(u64, 2);
    header.disk_guid = zgpt.gpt.Guid.random();

    // Create partition entries
    const num_entries = zgpt.gpt.GPT_NPARTITIONS_DEFAULT;
    var entries = try allocator.alloc(zgpt.gpt.GptEntry, num_entries);
    defer allocator.free(entries);
    @memset(std.mem.sliceAsBytes(entries), 0);

    // Set up partitions
    var current_lba: u64 = first_usable_lba;
    for (partitions, 0..) |part, i| {
        const partition_end: u64 = current_lba + part.size_sectors - 1;
        entries[i].type_guid = try zgpt.gpt.PartitionType.linux_filesystem.toGuid();
        entries[i].partition_guid = zgpt.gpt.Guid.random();
        entries[i].setLbaRange(current_lba, partition_end);
        try entries[i].setName(part.name);
        current_lba = partition_end + 1;
    }

    // Calculate CRC32 for partition entries
    const entries_size = num_entries * @sizeOf(zgpt.gpt.GptEntry);
    const entries_crc = std.hash.Crc32.hash(std.mem.sliceAsBytes(entries)[0..entries_size]);
    header.partition_entry_array_crc32 = std.mem.nativeToLittle(u32, entries_crc);

    // Calculate CRC32 for header
    header.header_crc32 = 0;
    const header_crc = std.hash.Crc32.hash(std.mem.asBytes(&header)[0..zgpt.gpt.GPT_HEADER_MINSZ]);
    header.header_crc32 = std.mem.nativeToLittle(u32, header_crc);

    // Write protective MBR
    const mbr = zgpt.gpt.createProtectiveMbr(total_sectors);
    try file.writePositionalAll(io, &mbr, 0);

    // Write primary GPT header at sector 1
    var header_sector: [512]u8 = [_]u8{0} ** 512;
    @memcpy(header_sector[0..@sizeOf(zgpt.gpt.GptHeader)], std.mem.asBytes(&header));
    try file.writePositionalAll(io, &header_sector, SECTOR_SIZE);

    // Write partition entries starting at sector 2
    try file.writePositionalAll(io, std.mem.sliceAsBytes(entries), 2 * SECTOR_SIZE);

    // Write backup partition entries
    try file.writePositionalAll(
        io,
        std.mem.sliceAsBytes(entries),
        backup_entries_lba * SECTOR_SIZE,
    );

    // Write backup GPT header
    var backup_header = header;
    backup_header.my_lba = std.mem.nativeToLittle(u64, backup_header_lba);
    backup_header.alternate_lba = std.mem.nativeToLittle(
        u64,
        zgpt.gpt.GPT_PRIMARY_PARTITION_TABLE_LBA,
    );
    backup_header.partition_entry_lba = std.mem.nativeToLittle(u64, backup_entries_lba);
    backup_header.header_crc32 = 0;
    const backup_header_crc = std.hash.Crc32.hash(
        std.mem.asBytes(&backup_header)[0..zgpt.gpt.GPT_HEADER_MINSZ],
    );
    backup_header.header_crc32 = std.mem.nativeToLittle(u32, backup_header_crc);

    @memset(&header_sector, 0);
    @memcpy(header_sector[0..@sizeOf(zgpt.gpt.GptHeader)], std.mem.asBytes(&backup_header));
    try file.writePositionalAll(io, &header_sector, backup_header_lba * SECTOR_SIZE);

    try file.sync(io);
}

/// Create a disk image with a GPT partition table and one partition
fn createTestImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    size_mb: u32,
    partition_size_sectors: u64,
) !void {
    try createTestImageMulti(allocator, io, path, size_mb, &.{
        .{ .size_sectors = partition_size_sectors, .name = "TestPart" },
    });
}

/// Set up a loop device using losetup (requires root)
fn setupLoopDevice(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]const u8 {
    const stdout = try runCommand(
        allocator,
        io,
        &.{ "losetup", "--find", "--show", "--partscan", image_path },
    );
    const loop_dev = std.mem.trimEnd(u8, stdout, "\n");
    const result = try allocator.dupe(u8, loop_dev);
    allocator.free(stdout);
    return result;
}

/// Set up a loop device with specific sector size
fn setupLoopDeviceWithSectorSize(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    sector_size: u32,
) ![]const u8 {
    const sector_size_str = try std.fmt.allocPrint(allocator, "{d}", .{sector_size});
    defer allocator.free(sector_size_str);
    const stdout = try runCommand(
        allocator,
        io,
        &.{
            "losetup",
            "--find",
            "--show",
            "--partscan",
            "--sector-size",
            sector_size_str,
            image_path,
        },
    );
    const loop_dev = std.mem.trimEnd(u8, stdout, "\n");
    const result = try allocator.dupe(u8, loop_dev);
    allocator.free(stdout);
    return result;
}

/// Detach a loop device
fn detachLoopDevice(allocator: std.mem.Allocator, io: std.Io, loop_dev: []const u8) void {
    runCommandIgnoreOutput(allocator, io, &.{ "losetup", "--detach", loop_dev }) catch {};
}

/// Get the size of a partition in sectors by reading from sysfs
fn getPartitionSizeSectors(
    allocator: std.mem.Allocator,
    io: std.Io,
    loop_dev: []const u8,
    part_num: u32,
) !?u64 {
    const loop_name = std.fs.path.basename(loop_dev);

    var path_buf: [128]u8 = undefined;
    const sysfs_path = try std.fmt.bufPrint(
        &path_buf,
        "/sys/block/{s}/{s}p{d}/size",
        .{ loop_name, loop_name, part_num },
    );

    const size_str = std.Io.Dir.cwd().readFileAlloc(
        io,
        sysfs_path,
        allocator,
        .limited(64),
    ) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(size_str);

    const trimmed = std.mem.trimEnd(u8, size_str, "\n");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

/// Get partition start sector from sysfs
fn getPartitionStartSector(
    allocator: std.mem.Allocator,
    io: std.Io,
    loop_dev: []const u8,
    part_num: u32,
) !?u64 {
    const loop_name = std.fs.path.basename(loop_dev);

    var path_buf: [128]u8 = undefined;
    const sysfs_path = try std.fmt.bufPrint(
        &path_buf,
        "/sys/block/{s}/{s}p{d}/start",
        .{ loop_name, loop_name, part_num },
    );

    const start_str = std.Io.Dir.cwd().readFileAlloc(
        io,
        sysfs_path,
        allocator,
        .limited(64),
    ) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(start_str);

    const trimmed = std.mem.trimEnd(u8, start_str, "\n");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

/// Resize partition in GPT using zgpt
fn resizePartitionInGpt(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: []const u8,
    partition_num: u32,
    new_size_sectors: u64,
) !void {
    var ctx = try zgpt.GptContext.init(allocator, io, device);
    defer ctx.deinit();

    try ctx.load();

    const entry = ctx.getPartition(partition_num) orelse return error.PartitionNotFound;
    const start = entry.getStartLba();
    entry.setSize(start, new_size_sectors);

    try ctx.save();
}

/// Helper to get partition info from GPT
fn getPartitionInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    device: []const u8,
    partition_num: u32,
) !struct { start: u64, size: u64 } {
    var ctx = try zgpt.GptContext.init(allocator, io, device);
    defer ctx.deinit();
    try ctx.load();
    const entry = ctx.getPartition(partition_num) orelse return error.PartitionNotFound;
    return .{ .start = entry.getStartLba(), .size = entry.getSize() };
}

fn settle(io: std.Io) !void {
    try std.Io.sleep(io, .fromMilliseconds(500), .awake);
}

// ============================================================================
// Basic Tests
// ============================================================================

test "integration: resize partition on loop device" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/resize_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    const initial_partition_sectors: u64 = 10240;
    try createTestImage(allocator, io, image_path, 20, initial_partition_sectors);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const initial_size = try getPartitionSizeSectors(allocator, io, loop_dev, 1) orelse {
        std.debug.print("Partition 1 not found in sysfs\n", .{});
        return error.PartitionNotFound;
    };
    try testing.expectEqual(initial_partition_sectors, initial_size);

    const new_size_sectors: u64 = 20480;
    try resizePartitionInGpt(allocator, io, loop_dev, 1, new_size_sectors);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const info = try getPartitionInfo(allocator, io, loop_dev, 1);
    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(info.start),
        @intCast(info.start + new_size_sectors),
        SECTOR_SIZE,
    );

    const new_size = try getPartitionSizeSectors(allocator, io, loop_dev, 1) orelse {
        return error.PartitionNotFound;
    };
    try testing.expectEqual(new_size_sectors, new_size);
}

test "integration: resize non-existent partition fails" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/error_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 10, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const result = zblkpg.resizePartition(loop_file.handle, 99, 0, 1000, 512);
    try testing.expectError(error.NoSuchPartition, result);
}

test "resize with invalid file descriptor" {
    const result = zblkpg.resizePartition(-1, 1, 0, 1000, 512);
    try testing.expectError(error.InvalidFileDescriptor, result);
}

// ============================================================================
// Error Case Tests
// ============================================================================

test "integration: resize with read-only fd succeeds" {
    // Note: Linux BLKPG_RESIZE_PARTITION ioctl does not require write access
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/readonly_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 20, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    // First resize in GPT (needs write access to update GPT)
    const new_size: u64 = 20480;
    try resizePartitionInGpt(allocator, io, loop_dev, 1, new_size);

    // Open read-only for the blkpg ioctl
    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_only });
    defer loop_file.close(io);

    const info = try getPartitionInfo(allocator, io, loop_dev, 1);
    // This should succeed - BLKPG doesn't require write access
    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(info.start),
        @intCast(info.start + new_size),
        SECTOR_SIZE,
    );

    const actual_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(new_size, actual_size);
}

test "integration: resize on regular file fails with NotSupported" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const file_path = "zig-cache/test-images/regular_file.img";
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    // Create a regular file
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);

    try file.writePositionalAll(io, &[_]u8{0} ** 4096, 0);

    const result = zblkpg.resizePartition(file.handle, 1, 0, 1000, 512);
    try testing.expectError(error.NotSupported, result);
}

test "resize with partition number 0 fails" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/partnum0_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 10, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const result = zblkpg.resizePartition(loop_file.handle, 0, 34, 10274, 512);
    try testing.expectError(error.InvalidArgument, result);
}

test "resize with negative partition number fails" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/partneg_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 10, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const result = zblkpg.resizePartition(loop_file.handle, -1, 34, 10274, 512);
    try testing.expectError(error.InvalidArgument, result);
}

test "resize with end before start fails" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/endbeforestart_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 10, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    // end_sector (100) < start_sector (1000) -> negative length
    const result = zblkpg.resizePartition(loop_file.handle, 1, 1000, 100, 512);
    try testing.expectError(error.InvalidArgument, result);
}

test "resize with zero length fails" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/zerolength_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 10, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    // start == end -> zero length
    const result = zblkpg.resizePartition(loop_file.handle, 1, 34, 34, 512);
    try testing.expectError(error.InvalidArgument, result);
}

// ============================================================================
// Happy Path Variation Tests
// ============================================================================

test "integration: shrink partition" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/shrink_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    // Start with a 10MB partition (20480 sectors)
    const initial_partition_sectors: u64 = 20480;
    try createTestImage(allocator, io, image_path, 20, initial_partition_sectors);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const initial_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(initial_partition_sectors, initial_size);

    // Shrink to 5MB (10240 sectors)
    const new_size_sectors: u64 = 10240;
    try resizePartitionInGpt(allocator, io, loop_dev, 1, new_size_sectors);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const info = try getPartitionInfo(allocator, io, loop_dev, 1);
    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(info.start),
        @intCast(info.start + new_size_sectors),
        SECTOR_SIZE,
    );

    const new_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(new_size_sectors, new_size);
}

test "integration: multiple resize operations in sequence" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/multi_resize_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 30, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    // Resize sequence: 10240 -> 20480 -> 15360 -> 30720
    const sizes = [_]u64{ 20480, 15360, 30720 };

    for (sizes) |new_size| {
        try resizePartitionInGpt(allocator, io, loop_dev, 1, new_size);
        const info = try getPartitionInfo(allocator, io, loop_dev, 1);
        try zblkpg.resizePartition(
            loop_file.handle,
            1,
            @intCast(info.start),
            @intCast(info.start + new_size),
            SECTOR_SIZE,
        );

        const actual_size = try getPartitionSizeSectors(
            allocator,
            io,
            loop_dev,
            1,
        ) orelse return error.PartitionNotFound;
        try testing.expectEqual(new_size, actual_size);
    }
}

test "integration: resize to maximum available space" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/maxsize_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    try createTestImage(allocator, io, image_path, 20, 10240);

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    // Read GPT to find the maximum usable size
    var ctx = try zgpt.GptContext.init(allocator, io, loop_dev);
    defer ctx.deinit();
    try ctx.load();

    const header = ctx.primary_header orelse return error.NoHeader;
    const first_usable = header.getFirstUsableLba();
    const last_usable = header.getLastUsableLba();
    const max_size = last_usable - first_usable + 1;

    // Resize partition to max
    try resizePartitionInGpt(allocator, io, loop_dev, 1, max_size);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const info = try getPartitionInfo(allocator, io, loop_dev, 1);
    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(info.start),
        @intCast(info.start + max_size),
        SECTOR_SIZE,
    );

    const actual_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(max_size, actual_size);
}

/// Create a disk image with GPT for 4K sectors
fn createTestImage4K(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    size_mb: u32,
    partition_size_4k_sectors: u64,
) !void {
    const sector_size: u32 = 4096;

    // Create sparse file
    const size_str = try std.fmt.allocPrint(allocator, "{d}M", .{size_mb});
    defer allocator.free(size_str);
    try runCommandIgnoreOutput(allocator, io, &.{ "truncate", "-s", size_str, path });

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const file_stat = try file.stat(io);
    const device_size = file_stat.size;
    const total_sectors = device_size / sector_size;

    // GPT layout for 4K sectors (fewer sectors needed for entries)
    // 128 entries * 128 bytes = 16384 bytes = 4 sectors at 4K
    const partition_entries_sectors: u64 = 4;
    const first_usable_lba: u64 = 1 + 1 + partition_entries_sectors; // MBR + Header + Entries = 6
    const backup_header_lba: u64 = total_sectors - 1;
    const backup_entries_lba: u64 = backup_header_lba - partition_entries_sectors;
    const last_usable_lba: u64 = backup_entries_lba - 1;

    var header = zgpt.gpt.GptHeader.init();
    header.my_lba = std.mem.nativeToLittle(u64, zgpt.gpt.GPT_PRIMARY_PARTITION_TABLE_LBA);
    header.alternate_lba = std.mem.nativeToLittle(u64, backup_header_lba);
    header.first_usable_lba = std.mem.nativeToLittle(u64, first_usable_lba);
    header.last_usable_lba = std.mem.nativeToLittle(u64, last_usable_lba);
    header.partition_entry_lba = std.mem.nativeToLittle(u64, 2);
    header.disk_guid = zgpt.gpt.Guid.random();

    const num_entries = zgpt.gpt.GPT_NPARTITIONS_DEFAULT;
    var entries = try allocator.alloc(zgpt.gpt.GptEntry, num_entries);
    defer allocator.free(entries);
    @memset(std.mem.sliceAsBytes(entries), 0);

    const partition_start: u64 = first_usable_lba;
    const partition_end: u64 = partition_start + partition_size_4k_sectors - 1;

    entries[0].type_guid = try zgpt.gpt.PartitionType.linux_filesystem.toGuid();
    entries[0].partition_guid = zgpt.gpt.Guid.random();
    entries[0].setLbaRange(partition_start, partition_end);
    try entries[0].setName("TestPart4K");

    const entries_size = num_entries * @sizeOf(zgpt.gpt.GptEntry);
    const entries_crc = std.hash.Crc32.hash(std.mem.sliceAsBytes(entries)[0..entries_size]);
    header.partition_entry_array_crc32 = std.mem.nativeToLittle(u32, entries_crc);

    header.header_crc32 = 0;
    const header_crc = std.hash.Crc32.hash(std.mem.asBytes(&header)[0..zgpt.gpt.GPT_HEADER_MINSZ]);
    header.header_crc32 = std.mem.nativeToLittle(u32, header_crc);

    // Write protective MBR (sector 0, 4K) - MBR is 512 bytes, pad rest of 4K sector
    const mbr_data = zgpt.gpt.createProtectiveMbr(total_sectors);
    var mbr_sector: [4096]u8 = [_]u8{0} ** 4096;
    @memcpy(mbr_sector[0..512], &mbr_data);
    try file.writePositionalAll(io, &mbr_sector, 0);

    // Write primary GPT header at sector 1
    var header_sector: [4096]u8 = [_]u8{0} ** 4096;
    @memcpy(header_sector[0..@sizeOf(zgpt.gpt.GptHeader)], std.mem.asBytes(&header));
    try file.writePositionalAll(io, &header_sector, sector_size);

    // Write partition entries starting at sector 2
    try file.writePositionalAll(io, std.mem.sliceAsBytes(entries), 2 * sector_size);

    // Write backup partition entries
    try file.writePositionalAll(
        io,
        std.mem.sliceAsBytes(entries),
        backup_entries_lba * sector_size,
    );

    // Write backup GPT header
    var backup_header = header;
    backup_header.my_lba = std.mem.nativeToLittle(u64, backup_header_lba);
    backup_header.alternate_lba = std.mem.nativeToLittle(
        u64,
        zgpt.gpt.GPT_PRIMARY_PARTITION_TABLE_LBA,
    );
    backup_header.partition_entry_lba = std.mem.nativeToLittle(u64, backup_entries_lba);
    backup_header.header_crc32 = 0;
    const backup_header_crc = std.hash.Crc32.hash(
        std.mem.asBytes(&backup_header)[0..zgpt.gpt.GPT_HEADER_MINSZ],
    );
    backup_header.header_crc32 = std.mem.nativeToLittle(u32, backup_header_crc);

    @memset(&header_sector, 0);
    @memcpy(header_sector[0..@sizeOf(zgpt.gpt.GptHeader)], std.mem.asBytes(&backup_header));
    try file.writePositionalAll(io, &header_sector, backup_header_lba * sector_size);

    try file.sync(io);
}

test "integration: resize with 4096-byte sectors" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/sector4k_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    // Create image with proper 4K sector GPT layout
    // 1280 4K sectors = 5MB = 10240 512-byte sectors (sysfs always reports in 512-byte sectors)
    const initial_4k_sectors: u64 = 1280;
    try createTestImage4K(allocator, io, image_path, 20, initial_4k_sectors);

    // Try to set up with 4K sectors - this may fail if kernel doesn't support it
    const loop_dev = setupLoopDeviceWithSectorSize(allocator, io, image_path, 4096) catch |err| {
        if (err == error.CommandFailed) {
            std.debug.print("Skipping: kernel doesn't support 4K sector loop devices\n", .{});
            return;
        }
        return err;
    };
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    // Note: sysfs always reports sizes in 512-byte sectors, regardless of device sector size
    const initial_size_512 = try getPartitionSizeSectors(allocator, io, loop_dev, 1) orelse {
        std.debug.print("Skipping: partition not visible with 4K sectors\n", .{});
        return;
    };
    // Convert expected 4K sectors to 512-byte sectors for comparison
    try testing.expectEqual(initial_4k_sectors * 8, initial_size_512);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    // Resize to 10MB (2560 4K sectors = 20480 512-byte sectors)
    const new_size_4k_sectors: u64 = 2560;
    // sysfs start is also in 512-byte sectors
    const start_512 = try getPartitionStartSector(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    // Convert to 4K sectors for the ioctl
    const start_4k = start_512 / 8;

    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(start_4k),
        @intCast(start_4k + new_size_4k_sectors),
        4096,
    );

    const new_size_512 = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(new_size_4k_sectors * 8, new_size_512);
}

// ============================================================================
// Multi-Partition Tests
// ============================================================================

test "integration: resize one partition without affecting others" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/multipart_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    // Create image with 2 partitions, leaving space for partition 1 to grow
    // Partition 1: small, with room to grow
    // Partition 2: at the end, won't be resized
    try createTestImageMulti(allocator, io, image_path, 50, &.{
        .{ .size_sectors = 10240, .name = "Part1" },
        .{ .size_sectors = 10240, .name = "Part2" },
    });

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    // Record initial sizes
    const initial_size1 = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    const initial_size2 = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        2,
    ) orelse return error.PartitionNotFound;

    try testing.expectEqual(@as(u64, 10240), initial_size1);
    try testing.expectEqual(@as(u64, 10240), initial_size2);

    // Shrink partition 1 (shrinking won't cause overlap)
    const new_size1: u64 = 5120;
    try resizePartitionInGpt(allocator, io, loop_dev, 1, new_size1);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const info1 = try getPartitionInfo(allocator, io, loop_dev, 1);
    try zblkpg.resizePartition(
        loop_file.handle,
        1,
        @intCast(info1.start),
        @intCast(info1.start + new_size1),
        SECTOR_SIZE,
    );

    // Verify partition 1 changed
    const final_size1 = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        1,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(new_size1, final_size1);

    // Verify partition 2 unchanged
    const final_size2 = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        2,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(initial_size2, final_size2);
}

test "integration: resize partition 2 specifically" {
    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    const allocator = testing.allocator;
    const io = testing.io;

    std.Io.Dir.cwd().createDirPath(io, "zig-cache/test-images") catch {};

    const image_path = "zig-cache/test-images/part2_test.img";
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};

    // Create image with 2 partitions - partition 2 is at the end with room to grow
    try createTestImageMulti(allocator, io, image_path, 50, &.{
        .{ .size_sectors = 10240, .name = "First" },
        .{ .size_sectors = 10240, .name = "Second" },
    });

    const loop_dev = try setupLoopDevice(allocator, io, image_path);
    defer {
        detachLoopDevice(allocator, io, loop_dev);
        allocator.free(loop_dev);
    }

    try settle(io);

    const initial_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        2,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(@as(u64, 10240), initial_size);

    // Grow partition 2 into free space at end of disk
    const new_size: u64 = 30720;
    try resizePartitionInGpt(allocator, io, loop_dev, 2, new_size);

    const loop_file = try std.Io.Dir.openFileAbsolute(io, loop_dev, .{ .mode = .read_write });
    defer loop_file.close(io);

    const info = try getPartitionInfo(allocator, io, loop_dev, 2);
    try zblkpg.resizePartition(
        loop_file.handle,
        2,
        @intCast(info.start),
        @intCast(info.start + new_size),
        SECTOR_SIZE,
    );

    const final_size = try getPartitionSizeSectors(
        allocator,
        io,
        loop_dev,
        2,
    ) orelse return error.PartitionNotFound;
    try testing.expectEqual(new_size, final_size);
}
