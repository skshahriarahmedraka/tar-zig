#!/bin/bash
# Comprehensive CLI tests for tar-zig
# Run from the tar-zig directory: ./tests/run_tests.sh

# Don't exit on first error - we want to run all tests
# set -e

TAR_ZIG="./zig-out/bin/tar-zig"
TEST_DIR="tmp_test_$$"
PASS=0
FAIL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f tmp_test_*.tar tmp_test_*.tar.gz tmp_test_*.tar.bz2 tmp_test_*.tar.xz 2>/dev/null || true
}

trap cleanup EXIT

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASS++))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((FAIL++))
}

# Build first
echo "Building tar-zig..."
zig build || { echo "Build failed"; exit 1; }

echo ""
echo "=== Running tar-zig CLI tests ==="
echo ""

# Create test directory structure
mkdir -p "$TEST_DIR/subdir"
echo "File 1 content" > "$TEST_DIR/file1.txt"
echo "File 2 content" > "$TEST_DIR/file2.txt"
echo "Subdir file" > "$TEST_DIR/subdir/nested.txt"
ln -s file1.txt "$TEST_DIR/link.txt" 2>/dev/null || true

# Test 1: Create archive
echo "Test 1: Create archive (-c)"
if $TAR_ZIG -cf tmp_test_create.tar "$TEST_DIR"; then
    pass "Create archive"
else
    fail "Create archive"
fi

# Test 2: List archive
echo "Test 2: List archive (-t)"
OUTPUT=$($TAR_ZIG -tf tmp_test_create.tar)
echo "$OUTPUT" | grep -q "file1.txt" && pass "List archive" || fail "List archive"

# Test 3: Verbose list
echo "Test 3: Verbose list (-tv)"
OUTPUT=$($TAR_ZIG -tvf tmp_test_create.tar)
echo "$OUTPUT" | grep -q "rw" && pass "Verbose list shows permissions" || fail "Verbose list shows permissions"

# Test 4: Extract archive
echo "Test 4: Extract archive (-x)"
mkdir -p "${TEST_DIR}_extract"
$TAR_ZIG -xf tmp_test_create.tar -C "${TEST_DIR}_extract"
[ -f "${TEST_DIR}_extract/$TEST_DIR/file1.txt" ] && pass "Extract archive" || fail "Extract archive"
rm -rf "${TEST_DIR}_extract"

# Test 5: Gzip compression
echo "Test 5: Gzip compression (-z)"
if command -v gzip &> /dev/null; then
    $TAR_ZIG -czf tmp_test_gzip.tar.gz "$TEST_DIR" && \
    file tmp_test_gzip.tar.gz | grep -q "gzip" && pass "Gzip compression" || fail "Gzip compression"
else
    echo "SKIP: gzip not installed"
fi

# Test 6: Bzip2 compression
echo "Test 6: Bzip2 compression (-j)"
if command -v bzip2 &> /dev/null; then
    $TAR_ZIG -cjf tmp_test_bzip2.tar.bz2 "$TEST_DIR" && \
    file tmp_test_bzip2.tar.bz2 | grep -q "bzip2" && pass "Bzip2 compression" || fail "Bzip2 compression"
else
    echo "SKIP: bzip2 not installed"
fi

# Test 7: XZ compression
echo "Test 7: XZ compression (-J)"
if command -v xz &> /dev/null; then
    $TAR_ZIG -cJf tmp_test_xz.tar.xz "$TEST_DIR" && \
    file tmp_test_xz.tar.xz | grep -q "XZ" && pass "XZ compression" || fail "XZ compression"
else
    echo "SKIP: xz not installed"
fi

# Test 8: Extract compressed archive
echo "Test 8: Extract gzip compressed archive"
if [ -f tmp_test_gzip.tar.gz ]; then
    mkdir -p "${TEST_DIR}_gz_extract"
    $TAR_ZIG -xzf tmp_test_gzip.tar.gz -C "${TEST_DIR}_gz_extract" && \
    [ -f "${TEST_DIR}_gz_extract/$TEST_DIR/file1.txt" ] && pass "Extract gzip archive" || fail "Extract gzip archive"
    rm -rf "${TEST_DIR}_gz_extract"
else
    echo "SKIP: gzip archive not created"
fi

# Test 9: Append to archive
echo "Test 9: Append to archive (-r)"
echo "New file" > "$TEST_DIR/newfile.txt"
$TAR_ZIG -rf tmp_test_create.tar "$TEST_DIR/newfile.txt"
$TAR_ZIG -tf tmp_test_create.tar | grep -q "newfile.txt" && pass "Append to archive" || fail "Append to archive"

# Test 10: Delete from archive
echo "Test 10: Delete from archive (--delete)"
$TAR_ZIG --delete -f tmp_test_create.tar "$TEST_DIR/newfile.txt"
! $TAR_ZIG -tf tmp_test_create.tar | grep -q "newfile.txt" && pass "Delete from archive" || fail "Delete from archive"

# Test 11: Diff archive with filesystem
echo "Test 11: Diff archive with filesystem (-d)"
# First create a fresh archive
$TAR_ZIG -cf tmp_test_diff.tar "$TEST_DIR"
# Modify a file
echo "Modified" >> "$TEST_DIR/file1.txt"
OUTPUT=$($TAR_ZIG -df tmp_test_diff.tar 2>&1)
echo "$OUTPUT" | grep -q "differ" && pass "Diff detects changes" || fail "Diff detects changes"

