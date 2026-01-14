#!/bin/bash
#
# tar-zig Installation Script
# Installs tar-zig binary to a Unix-based operating system
#
# This script installs:
#   - tar-zig     (alternative to tar)
#
# IMPORTANT: This does NOT modify or replace the system's native tar command.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default installation prefix
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"

# Build optimization level
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                     tar-zig Installer                     ║"
    echo "║       Memory-safe tar implementation written in Zig       ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_requirements() {
    info "Checking requirements..."

    # Check for Unix-like OS
    case "$(uname -s)" in
        Linux*|Darwin*|FreeBSD*|OpenBSD*|NetBSD*)
            info "Detected OS: $(uname -s)"
            ;;
        *)
            error "This installer only supports Unix-based operating systems."
            ;;
    esac

    # Check for Zig compiler
    if ! command -v zig &> /dev/null; then
        error "Zig compiler not found. Please install Zig 0.13.0 or later.
       Visit: https://ziglang.org/download/"
    fi

    # Check Zig version
    ZIG_VERSION=$(zig version)
    info "Found Zig version: $ZIG_VERSION"

    # Check for root/sudo access for installation
    if [ "$EUID" -ne 0 ] && [ ! -w "$BINDIR" ]; then
        warn "Installation to $BINDIR requires root privileges."
        warn "You may need to run this script with sudo or as root."
    fi

    success "All requirements met."
}

build_release() {
    info "Building tar-zig with $OPTIMIZE optimization..."

    cd "$SCRIPT_DIR"

    # Clean previous build
    if [ -d "zig-out" ]; then
        info "Cleaning previous build..."
        rm -rf zig-out
    fi

    # Build with release optimizations
    if ! zig build -Doptimize="$OPTIMIZE"; then
        error "Build failed. Please check the error messages above."
    fi

    # Verify binary was created
    if [ ! -f "zig-out/bin/tar-zig" ]; then
        error "Build completed but tar-zig binary not found."
    fi

    success "Build completed successfully."
}

install_binaries() {
    info "Installing binaries to $BINDIR..."

    # Create bin directory if it doesn't exist
    if [ ! -d "$BINDIR" ]; then
        info "Creating directory: $BINDIR"
        mkdir -p "$BINDIR" || error "Failed to create $BINDIR"
    fi

    # Install tar-zig
    info "Installing tar-zig..."
    cp "$SCRIPT_DIR/zig-out/bin/tar-zig" "$BINDIR/tar-zig" || error "Failed to install tar-zig"
    chmod 755 "$BINDIR/tar-zig" || error "Failed to set permissions on tar-zig"

    success "Binary installed successfully."
}

run_tests() {
    info "Running test suite..."

    cd "$SCRIPT_DIR"

    # Run Zig unit tests
    if ! zig build test; then
        error "Unit tests failed. Please check the error messages above."
    fi

    success "All tests passed."
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  Installation Complete!                     ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Installed binary:"
    echo "  • tar-zig -> $BINDIR/tar-zig"
    echo ""
    echo "Usage examples:"
    echo "  tar-zig -cvf archive.tar file1 file2     # Create archive"
    echo "  tar-zig -xvf archive.tar                 # Extract archive"
    echo "  tar-zig -tvf archive.tar                 # List archive contents"
    echo "  tar-zig -cvzf archive.tar.gz dir/        # Create gzip compressed"
    echo "  tar-zig -xvzf archive.tar.gz             # Extract gzip compressed"
    echo "  tar-zig -rvf archive.tar newfile         # Append to archive"
    echo "  tar-zig --delete -f archive.tar file     # Delete from archive"
    echo "  tar-zig -uvf archive.tar file            # Update archive"
    echo ""
    echo "Supported compression:"
    echo "  -z, --gzip      Filter through gzip"
    echo "  -j, --bzip2     Filter through bzip2"
    echo "  -J, --xz        Filter through xz"
    echo ""
    echo -e "${BLUE}The system's native 'tar' command has NOT been modified.${NC}"
    echo ""
}

show_help() {
    echo "tar-zig Installation Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -p, --prefix DIR    Installation prefix (default: /usr/local)"
    echo "  -b, --bindir DIR    Binary directory (default: PREFIX/bin)"
    echo "  -o, --optimize OPT  Optimization level (default: ReleaseSafe)"
    echo "                      Options: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall"
    echo "  --build-only        Only build, do not install"
    echo "  --skip-build        Skip build, only install (requires previous build)"
    echo "  --with-tests        Run tests before installation"
    echo ""
    echo "Environment variables:"
    echo "  PREFIX    Installation prefix"
    echo "  BINDIR    Binary directory"
    echo "  OPTIMIZE  Optimization level"
    echo ""
    echo "Examples:"
    echo "  $0                           # Build and install to /usr/local/bin"
    echo "  $0 --prefix /opt/tar-zig     # Install to /opt/tar-zig/bin"
    echo "  $0 --with-tests              # Run tests before installing"
    echo "  $0 --build-only              # Only build, don't install"
    echo ""
}

# Parse command line arguments
BUILD_ONLY=false
SKIP_BUILD=false
WITH_TESTS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--prefix)
            PREFIX="$2"
            BINDIR="$PREFIX/bin"
            shift 2
            ;;
        -b|--bindir)
            BINDIR="$2"
            shift 2
            ;;
        -o|--optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --with-tests)
            WITH_TESTS=true
            shift
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Main execution
main() {
    print_banner
    check_requirements

    if [ "$SKIP_BUILD" = false ]; then
        build_release
    else
        info "Skipping build (--skip-build specified)"
        if [ ! -f "$SCRIPT_DIR/zig-out/bin/tar-zig" ]; then
            error "No previous build found. Run without --skip-build first."
        fi
    fi

    if [ "$WITH_TESTS" = true ]; then
        run_tests
    fi

    if [ "$BUILD_ONLY" = false ]; then
        install_binaries
        print_summary
    else
        info "Build complete (--build-only specified)"
        echo ""
        echo "Built binary is in: $SCRIPT_DIR/zig-out/bin/"
        echo "  • tar-zig"
        echo ""
    fi
}

main
