# tar-zig Test Suite Documentation

This document describes the comprehensive test suite for tar-zig, a GNU tar compatible implementation in Zig.

## Test Overview

The test suite consists of two main components:

1. **Zig Unit Tests** - Low-level tests for individual modules
2. **CLI Integration Tests** - End-to-end tests using shell scripts

## Running Tests

### All Tests
```bash
cd tar-zig
zig build test              # Run all Zig unit tests
./tests/run_tests.sh        # Run all CLI integration tests
```

### Individual Test Modules
```bash
zig build test              # Runs tests from all modules
```

## Zig Unit Tests

### Module Tests

| Module | File | Description |
|--------|------|-------------|
| tar_header | `src/tar_header.zig` | Header parsing, checksum, octal encoding |
| integration | `src/tests/integration_tests.zig` | Cross-module integration tests |
| hardlinks | `src/tests/test_hardlinks.zig` | Hard link header handling |
| special_files | `src/tests/test_special_files.zig` | Device files, FIFOs, symlinks |
| sparse_files | `src/tests/test_sparse_files.zig` | Sparse file format handling |
| large_files | `src/tests/test_large_files.zig` | Large file (>8GB) support |

### Test Categories

#### Header Tests (`tar_header.zig`)
- Checksum calculation and verification
- Octal encoding/decoding
- Base-256 encoding for large values
- Name field handling (name + prefix)
- Type flag parsing

#### Hard Link Tests (`test_hardlinks.zig`)
- Hard link type flag (`'1'`)
- Link name storage
- Multiple hard links to same file
- Checksum validity with hard links
- Metadata preservation

#### Special File Tests (`test_special_files.zig`)
- Character device headers (type `'3'`)
- Block device headers (type `'4'`)
- FIFO/named pipe headers (type `'6'`)
- Symbolic link headers (type `'2'`)
- Directory headers (type `'5'`)
- Device major/minor number encoding
- GNU and PAX extension type flags

#### Sparse File Tests (`test_sparse_files.zig`)
- GNU sparse type flag (`'S'`)
- Sparse map entry structures
- Logical vs physical size handling
- Block calculations for sparse data
- PAX sparse attributes
- Hole detection algorithms

#### Large File Tests (`test_large_files.zig`)
- Base-256 encoding for sizes > 8GB
- Octal encoding boundary (8,589,934,591 bytes)
- Large mtime values (year 2100+)
- Large UID/GID values
- 64-bit size limits

## CLI Integration Tests

The shell script `tests/run_tests.sh` runs 40 comprehensive tests:

### Basic Operations (Tests 1-10)
| Test | Description |
|------|-------------|
| 1 | Create archive (`-c`) |
| 2 | List archive (`-t`) |
| 3 | Verbose list (`-tv`) |
| 4 | Extract archive (`-x`) |
| 5 | Gzip compression (`-z`) |
| 6 | Bzip2 compression (`-j`) |
| 7 | XZ compression (`-J`) |
| 8 | Extract gzip compressed archive |
| 9 | Append to archive (`-r`) |
| 10 | Delete from archive (`--delete`) |

### Advanced Features (Tests 11-20)
| Test | Description |
|------|-------------|
| 11 | Diff archive with filesystem (`-d`) |
| 12 | Strip components (`--strip-components`) |
| 13 | Keep old files (`-k`) |
| 14 | GNU tar compatibility (extract) |
| 15 | GNU tar compatibility (create) |
| 16 | Long filename support (>100 chars) |
| 17 | Help option (`--help`) |
| 18 | Version option (`--version`) |
| 19 | Auto-detect compression (`-a`) |
| 20 | Empty directory archiving |

### Link and Special File Tests (Tests 21-25)
| Test | Description |
|------|-------------|
| 21 | Hard link archiving |
| 22 | Symbolic link archiving |
| 23 | Update mode (`-u`) |
| 24 | Nested directory extraction |
| 25 | Many files archiving (50+ files) |

### File Handling Tests (Tests 26-30)
| Test | Description |
|------|-------------|
| 26 | Binary file archiving |
| 27 | Permissions preservation |
| 28 | Zstd compression (`--zstd`) |
| 29 | Extract specific file |
| 30 | Directory change during create (`-C`) |

### GNU Tar Compatibility Tests (Tests 31-40)
| Test | Description | Based On |
|------|-------------|----------|
| 31 | Append preserves existing entries | append01.at |
| 32 | Delete from middle of archive | delete01.at |
| 33 | Extract overwrites existing files | extrac04.at |
| 34 | Multiple files on command line | - |
| 35 | Special characters in filenames | - |
| 36 | Verbose create (`-cv`) | - |
| 37 | Empty file archiving | - |
| 38 | Very long filename (>200 chars) | longv7.at |
| 39 | Archive multiple directories | - |
| 40 | Roundtrip integrity check | - |

## Test Patterns from GNU tar

The test suite is inspired by the GNU tar test suite (`tar/tests/*.at`). Key patterns implemented:

### Archive Format Tests
- USTAR format compliance
- GNU extensions (long names, sparse files)
- PAX extended headers

### Edge Cases
- Empty files and directories
- Very long filenames (>100, >200 characters)
- Files with special characters (spaces)
- Binary file integrity

### Operation Tests
- Create/Extract roundtrip integrity
- Append without corrupting existing entries
- Delete specific entries
- Update only newer files

## Adding New Tests

### Adding a Zig Unit Test

1. Create a new test file in `src/tests/`:
```zig
const std = @import("std");
const tar_header = @import("tar_header");

test "my new test" {
    // Test implementation
    try std.testing.expect(true);
}
```

2. Add to `build.zig`:
```zig
const my_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests/my_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tar_header", .module = tar_module },
        },
    }),
});
test_step.dependOn(&b.addRunArtifact(my_tests).step);
```

### Adding a Shell Test

Add to `tests/run_tests.sh`:
```bash
# Test N: Description
echo "Test N: Description"
# Test commands...
[ condition ] && pass "Description" || fail "Description"
```

## Test Results

Current test status (as of January 2026):

- **Zig Unit Tests**: 110+ tests passing
- **CLI Integration Tests**: 70/70 tests passing

## Known Limitations

1. Sparse file creation not yet implemented (read support only)
2. ACL/xattr support not implemented
3. Incremental backups not supported
4. Multi-volume archives not supported

## Contributing

When adding new features, please:

1. Add corresponding unit tests in Zig
2. Add CLI integration tests if applicable
3. Update this documentation
4. Ensure all existing tests continue to pass