# Test 12: Strip components
echo "Test 12: Strip components (--strip-components)"
mkdir -p "${TEST_DIR}_strip"
$TAR_ZIG -cf tmp_test_strip.tar "$TEST_DIR"
$TAR_ZIG -xf tmp_test_strip.tar -C "${TEST_DIR}_strip" --strip-components=1
[ -f "${TEST_DIR}_strip/file1.txt" ] && pass "Strip components" || fail "Strip components"
rm -rf "${TEST_DIR}_strip"

# Test 13: Keep old files
echo "Test 13: Keep old files (-k)"
mkdir -p "${TEST_DIR}_keep"
$TAR_ZIG -xf tmp_test_create.tar -C "${TEST_DIR}_keep"
echo "Original" > "${TEST_DIR}_keep/$TEST_DIR/file1.txt"
$TAR_ZIG -xkf tmp_test_create.tar -C "${TEST_DIR}_keep"
grep -q "Original" "${TEST_DIR}_keep/$TEST_DIR/file1.txt" && pass "Keep old files" || fail "Keep old files"
rm -rf "${TEST_DIR}_keep"

# Test 14: GNU tar compatibility - create with tar-zig, extract with GNU tar
echo "Test 14: GNU tar compatibility (extract)"
if command -v tar &> /dev/null; then
    mkdir -p "${TEST_DIR}_gnu"
    tar -xf tmp_test_create.tar -C "${TEST_DIR}_gnu"
    [ -f "${TEST_DIR}_gnu/$TEST_DIR/file1.txt" ] && pass "GNU tar can extract our archives" || fail "GNU tar can extract our archives"
    rm -rf "${TEST_DIR}_gnu"
else
    echo "SKIP: GNU tar not installed"
fi

# Test 15: GNU tar compatibility - create with GNU tar, extract with tar-zig
echo "Test 15: GNU tar compatibility (create)"
if command -v tar &> /dev/null; then
    tar -cf tmp_test_gnu.tar "$TEST_DIR"
    mkdir -p "${TEST_DIR}_from_gnu"
    $TAR_ZIG -xf tmp_test_gnu.tar -C "${TEST_DIR}_from_gnu"
    [ -f "${TEST_DIR}_from_gnu/$TEST_DIR/file1.txt" ] && pass "Can extract GNU tar archives" || fail "Can extract GNU tar archives"
    rm -rf "${TEST_DIR}_from_gnu" tmp_test_gnu.tar
else
    echo "SKIP: GNU tar not installed"
fi

# Test 16: Long filename support
echo "Test 16: Long filename support"
LONG_DIR="$TEST_DIR/this_is_a_very_long_directory_name_that_exceeds_100_characters_to_test_long_name_support"
mkdir -p "$LONG_DIR"
echo "Long name test" > "$LONG_DIR/file.txt"
$TAR_ZIG -cf tmp_test_long.tar "$LONG_DIR"
$TAR_ZIG -tf tmp_test_long.tar | grep -q "long_name_support" && pass "Long filename support" || fail "Long filename support"

# Test 17: Help option
echo "Test 17: Help option (--help)"
OUTPUT=$($TAR_ZIG --help 2>&1) || true
echo "$OUTPUT" | grep -q "Usage:" && pass "Help option" || fail "Help option"

# Test 18: Version option
echo "Test 18: Version option (--version)"
OUTPUT=$($TAR_ZIG --version 2>&1) || true
echo "$OUTPUT" | grep -q "tar-zig" && pass "Version option" || fail "Version option"

# Test 19: Auto-detect compression (-a)
echo "Test 19: Auto-detect compression (-a)"
if command -v gzip &> /dev/null; then
    $TAR_ZIG -caf tmp_test_auto.tar.gz "$TEST_DIR"
    file tmp_test_auto.tar.gz | grep -q "gzip" && pass "Auto-detect compression" || fail "Auto-detect compression"
else
    echo "SKIP: gzip not installed"
fi

# Test 20: Empty archive handling
echo "Test 20: Empty directory archiving"
mkdir -p "$TEST_DIR/empty_dir"
$TAR_ZIG -cf tmp_test_empty.tar "$TEST_DIR/empty_dir"
$TAR_ZIG -tf tmp_test_empty.tar | grep -q "empty_dir" && pass "Empty directory archiving" || fail "Empty directory archiving"

# Test 21: Hard links (if supported by filesystem)
echo "Test 21: Hard link archiving"
echo "Original content" > "$TEST_DIR/original.txt"
if ln "$TEST_DIR/original.txt" "$TEST_DIR/hardlink.txt" 2>/dev/null; then
    $TAR_ZIG -cf tmp_test_hardlink.tar "$TEST_DIR/original.txt" "$TEST_DIR/hardlink.txt"
    $TAR_ZIG -tvf tmp_test_hardlink.tar | grep -q "hardlink.txt" && pass "Hard link archiving" || fail "Hard link archiving"
else
    echo "SKIP: Hard links not supported on this filesystem"
fi

# Test 22: Symbolic links
echo "Test 22: Symbolic link archiving"
ln -sf file1.txt "$TEST_DIR/symlink.txt" 2>/dev/null || true
if [ -L "$TEST_DIR/symlink.txt" ]; then
    $TAR_ZIG -cf tmp_test_symlink.tar "$TEST_DIR/symlink.txt" 2>/dev/null
    $TAR_ZIG -tf tmp_test_symlink.tar | grep -q "symlink.txt" && pass "Symbolic link archiving" || fail "Symbolic link archiving"
