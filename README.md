# tar-zig

A fast, modern implementation of the GNU tar utility written in [Zig](https://ziglang.org/). tar-zig is designed to be a drop-in replacement for common tar operations with full GNU tar compatibility.

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)]()
[![Tests](https://img.shields.io/badge/tests-180%2B%20passing-brightgreen)]()
[![Zig Version](https://img.shields.io/badge/zig-0.15-orange)]()
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Features

- **Full Archive Operations**: Create, extract, list, append, update, delete, and compare archives
- **Compression Support**: gzip, bzip2, xz, and zstd (via external tools)
- **GNU tar Compatible**: Archives created by tar-zig can be extracted by GNU tar and vice versa
- **Long Filename Support**: Handles filenames >100 characters using GNU extensions
- **Large File Support**: Handles files >8GB using base-256 encoding
- **PAX Extended Headers**: Support for UTF-8 filenames and extended attributes
- **No C Dependencies**: Pure Zig implementation
- **Fast & Memory Efficient**: Optimized for performance

## Installation

### Building from Source

Requirements:
- Zig 0.15 or later

```bash
git clone https://github.com/yourusername/tar-zig.git
cd tar-zig
zig build -Doptimize=ReleaseFast

# The binary will be at ./zig-out/bin/tar-zig
```

### Adding to PATH

```bash
# Option 1: Copy to a directory in your PATH
sudo cp ./zig-out/bin/tar-zig /usr/local/bin/

# Option 2: Add to PATH in your shell config
export PATH="$PATH:/path/to/tar-zig/zig-out/bin"
```

## Quick Start

### Create an Archive

```bash
# Create a tar archive
tar-zig -cvf archive.tar file1.txt file2.txt directory/

# Create a compressed archive (gzip)
tar-zig -czvf archive.tar.gz directory/

# Create with bzip2 compression
tar-zig -cjvf archive.tar.bz2 directory/

# Create with xz compression
tar-zig -cJvf archive.tar.xz directory/

# Create with zstd compression
tar-zig --zstd -cvf archive.tar.zst directory/
```

### Extract an Archive

```bash
# Extract to current directory
tar-zig -xvf archive.tar

# Extract to a specific directory
tar-zig -xvf archive.tar -C /path/to/destination/

# Extract specific files
tar-zig -xvf archive.tar file1.txt directory/file2.txt

# Extract and strip leading path components
tar-zig -xvf archive.tar --strip-components=1
```

### List Archive Contents

```bash
# Simple listing
tar-zig -tf archive.tar

# Verbose listing (with permissions, owner, size, date)
tar-zig -tvf archive.tar
```

### Modify Archives

```bash
# Append files to an existing archive
tar-zig -rvf archive.tar newfile.txt

# Update only newer files
tar-zig -uvf archive.tar directory/

# Delete files from archive
tar-zig --delete -f archive.tar unwanted.txt

# Compare archive with filesystem
tar-zig -dvf archive.tar
```

## Command Reference

### Main Operations

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-c` | `--create` | Create a new archive |
| `-x` | `--extract` | Extract files from an archive |
| `-t` | `--list` | List the contents of an archive |
| `-r` | `--append` | Append files to the end of an archive |
| `-u` | `--update` | Only append files newer than archive copy |
| `-d` | `--diff` | Find differences between archive and filesystem |
| | `--delete` | Delete files from the archive |

### Common Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-f` | `--file=ARCHIVE` | Use archive file ARCHIVE |
| `-v` | `--verbose` | Verbosely list files processed |
| `-C` | `--directory=DIR` | Change to directory DIR before operations |

### Compression Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-z` | `--gzip` | Filter archive through gzip |
| `-j` | `--bzip2` | Filter archive through bzip2 |
| `-J` | `--xz` | Filter archive through xz |
| | `--zstd` | Filter archive through zstd |
| `-a` | `--auto-compress` | Use archive suffix to determine compression |

### Other Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-h` | `--dereference` | Follow symlinks; archive files they point to |
| `-k` | `--keep-old-files` | Don't replace existing files when extracting |
| | `--strip-components=N` | Strip N leading path components on extraction |
| | `--help` | Display help information |
| | `--version` | Display version information |

## Examples

### Backup a Directory

```bash
# Create a timestamped backup
tar-zig -czvf backup-$(date +%Y%m%d).tar.gz /path/to/important/data/
```

### Extract Only Specific File Types

```bash
# List all .txt files in archive
tar-zig -tvf archive.tar | grep '\.txt$'

# Extract only specific files
tar-zig -xvf archive.tar $(tar-zig -tf archive.tar | grep '\.txt$')
```

### Create Archive Excluding Certain Files

```bash
# Archive current directory, will include all files
tar-zig -cvf project.tar .

# Or archive specific subdirectories
tar-zig -cvf project.tar src/ include/ docs/
```

### Transfer Files Between Machines

```bash
# On source machine: create and stream
tar-zig -czf - /data | ssh user@remote 'tar-zig -xzf - -C /destination'

# Or save locally first
tar-zig -czvf data.tar.gz /data
scp data.tar.gz user@remote:/destination/
ssh user@remote 'cd /destination && tar-zig -xzvf data.tar.gz'
```

### Verify Archive Integrity

```bash
# List contents to verify archive is readable
tar-zig -tvf archive.tar > /dev/null && echo "Archive OK" || echo "Archive corrupted"

# Compare archive with current filesystem
tar-zig -dvf archive.tar
```

### Working with Different Directories

```bash
# Create archive with relative paths from a different directory
tar-zig -cvf archive.tar -C /home/user/projects project1 project2

# Extract to a different directory
tar-zig -xvf archive.tar -C /tmp/extracted/
```

## Compression Comparison

| Format | Extension | Option | Compression Ratio | Speed |
|--------|-----------|--------|-------------------|-------|
| None | `.tar` | (none) | 1:1 | Fastest |
| Gzip | `.tar.gz`, `.tgz` | `-z` | Good | Fast |
| Bzip2 | `.tar.bz2`, `.tbz` | `-j` | Better | Slower |
| XZ | `.tar.xz`, `.txz` | `-J` | Best | Slowest |
| Zstd | `.tar.zst` | `--zstd` | Better | Fast |

## GNU tar Compatibility

tar-zig is designed to be compatible with GNU tar. Archives created by tar-zig can be extracted using GNU tar and vice versa.

### Supported Features

- ✅ POSIX ustar format
- ✅ GNU long filename extensions (type 'L' and 'K' headers)
- ✅ PAX extended headers
- ✅ Large files (>8GB) via base-256 encoding
- ✅ Symbolic links
- ✅ Hard links
- ✅ Directories with proper permissions
- ✅ All compression formats (via external tools)

### Not Yet Implemented

- ❌ Sparse file optimization (archives contain full data)
- ❌ Incremental backups (-g/--listed-incremental)
- ❌ Multi-volume archives (-M)
- ❌ Extended attributes (--xattrs, --acls, --selinux)
- ❌ Exclude patterns (--exclude)
- ❌ Transform patterns (--transform)

## Testing

tar-zig includes a comprehensive test suite with 180+ tests:

```bash
# Run Zig unit tests (110+ tests)
zig build test

# Run CLI integration tests (70 tests)
./tests/run_tests.sh
```

### Test Coverage

- Header parsing and generation
- Checksum calculation
- Octal/base-256 encoding
- Long filename handling
- All archive operations (create, extract, list, append, update, delete, diff)
- Compression/decompression
- Hard links and symbolic links
- Error handling
- GNU tar compatibility

## Project Structure

```
tar-zig/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig           # Entry point and CLI
│   ├── tar_header.zig     # TAR format definitions
│   ├── options.zig        # Command-line options
│   ├── buffer.zig         # I/O buffering
│   ├── create.zig         # Archive creation
│   ├── extract.zig        # Archive extraction
│   ├── list.zig           # Archive listing
│   ├── append.zig         # Append operations
│   ├── update.zig         # Update operations
│   ├── delete.zig         # Delete operations
│   ├── diff.zig           # Compare operations
│   ├── pax.zig            # PAX extended headers
│   ├── compression.zig    # Compression handling
│   ├── file_utils.zig     # File system utilities
│   └── tests/             # Unit tests
└── tests/
    ├── run_tests.sh       # Integration test script
    └── README.md          # Test documentation
```

## Performance

tar-zig is designed for performance:

- **Efficient I/O**: Uses buffered reading/writing with 512-byte block alignment
- **Minimal Allocations**: Reuses buffers where possible
- **Streaming**: Processes archives without loading entirely into memory
- **Native Code**: Compiles to optimized native binaries

Benchmark your specific workload:

```bash
# Time archive creation
time tar-zig -cf test.tar /path/to/data

# Compare with GNU tar
time tar -cf test2.tar /path/to/data
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Building for Development

```bash
# Debug build (faster compilation, includes debug info)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
./tests/run_tests.sh
```

### Code Style

- Follow Zig standard library conventions
- Include doc comments for public functions
- Add tests for new functionality
- Ensure all tests pass before submitting

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- The [GNU tar](https://www.gnu.org/software/tar/) project for the reference implementation
- The [Zig](https://ziglang.org/) programming language team
- POSIX tar specification (IEEE Std 1003.1)

## See Also

- [GNU tar manual](https://www.gnu.org/software/tar/manual/)
- [POSIX tar specification](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html)
- [Zig documentation](https://ziglang.org/documentation/master/)
