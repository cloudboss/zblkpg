# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

zblkpg is a Zig library for calling Linux blkpg ioctls. Currently only the `BLKPG_RESIZE_PARTITION` operation is implemented, which allows resizing a partition while it is mounted by informing the kernel about new partition boundaries.

## Build Commands

```bash
# Run unit tests (struct size validation)
zig build test

# Run integration tests (requires root, uses loop devices)
sudo zig build test-integration
```

Requires Zig 0.17.0.

## Architecture

### Main Library (`src/blkpg.zig`)

The library exposes a single function:

```zig
pub fn resizePartition(
    fd: std.posix.fd_t,
    part_num: i32,
    start_sector: i64,
    end_sector: i64,
    sector_size: i64,
) ResizeError!void
```

Internally uses two extern structs matching the Linux kernel ABI:
- `BlkpgIoctlArg` (24 bytes) - ioctl argument structure
- `BlkpgPartition` (152 bytes) - partition information

Error handling maps Linux errno values to `ResizeError`:
- `EACCES` → `AccessDenied`
- `EBADF` → `InvalidFileDescriptor`
- `EINVAL` → `InvalidArgument`
- `ENXIO`, `ENOENT` → `NoSuchPartition`
- `ENOTTY` → `NotSupported`

### Integration Tests (`tests/integration_test.zig`)

Tests require root privileges and use loop devices:

1. Create a sparse disk image with `truncate`
2. Create GPT partition table using the `zgpt` library (pure Zig, no external tools)
3. Set up loop device with `losetup --partscan`
4. Read partition size from sysfs (`/sys/block/loopN/loopNpM/size`)
5. Resize partition in GPT using `zgpt.GptContext`
6. Call `resizePartition()` to inform kernel
7. Verify new size in sysfs

Tests skip gracefully when not running as root.

### Dependencies

- `zgpt` - Zig GPT partition library (fetched from GitHub)

## Code Style

- Follow Zig idioms and standard library conventions
- Use `std.posix` and `std.os.linux` for system interfaces
- Extern structs must match Linux kernel ABI exactly
- Unit tests verify struct sizes match kernel expectations

## Testing Notes

Integration tests create temporary files in `_output/test-images/` and clean up after themselves. The tests:
- Verify basic resize operation works
- Verify resizing non-existent partition returns `error.NoSuchPartition`
- Verify invalid file descriptor returns `error.InvalidFileDescriptor`