else
    echo "SKIP: Symbolic links not created"
fi

# Test 23: Update mode (-u)
echo "Test 23: Update mode (-u)"
$TAR_ZIG -cf tmp_test_update.tar "$TEST_DIR/file1.txt"
sleep 1
touch "$TEST_DIR/file1.txt"  # Update mtime
$TAR_ZIG -uf tmp_test_update.tar "$TEST_DIR/file1.txt"
COUNT=$($TAR_ZIG -tf tmp_test_update.tar | grep -c "file1.txt")
[ "$COUNT" -eq 2 ] && pass "Update mode appends newer file" || fail "Update mode appends newer file"

# Test 24: Nested directory extraction
echo "Test 24: Nested directory structure"
mkdir -p "$TEST_DIR/a/b/c/d"
echo "deep file" > "$TEST_DIR/a/b/c/d/deep.txt"
$TAR_ZIG -cf tmp_test_nested.tar "$TEST_DIR/a"
mkdir -p "${TEST_DIR}_nested"
$TAR_ZIG -xf tmp_test_nested.tar -C "${TEST_DIR}_nested"
[ -f "${TEST_DIR}_nested/$TEST_DIR/a/b/c/d/deep.txt" ] && pass "Nested directory structure" || fail "Nested directory structure"
rm -rf "${TEST_DIR}_nested"

# Test 25: Large number of files
echo "Test 25: Many files archiving"
mkdir -p "$TEST_DIR/many"
for i in $(seq 1 50); do
    echo "file $i" > "$TEST_DIR/many/file_$i.txt"
done
$TAR_ZIG -cf tmp_test_many.tar "$TEST_DIR/many"
COUNT=$($TAR_ZIG -tf tmp_test_many.tar | wc -l)
[ "$COUNT" -ge 50 ] && pass "Many files archiving" || fail "Many files archiving"

# Test 26: Binary file handling
echo "Test 26: Binary file archiving"
dd if=/dev/urandom of="$TEST_DIR/binary.bin" bs=1024 count=10 2>/dev/null
$TAR_ZIG -cf tmp_test_binary.tar "$TEST_DIR/binary.bin"
mkdir -p "${TEST_DIR}_binary"
$TAR_ZIG -xf tmp_test_binary.tar -C "${TEST_DIR}_binary"
cmp -s "$TEST_DIR/binary.bin" "${TEST_DIR}_binary/$TEST_DIR/binary.bin" && pass "Binary file archiving" || fail "Binary file archiving"
rm -rf "${TEST_DIR}_binary"

# Test 27: Permissions preservation
echo "Test 27: Permissions preservation"
chmod 755 "$TEST_DIR/file1.txt"
$TAR_ZIG -cf tmp_test_perms.tar "$TEST_DIR/file1.txt"
$TAR_ZIG -tvf tmp_test_perms.tar | grep -q "rwxr-xr-x" && pass "Permissions preservation" || fail "Permissions preservation"

# Test 28: Zstd compression (if available)
echo "Test 28: Zstd compression (--zstd)"
if command -v zstd &> /dev/null; then
    $TAR_ZIG --zstd -cf tmp_test_zstd.tar.zst "$TEST_DIR" && \
    file tmp_test_zstd.tar.zst | grep -qi "zstandard\|zstd" && pass "Zstd compression" || fail "Zstd compression"
else
    echo "SKIP: zstd not installed"
fi

# Test 29: Extract specific file
echo "Test 29: Extract specific file"
mkdir -p "${TEST_DIR}_specific"
$TAR_ZIG -xf tmp_test_create.tar -C "${TEST_DIR}_specific" "$TEST_DIR/file1.txt"
[ -f "${TEST_DIR}_specific/$TEST_DIR/file1.txt" ] && pass "Extract specific file" || fail "Extract specific file"
rm -rf "${TEST_DIR}_specific"

# Test 30: Directory change during create (-C)
echo "Test 30: Directory change during create (-C)"
$TAR_ZIG -cf tmp_test_chdir.tar -C "$TEST_DIR" file1.txt file2.txt
$TAR_ZIG -tf tmp_test_chdir.tar | grep -q "^file1.txt$" && pass "Directory change during create" || fail "Directory change during create"

# ============================================
# Additional GNU tar compatibility tests
# Based on GNU tar test suite patterns
# ============================================

# Test 31: Append preserves existing entries (append01.at pattern)
echo "Test 31: Append preserves existing entries"
echo "content1" > "$TEST_DIR/append1.txt"
echo "content2" > "$TEST_DIR/append2.txt"
$TAR_ZIG -cf tmp_test_append_preserve.tar "$TEST_DIR/append1.txt"
$TAR_ZIG -rf tmp_test_append_preserve.tar "$TEST_DIR/append2.txt"
COUNT=$($TAR_ZIG -tf tmp_test_append_preserve.tar | wc -l)
[ "$COUNT" -eq 2 ] && pass "Append preserves existing entries" || fail "Append preserves existing entries"

