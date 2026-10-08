# zblkpg

A Zig library to call Linux blkpg ioctls.

Note: only the `BLKPG_RESIZE_PARTITION` operation is implemented.

Requires Zig 0.17.0 and Linux.

## Usage

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zblkpg = .{
        .url = "https://github.com/cloudboss/zblkpg/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zblkpg_dep = b.dependency("zblkpg", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zblkpg", zblkpg_dep.module("zblkpg"));
```

## Example

```zig
const std = @import("std");
const zblkpg = @import("zblkpg");

pub fn main(init: std.process.Init) !void {
    const file = try std.Io.Dir.openFileAbsolute(
        init.io,
        "/dev/nvme0n1",
        .{ .mode = .read_write },
    );
    defer file.close(init.io);

    // Resize partition 2: new range is sectors 456-789 with 512-byte sectors
    try zblkpg.resizePartition(file.handle, 2, 456, 789, 512);
}
```

## API

### `resizePartition`

```zig
pub fn resizePartition(
    fd: std.posix.fd_t,
    part_num: i32,
    start_sector: i64,
    end_sector: i64,
    sector_size: i64,
) ResizeError!void
```

Resizes a partition while it is mounted. This calls the blkpg ioctl with the
`BLKPG_RESIZE_PARTITION` operation, informing the kernel about the new partition
boundaries without requiring unmounting.

Parameters:
- `fd`: The open file descriptor of the disk device (e.g., /dev/nvme0n1).
- `part_num`: The number of the partition to be modified.
- `start_sector`: The start sector of the partition.
- `end_sector`: The end sector of the partition.
- `sector_size`: The size of the sectors in bytes.

### Error Types

- `AccessDenied`: Access to the device was denied.
- `InvalidFileDescriptor`: The file descriptor is not valid or not open for writing.
- `InvalidArgument`: Invalid argument (e.g., partition number, start, or length).
- `NotSupported`: The device does not support this operation.
- `Unexpected`: An unexpected error occurred.

## Testing

Unit tests (struct size validation):

```sh
zig build test
```

Compile integration tests without root access:

```sh
zig build test-integration-compile
```

Integration tests (requires root, uses loop devices):

```sh
sudo zig build test-integration
```

## License

MIT
