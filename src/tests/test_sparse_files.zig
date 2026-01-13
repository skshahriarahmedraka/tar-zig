const std = @import("std");
const tar_header = @import("tar_header");

// Sparse Files Tests for tar-zig
// Based on GNU tar tests: sparse01.at, sparse02.at, sparse03.at, etc.
// Sparse files contain "holes" - regions that don't actually occupy disk space

// Test GNU sparse header type flag
test "gnu sparse type flag" {
    // GNU sparse files use 'S' type flag in some formats
    const sparse_flag = tar_header.TypeFlag.fromByte('S');
    try std.testing.expectEqual(tar_header.TypeFlag.gnu_sparse, sparse_flag);
}

// Test sparse file header with regular type
test "sparse file as regular with sparse data" {
    // In POSIX/PAX format, sparse files are stored as regular files
    // with extended attributes describing the sparse map
    var header = tar_header.PosixHeader.init();
    try header.setName("sparse_file.dat");
    header.setTypeFlag(.regular);
    // Real size includes holes
    header.setSize(10 * 1024 * 1024); // 10 MB logical size
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test sparse file size representation
test "sparse file logical vs physical size" {
    var header = tar_header.PosixHeader.init();
    try header.setName("sparse.bin");
    header.setTypeFlag(.regular);

    // A sparse file might have:
    // - Logical size: 1 GB (what the file system reports)
    // - Physical size: 4 KB (actual data stored)
    // In the tar header, we store the physical size of data blocks
    const physical_size: u64 = 4096;
    header.setSize(physical_size);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(physical_size, try header.getSize());
}

// Test sparse entry structure
// GNU sparse format stores offset/size pairs
test "sparse map entry structure" {
    // Sparse map entries are typically:
    // - offset: position in the file where data starts
    // - numbytes: number of bytes of actual data

    const SparseEntry = struct {
        offset: u64,
        numbytes: u64,
    };

    // Example sparse file with holes:
    // [HOLE: 0-1MB][DATA: 1MB-1MB+4KB][HOLE: ...][DATA: 2MB-2MB+4KB]
    const sparse_map = [_]SparseEntry{
        .{ .offset = 1024 * 1024, .numbytes = 4096 }, // Data at 1 MB
        .{ .offset = 2 * 1024 * 1024, .numbytes = 4096 }, // Data at 2 MB
    };

    // Total physical data size
    var total_data: u64 = 0;
    for (sparse_map) |entry| {
        total_data += entry.numbytes;
    }

    try std.testing.expectEqual(@as(u64, 8192), total_data);
}

// Test blocks needed calculation for sparse files
test "sparse file block calculation" {
    // Even sparse files need to be block-aligned in the archive
    // Only the actual data blocks are stored

    // 4096 bytes of data = 8 blocks (512 * 8 = 4096)
    try std.testing.expectEqual(@as(u64, 8), tar_header.blocksNeeded(4096));

    // 4097 bytes = 9 blocks
    try std.testing.expectEqual(@as(u64, 9), tar_header.blocksNeeded(4097));

    // 1 byte still needs 1 block
    try std.testing.expectEqual(@as(u64, 1), tar_header.blocksNeeded(1));
}

// Test GNU sparse header fields
test "gnu sparse header extended fields" {
    // GNU sparse format version 0.0 uses extended header fields:
    // - isextended: flag indicating more sparse entries follow
    // - realsize: the logical size of the sparse file
    // These are stored in the 'extra' area of the header or in extended headers

    var header = tar_header.PosixHeader.init();
    try header.setName("gnu_sparse.dat");
    header.setTypeFlag(.gnu_sparse);
    header.setMode(0o644);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expectEqual(tar_header.TypeFlag.gnu_sparse, header.getTypeFlag());
}

// Test sparse file with maximum holes
test "sparse file extreme case" {
    // Test a file that's mostly holes
    // 1 TB logical size, but only 512 bytes of actual data

    var header = tar_header.PosixHeader.init();
    try header.setName("extreme_sparse.bin");
    header.setTypeFlag(.regular);

    // Only store physical data size in header
    const physical_size: u64 = 512;
    header.setSize(physical_size);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
    try std.testing.expectEqual(@as(u64, 1), tar_header.blocksNeeded(physical_size));
}

// Test PAX sparse attributes
test "pax sparse extended attributes" {
    // PAX format stores sparse information in extended headers:
    // - GNU.sparse.major: sparse format major version
    // - GNU.sparse.minor: sparse format minor version
    // - GNU.sparse.name: original filename
    // - GNU.sparse.realsize: logical file size
    // - GNU.sparse.map: offset,size pairs

    // This test verifies the concept - actual PAX parsing is in pax.zig
    const pax_sparse_attrs = [_][]const u8{
        "GNU.sparse.major",
        "GNU.sparse.minor",
        "GNU.sparse.name",
        "GNU.sparse.realsize",
        "GNU.sparse.map",
        "GNU.sparse.size",
        "GNU.sparse.numblocks",
        "GNU.sparse.offset",
        "GNU.sparse.numbytes",
    };

    // Just verify we have the expected attribute names
    try std.testing.expectEqual(@as(usize, 9), pax_sparse_attrs.len);
}

// Test sparse file with multiple data regions
test "sparse file multiple regions" {
    // Simulate a sparse file with multiple data regions
    const DataRegion = struct {
        offset: u64,
        length: u64,
    };

    const regions = [_]DataRegion{
        .{ .offset = 0, .length = 1000 }, // Data at start
        .{ .offset = 1024 * 1024, .length = 4096 }, // Data at 1 MB
        .{ .offset = 2 * 1024 * 1024, .length = 4096 }, // Data at 2 MB
        .{ .offset = 10 * 1024 * 1024, .length = 500 }, // Data at 10 MB
    };

    // Calculate total physical size: 1000 + 4096 + 4096 + 500 = 9692
    var physical_total: u64 = 0;
    for (regions) |r| {
        physical_total += r.length;
    }

    try std.testing.expectEqual(@as(u64, 9692), physical_total);

    // Calculate blocks needed for archive
    var blocks_needed: u64 = 0;
    for (regions) |r| {
        blocks_needed += tar_header.blocksNeeded(r.length);
    }

    // Each region is independently padded
    // 1000 -> 2 blocks, 4096 -> 8 blocks, 4096 -> 8 blocks, 500 -> 1 block
    try std.testing.expectEqual(@as(u64, 2 + 8 + 8 + 1), blocks_needed);
}

// Test sparse file header checksum
test "sparse file header checksum validity" {
    var header = tar_header.PosixHeader.init();
    try header.setName("checksum_sparse.dat");
    header.setTypeFlag(.gnu_sparse);
    header.setMode(0o644);
    header.setUid(1000);
    header.setGid(1000);
    header.setSize(4096);
    header.setMtime(1704067200);
    header.setUstarMagic();
    header.setChecksum();

    try std.testing.expect(header.verifyChecksum());
}

// Test sparse file extraction concepts
test "sparse file hole detection" {
    // When extracting sparse files, we need to detect holes
    // A hole is a region of zeros that can be represented as a seek

    const data = [_]u8{ 0, 0, 0, 0, 'A', 'B', 'C', 'D', 0, 0, 0, 0 };

    // Find non-zero regions manually (simulating hole detection)
    const Region = struct { start: usize, end: usize };
    var regions: [10]Region = undefined;
    var region_count: usize = 0;

    var in_data = false;
    var data_start: usize = 0;

    for (data, 0..) |byte, i| {
        if (byte != 0 and !in_data) {
            in_data = true;
            data_start = i;
        } else if (byte == 0 and in_data) {
            in_data = false;
            regions[region_count] = .{ .start = data_start, .end = i };
            region_count += 1;
        }
    }
    if (in_data) {
        regions[region_count] = .{ .start = data_start, .end = data.len };
        region_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), region_count);
    try std.testing.expectEqual(@as(usize, 4), regions[0].start);
    try std.testing.expectEqual(@as(usize, 8), regions[0].end);
}

// Test GNU sparse format version detection
test "gnu sparse format versions" {
    // GNU tar supports multiple sparse format versions:
    // - 0.0: Original format with sparse headers in tar header
    // - 0.1: Extended sparse headers follow the header
    // - 1.0: PAX extended headers with sparse map

    const SparseVersion = struct {
        major: u8,
        minor: u8,
    };

    const versions = [_]SparseVersion{
        .{ .major = 0, .minor = 0 },
        .{ .major = 0, .minor = 1 },
        .{ .major = 1, .minor = 0 },
    };

    try std.testing.expectEqual(@as(usize, 3), versions.len);
}