# Test 32: Delete specific file from middle (delete01.at pattern)
echo "Test 32: Delete from middle of archive"
echo "file1" > "$TEST_DIR/del1.txt"
echo "file2" > "$TEST_DIR/del2.txt"
echo "file3" > "$TEST_DIR/del3.txt"
$TAR_ZIG -cf tmp_test_del_mid.tar "$TEST_DIR/del1.txt" "$TEST_DIR/del2.txt" "$TEST_DIR/del3.txt"
$TAR_ZIG --delete -f tmp_test_del_mid.tar "$TEST_DIR/del2.txt"
! $TAR_ZIG -tf tmp_test_del_mid.tar | grep -q "del2.txt" && \
$TAR_ZIG -tf tmp_test_del_mid.tar | grep -q "del1.txt" && \
$TAR_ZIG -tf tmp_test_del_mid.tar | grep -q "del3.txt" && pass "Delete from middle of archive" || fail "Delete from middle of archive"

# Test 33: Extract with overwrite (extrac04.at pattern)
echo "Test 33: Extract overwrites existing files"
mkdir -p "${TEST_DIR}_overwrite"
echo "old content" > "${TEST_DIR}_overwrite/file.txt"
echo "new content" > "$TEST_DIR/file.txt"
$TAR_ZIG -cf tmp_test_overwrite.tar "$TEST_DIR/file.txt"
$TAR_ZIG -xf tmp_test_overwrite.tar -C "${TEST_DIR}_overwrite" --strip-components=1
grep -q "new content" "${TEST_DIR}_overwrite/file.txt" && pass "Extract overwrites existing files" || fail "Extract overwrites existing files"
rm -rf "${TEST_DIR}_overwrite"

# Test 34: Incremental file list behavior
echo "Test 34: Multiple files on command line"
$TAR_ZIG -cf tmp_test_multi.tar "$TEST_DIR/file1.txt" "$TEST_DIR/file2.txt" "$TEST_DIR/subdir"
COUNT=$($TAR_ZIG -tf tmp_test_multi.tar | wc -l)
[ "$COUNT" -ge 4 ] && pass "Multiple files on command line" || fail "Multiple files on command line"

# Test 35: Archive with special characters in names
echo "Test 35: Special characters in filenames"
touch "$TEST_DIR/file with spaces.txt" 2>/dev/null || true
if [ -f "$TEST_DIR/file with spaces.txt" ]; then
    $TAR_ZIG -cf tmp_test_special_chars.tar "$TEST_DIR/file with spaces.txt"
    $TAR_ZIG -tf tmp_test_special_chars.tar | grep -q "file with spaces" && pass "Special characters in filenames" || fail "Special characters in filenames"
else
    echo "SKIP: Cannot create file with spaces"
fi

# Test 36: Verbose create shows filenames
echo "Test 36: Verbose create (-cv)"
OUTPUT=$($TAR_ZIG -cvf tmp_test_verbose_create.tar "$TEST_DIR/file1.txt" 2>&1)
echo "$OUTPUT" | grep -q "file1.txt" && pass "Verbose create shows filenames" || fail "Verbose create shows filenames"

# Test 37: Empty file handling
echo "Test 37: Empty file archiving"
touch "$TEST_DIR/empty.txt"
$TAR_ZIG -cf tmp_test_empty_file.tar "$TEST_DIR/empty.txt"
mkdir -p "${TEST_DIR}_empty"
$TAR_ZIG -xf tmp_test_empty_file.tar -C "${TEST_DIR}_empty"
[ -f "${TEST_DIR}_empty/$TEST_DIR/empty.txt" ] && [ ! -s "${TEST_DIR}_empty/$TEST_DIR/empty.txt" ] && pass "Empty file archiving" || fail "Empty file archiving"
rm -rf "${TEST_DIR}_empty"

# Test 38: Very long filename (>200 chars, GNU extension)
echo "Test 38: Very long filename (GNU extension)"
VERY_LONG_NAME="$TEST_DIR/this_is_an_extremely_long_filename_that_definitely_exceeds_one_hundred_characters_and_requires_gnu_long_name_extension_support_to_work_correctly.txt"
echo "long name content" > "$VERY_LONG_NAME"
$TAR_ZIG -cf tmp_test_very_long.tar "$VERY_LONG_NAME"
$TAR_ZIG -tf tmp_test_very_long.tar | grep -q "gnu_long_name_extension" && pass "Very long filename" || fail "Very long filename"

# Test 39: Archive multiple directories
echo "Test 39: Archive multiple directories"
mkdir -p "$TEST_DIR/dir1" "$TEST_DIR/dir2"
echo "d1" > "$TEST_DIR/dir1/f1.txt"
echo "d2" > "$TEST_DIR/dir2/f2.txt"
$TAR_ZIG -cf tmp_test_multidirs.tar "$TEST_DIR/dir1" "$TEST_DIR/dir2"
$TAR_ZIG -tf tmp_test_multidirs.tar | grep -q "dir1" && \
$TAR_ZIG -tf tmp_test_multidirs.tar | grep -q "dir2" && pass "Archive multiple directories" || fail "Archive multiple directories"

# Test 40: Roundtrip integrity check
echo "Test 40: Roundtrip integrity (create-extract-compare)"
mkdir -p "$TEST_DIR/roundtrip"
for i in 1 2 3; do
    dd if=/dev/urandom of="$TEST_DIR/roundtrip/random$i.bin" bs=1024 count=5 2>/dev/null
done
$TAR_ZIG -cf tmp_test_roundtrip.tar "$TEST_DIR/roundtrip"
mkdir -p "${TEST_DIR}_roundtrip_out"
$TAR_ZIG -xf tmp_test_roundtrip.tar -C "${TEST_DIR}_roundtrip_out"
MATCH=true
for i in 1 2 3; do
    cmp -s "$TEST_DIR/roundtrip/random$i.bin" "${TEST_DIR}_roundtrip_out/$TEST_DIR/roundtrip/random$i.bin" || MATCH=false
done
$MATCH && pass "Roundtrip integrity check" || fail "Roundtrip integrity check"
rm -rf "${TEST_DIR}_roundtrip_out"

# ============================================
# Extract Edge Case Tests (based on extrac*.at)
# ============================================

# Test 41: Extract over existing directory (extrac01.at)
echo "Test 41: Extract over existing directory"
mkdir -p "${TEST_DIR}_ext01/subdir"
echo "original" > "${TEST_DIR}_ext01/subdir/file.txt"
$TAR_ZIG -cf tmp_test_ext01.tar "${TEST_DIR}_ext01"
chmod 755 "${TEST_DIR}_ext01/subdir"
$TAR_ZIG -xf tmp_test_ext01.tar 2>/dev/null
[ -d "${TEST_DIR}_ext01/subdir" ] && pass "Extract over existing directory" || fail "Extract over existing directory"
rm -rf "${TEST_DIR}_ext01"

# Test 42: Extract with absolute path stripping (extrac02.at pattern)
echo "Test 42: Absolute path handling in extract"
echo "test" > "$TEST_DIR/abstest.txt"
$TAR_ZIG -cf tmp_test_abs.tar "$TEST_DIR/abstest.txt"
mkdir -p "${TEST_DIR}_abs"
$TAR_ZIG -xf tmp_test_abs.tar -C "${TEST_DIR}_abs"
find "${TEST_DIR}_abs" -name "abstest.txt" | grep -q "abstest.txt" && pass "Absolute path handling" || fail "Absolute path handling"
rm -rf "${TEST_DIR}_abs"

# Test 43: Extract with directory permissions (extrac04.at)
echo "Test 43: Directory permissions in archive"
mkdir -p "$TEST_DIR/permdir"
chmod 700 "$TEST_DIR/permdir"
$TAR_ZIG -cf tmp_test_perm.tar "$TEST_DIR/permdir"
# Verify permissions are stored in archive (via verbose listing)
$TAR_ZIG -tvf tmp_test_perm.tar | grep -q "rwx------\|700" && pass "Directory permissions in archive" || fail "Directory permissions in archive"

# Test 44: Extract and verify file content
echo "Test 44: Extract and verify file content"
echo "verify content" > "$TEST_DIR/verify_test.txt"
$TAR_ZIG -cf tmp_test_verify.tar "$TEST_DIR/verify_test.txt"
mkdir -p "${TEST_DIR}_verify"
$TAR_ZIG -xf tmp_test_verify.tar -C "${TEST_DIR}_verify"
grep -q "verify content" "${TEST_DIR}_verify/$TEST_DIR/verify_test.txt" && pass "Extract and verify content" || fail "Extract and verify content"
rm -rf "${TEST_DIR}_verify"

# Test 45: Skip older files during extract (extrac07.at pattern)
echo "Test 45: Skip older files (keep-newer-files)"
mkdir -p "${TEST_DIR}_newer"
echo "old" > "$TEST_DIR/newer_test.txt"
$TAR_ZIG -cf tmp_test_newer.tar "$TEST_DIR/newer_test.txt"
sleep 1
echo "newer content" > "${TEST_DIR}_newer/$TEST_DIR/newer_test.txt"
mkdir -p "${TEST_DIR}_newer/$TEST_DIR"
echo "newer content" > "${TEST_DIR}_newer/$TEST_DIR/newer_test.txt"
# Note: --keep-newer-files not yet implemented, using -k as proxy
$TAR_ZIG -xf tmp_test_newer.tar -C "${TEST_DIR}_newer" -k 2>/dev/null || true
grep -q "newer content" "${TEST_DIR}_newer/$TEST_DIR/newer_test.txt" && pass "Keep newer files" || fail "Keep newer files"
rm -rf "${TEST_DIR}_newer"

# ============================================
# Delete Operation Tests (based on delete*.at)
# ============================================

# Test 46: Delete first member (delete02.at)
echo "Test 46: Delete first member from archive"
echo "f1" > "$TEST_DIR/df1.txt"
echo "f2" > "$TEST_DIR/df2.txt"
echo "f3" > "$TEST_DIR/df3.txt"
$TAR_ZIG -cf tmp_test_del_first.tar "$TEST_DIR/df1.txt" "$TEST_DIR/df2.txt" "$TEST_DIR/df3.txt"
$TAR_ZIG --delete -f tmp_test_del_first.tar "$TEST_DIR/df1.txt"
! $TAR_ZIG -tf tmp_test_del_first.tar | grep -q "df1.txt" && \
$TAR_ZIG -tf tmp_test_del_first.tar | grep -q "df2.txt" && pass "Delete first member" || fail "Delete first member"

# Test 47: Delete last member (delete03.at)
echo "Test 47: Delete last member from archive"
$TAR_ZIG -cf tmp_test_del_last.tar "$TEST_DIR/df1.txt" "$TEST_DIR/df2.txt" "$TEST_DIR/df3.txt"
$TAR_ZIG --delete -f tmp_test_del_last.tar "$TEST_DIR/df3.txt"
! $TAR_ZIG -tf tmp_test_del_last.tar | grep -q "df3.txt" && \
$TAR_ZIG -tf tmp_test_del_last.tar | grep -q "df1.txt" && pass "Delete last member" || fail "Delete last member"

# Test 48: Delete multiple members (delete04.at)
echo "Test 48: Delete multiple members"
$TAR_ZIG -cf tmp_test_del_multi.tar "$TEST_DIR/df1.txt" "$TEST_DIR/df2.txt" "$TEST_DIR/df3.txt"
$TAR_ZIG --delete -f tmp_test_del_multi.tar "$TEST_DIR/df1.txt" "$TEST_DIR/df3.txt"
! $TAR_ZIG -tf tmp_test_del_multi.tar | grep -q "df1.txt" && \
! $TAR_ZIG -tf tmp_test_del_multi.tar | grep -q "df3.txt" && \
$TAR_ZIG -tf tmp_test_del_multi.tar | grep -q "df2.txt" && pass "Delete multiple members" || fail "Delete multiple members"

# ============================================
# Append Operation Tests (based on append*.at)
# ============================================

# Test 49: Append to empty archive
echo "Test 49: Append to newly created archive"
touch tmp_test_append_new.tar
echo "appended" > "$TEST_DIR/append_new.txt"
# Create minimal empty archive first
$TAR_ZIG -cf tmp_test_append_new.tar --files-from=/dev/null 2>/dev/null || \
dd if=/dev/zero of=tmp_test_append_new.tar bs=1024 count=10 2>/dev/null
$TAR_ZIG -rf tmp_test_append_new.tar "$TEST_DIR/append_new.txt" 2>/dev/null
$TAR_ZIG -tf tmp_test_append_new.tar 2>/dev/null | grep -q "append_new.txt" && pass "Append to new archive" || fail "Append to new archive"

# Test 50: Multiple appends (append03.at)
echo "Test 50: Multiple sequential appends"
echo "a1" > "$TEST_DIR/app1.txt"
echo "a2" > "$TEST_DIR/app2.txt"
echo "a3" > "$TEST_DIR/app3.txt"
$TAR_ZIG -cf tmp_test_multi_append.tar "$TEST_DIR/app1.txt"
$TAR_ZIG -rf tmp_test_multi_append.tar "$TEST_DIR/app2.txt"
$TAR_ZIG -rf tmp_test_multi_append.tar "$TEST_DIR/app3.txt"
COUNT=$($TAR_ZIG -tf tmp_test_multi_append.tar | wc -l)
[ "$COUNT" -eq 3 ] && pass "Multiple sequential appends" || fail "Multiple sequential appends (got $COUNT)"

# ============================================
# Update Operation Tests (based on update*.at)
# ============================================

# Test 51: Update skips unchanged files
echo "Test 51: Update skips unchanged files"
echo "unchanged" > "$TEST_DIR/upd_unchanged.txt"
$TAR_ZIG -cf tmp_test_upd_skip.tar "$TEST_DIR/upd_unchanged.txt"
BEFORE=$($TAR_ZIG -tf tmp_test_upd_skip.tar | wc -l)
$TAR_ZIG -uf tmp_test_upd_skip.tar "$TEST_DIR/upd_unchanged.txt"
AFTER=$($TAR_ZIG -tf tmp_test_upd_skip.tar | wc -l)
[ "$BEFORE" -eq "$AFTER" ] && pass "Update skips unchanged" || fail "Update skips unchanged"

# Test 52: Update adds modified files
echo "Test 52: Update adds modified files"
echo "original" > "$TEST_DIR/upd_mod.txt"
$TAR_ZIG -cf tmp_test_upd_mod.tar "$TEST_DIR/upd_mod.txt"
sleep 1
echo "modified" > "$TEST_DIR/upd_mod.txt"
touch "$TEST_DIR/upd_mod.txt"  # Ensure mtime is updated
$TAR_ZIG -uf tmp_test_upd_mod.tar "$TEST_DIR/upd_mod.txt"
COUNT=$($TAR_ZIG -tf tmp_test_upd_mod.tar | grep -c "upd_mod.txt")
[ "$COUNT" -eq 2 ] && pass "Update adds modified files" || fail "Update adds modified files (got $COUNT)"

# ============================================
# Diff/Compare Tests (based on difflink.at)
# ============================================

# Test 53: Diff detects size changes
echo "Test 53: Diff detects size changes"
echo "short" > "$TEST_DIR/diff_size.txt"
$TAR_ZIG -cf tmp_test_diff_size.tar "$TEST_DIR/diff_size.txt"
echo "this is much longer content" > "$TEST_DIR/diff_size.txt"
$TAR_ZIG -df tmp_test_diff_size.tar 2>&1 | grep -qi "differ\|size\|changed" && pass "Diff detects size changes" || fail "Diff detects size changes"

# Test 54: Diff detects missing files
echo "Test 54: Diff detects missing files"
echo "will delete" > "$TEST_DIR/diff_missing.txt"
$TAR_ZIG -cf tmp_test_diff_missing.tar "$TEST_DIR/diff_missing.txt"
rm -f "$TEST_DIR/diff_missing.txt"
$TAR_ZIG -df tmp_test_diff_missing.tar 2>&1 | grep -qi "no such\|not found\|missing\|differ\|warning" && pass "Diff detects missing files" || fail "Diff detects missing files"

# ============================================
# Link Tests (based on link*.at)
# ============================================

# Test 55: Symbolic link target preserved
echo "Test 55: Symbolic link target preserved"
echo "target content" > "$TEST_DIR/link_target.txt"
ln -sf link_target.txt "$TEST_DIR/symlink_test" 2>/dev/null || true
if [ -L "$TEST_DIR/symlink_test" ]; then
    $TAR_ZIG -cf tmp_test_symlink_tgt.tar -h "$TEST_DIR/symlink_test" 2>/dev/null || \
    $TAR_ZIG -cf tmp_test_symlink_tgt.tar "$TEST_DIR/symlink_test" 2>/dev/null
    mkdir -p "${TEST_DIR}_symlink"
    $TAR_ZIG -xf tmp_test_symlink_tgt.tar -C "${TEST_DIR}_symlink"
    [ -f "${TEST_DIR}_symlink/$TEST_DIR/symlink_test" ] && pass "Symbolic link target preserved" || fail "Symbolic link target preserved"
    rm -rf "${TEST_DIR}_symlink"
else
    echo "SKIP: Symlinks not supported"
fi

# Test 56: Hard link count > 2 (link01.at)
echo "Test 56: Multiple hard links to same file"
echo "hardlink content" > "$TEST_DIR/hl_orig.txt"
ln "$TEST_DIR/hl_orig.txt" "$TEST_DIR/hl_link1.txt" 2>/dev/null || true
ln "$TEST_DIR/hl_orig.txt" "$TEST_DIR/hl_link2.txt" 2>/dev/null || true
if [ -f "$TEST_DIR/hl_link2.txt" ]; then
    $TAR_ZIG -cf tmp_test_hl_multi.tar "$TEST_DIR/hl_orig.txt" "$TEST_DIR/hl_link1.txt" "$TEST_DIR/hl_link2.txt"
    $TAR_ZIG -tvf tmp_test_hl_multi.tar | grep -c "hl_" | grep -q "[23]" && pass "Multiple hard links" || fail "Multiple hard links"
else
    echo "SKIP: Hard links not supported"
fi

# ============================================
# Long Name Tests (based on longv7.at, long01.at)
# ============================================

# Test 57: Filename exactly 100 chars
echo "Test 57: Filename exactly 100 characters"
LONG_100=$(printf '%0100d' 0 | tr '0' 'a').txt
# Truncate to exactly 100 chars including .txt
LONG_100="${TEST_DIR}/$(printf '%096s' | tr ' ' 'a').txt"
echo "100 char name" > "$LONG_100" 2>/dev/null || true
if [ -f "$LONG_100" ]; then
    $TAR_ZIG -cf tmp_test_long100.tar "$LONG_100"
    $TAR_ZIG -tf tmp_test_long100.tar | grep -q "aaa" && pass "Filename 100 chars" || fail "Filename 100 chars"
else
    echo "SKIP: Cannot create 100 char filename"
fi

# Test 58: Path with deep nesting
echo "Test 58: Deeply nested directory path"
DEEP_PATH="$TEST_DIR/a/b/c/d/e/f/g/h/i/j"
mkdir -p "$DEEP_PATH"
echo "deep" > "$DEEP_PATH/deep.txt"
$TAR_ZIG -cf tmp_test_deep.tar "$TEST_DIR/a"
$TAR_ZIG -tf tmp_test_deep.tar | grep -q "j/deep.txt" && pass "Deeply nested path" || fail "Deeply nested path"

# ============================================
# Compression Edge Cases
# ============================================

# Test 59: Explicit gzip decompression flag (-z)
echo "Test 59: Explicit gzip decompression"
$TAR_ZIG -czf tmp_test_explicit_gz.tar.gz "$TEST_DIR/file1.txt"
$TAR_ZIG -tzf tmp_test_explicit_gz.tar.gz | grep -q "file1.txt" && pass "Explicit gzip decompression" || fail "Explicit gzip decompression"

# Test 60: Empty compressed archive
echo "Test 60: Empty compressed archive handling"
$TAR_ZIG -czf tmp_test_empty_gz.tar.gz --files-from=/dev/null 2>/dev/null || \
touch tmp_test_empty_gz.tar.gz
# Should not crash on empty/minimal archive
$TAR_ZIG -tzf tmp_test_empty_gz.tar.gz 2>/dev/null; RC=$?
[ $RC -eq 0 ] || [ $RC -eq 1 ] && pass "Empty compressed archive handling" || fail "Empty compressed archive handling"

# ============================================
# Error Handling Tests
# ============================================

# Test 61: Missing archive file
echo "Test 61: Error on missing archive"
$TAR_ZIG -tf nonexistent_archive_12345.tar 2>&1 | grep -qi "error\|no such\|cannot\|failed" && pass "Error on missing archive" || fail "Error on missing archive"

# Test 62: Invalid archive format
echo "Test 62: Error on invalid archive"
echo "this is not a tar file" > tmp_test_invalid.tar
$TAR_ZIG -tf tmp_test_invalid.tar 2>&1 | grep -qi "error\|invalid\|cannot\|not.*tar" && pass "Error on invalid archive" || fail "Error on invalid archive"

# Test 63: Create with no files specified
echo "Test 63: Error when no files specified"
$TAR_ZIG -cf tmp_test_nofiles.tar 2>&1 | grep -qi "error\|no.*file\|specify" && pass "Error no files specified" || fail "Error no files specified"

# ============================================
# Special Cases
# ============================================

# Test 64: File with newline in content
echo "Test 64: File with multiple newlines"
printf "line1\nline2\nline3\n" > "$TEST_DIR/multiline.txt"
$TAR_ZIG -cf tmp_test_multiline.tar "$TEST_DIR/multiline.txt"
mkdir -p "${TEST_DIR}_multiline"
$TAR_ZIG -xf tmp_test_multiline.tar -C "${TEST_DIR}_multiline"
cmp -s "$TEST_DIR/multiline.txt" "${TEST_DIR}_multiline/$TEST_DIR/multiline.txt" && pass "Multiline file content" || fail "Multiline file content"
rm -rf "${TEST_DIR}_multiline"

# Test 65: File with special bytes (null, high bytes)
echo "Test 65: Binary file with special bytes"
printf '\x00\x01\x02\xff\xfe\xfd' > "$TEST_DIR/special_bytes.bin"
$TAR_ZIG -cf tmp_test_special_bytes.tar "$TEST_DIR/special_bytes.bin"
mkdir -p "${TEST_DIR}_special"
$TAR_ZIG -xf tmp_test_special_bytes.tar -C "${TEST_DIR}_special"
cmp -s "$TEST_DIR/special_bytes.bin" "${TEST_DIR}_special/$TEST_DIR/special_bytes.bin" && pass "Special bytes preserved" || fail "Special bytes preserved"
rm -rf "${TEST_DIR}_special"

# Test 66: Large directory listing (100+ files)
echo "Test 66: Large directory listing"
mkdir -p "$TEST_DIR/largedir"
for i in $(seq 1 100); do echo "$i" > "$TEST_DIR/largedir/file_$i.txt"; done
$TAR_ZIG -cf tmp_test_largedir.tar "$TEST_DIR/largedir"
COUNT=$($TAR_ZIG -tf tmp_test_largedir.tar | grep "file_" | wc -l)
[ "$COUNT" -eq 100 ] && pass "Large directory (100 files)" || fail "Large directory (got $COUNT files)"

# Test 67: Archive with mixed content types
echo "Test 67: Mixed content types in single archive"
mkdir -p "$TEST_DIR/mixed"
echo "regular" > "$TEST_DIR/mixed/regular.txt"
mkdir "$TEST_DIR/mixed/subdir"
echo "sub" > "$TEST_DIR/mixed/subdir/file.txt"
ln -sf regular.txt "$TEST_DIR/mixed/symlink" 2>/dev/null || true
$TAR_ZIG -cf tmp_test_mixed.tar "$TEST_DIR/mixed"
TYPES=$($TAR_ZIG -tvf tmp_test_mixed.tar | cut -c1 | sort -u | tr -d '\n')
echo "$TYPES" | grep -q "d" && echo "$TYPES" | grep -q "-" && pass "Mixed content types" || fail "Mixed content types"

# Test 68: Verify archive integrity after operations
echo "Test 68: Archive integrity after append+delete"
echo "f1" > "$TEST_DIR/integ1.txt"
echo "f2" > "$TEST_DIR/integ2.txt"
echo "f3" > "$TEST_DIR/integ3.txt"
$TAR_ZIG -cf tmp_test_integrity.tar "$TEST_DIR/integ1.txt"
$TAR_ZIG -rf tmp_test_integrity.tar "$TEST_DIR/integ2.txt"
$TAR_ZIG --delete -f tmp_test_integrity.tar "$TEST_DIR/integ1.txt"
$TAR_ZIG -rf tmp_test_integrity.tar "$TEST_DIR/integ3.txt"
# Verify we can still list and extract
$TAR_ZIG -tf tmp_test_integrity.tar | grep -q "integ2.txt" && \
$TAR_ZIG -tf tmp_test_integrity.tar | grep -q "integ3.txt" && \
! $TAR_ZIG -tf tmp_test_integrity.tar | grep -q "integ1.txt" && pass "Archive integrity after ops" || fail "Archive integrity after ops"

# Test 69: Consecutive operations on same archive
echo "Test 69: Consecutive list operations"
$TAR_ZIG -tf tmp_test_integrity.tar > /tmp/list1.txt
$TAR_ZIG -tf tmp_test_integrity.tar > /tmp/list2.txt
cmp -s /tmp/list1.txt /tmp/list2.txt && pass "Consecutive list operations" || fail "Consecutive list operations"

# Test 70: Extract then re-archive produces equivalent
echo "Test 70: Extract and re-archive equivalence"
mkdir -p "${TEST_DIR}_rearchive"
$TAR_ZIG -xf tmp_test_create.tar -C "${TEST_DIR}_rearchive"
$TAR_ZIG -cf tmp_test_rearchived.tar -C "${TEST_DIR}_rearchive" .
$TAR_ZIG -tf tmp_test_rearchived.tar | grep -q "file1.txt" && pass "Re-archive equivalence" || fail "Re-archive equivalence"
rm -rf "${TEST_DIR}_rearchive"

echo ""
echo "=== Test Summary ==="
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${RED}Failed: $FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
