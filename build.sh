#!/bin/bash
echo "Building SQLThinkRS Rust shared library (.so)..."
echo ""

echo "Cleaning previous build..."

# Try to remove the .so if it exists
if [ -f target/release/libsqlthinkrs.so ]; then
    rm -f target/release/libsqlthinkrs.so 2>/dev/null
    if [ -f target/release/libsqlthinkrs.so ]; then
        echo "WARNING: Could not delete target/release/libsqlthinkrs.so - file may be in use."
        echo "         Close any processes using the library and retry."
        exit 1
    fi
fi

if [ -f target/release/deps/libsqlthinkrs.so ]; then
    rm -f target/release/deps/libsqlthinkrs.so 2>/dev/null
    if [ -f target/release/deps/libsqlthinkrs.so ]; then
        echo "WARNING: Could not delete target/release/deps/libsqlthinkrs.so - file may be in use."
        exit 1
    fi
fi

if [ -d target ]; then
    rm -rf target
fi

echo ""

cargo build --release

if [ $? -eq 0 ]; then
    echo ""
    echo "========================================"
    echo "Build successful!"
    echo "Library location: target/release/libsqlthinkrs.so"
    echo "========================================"
    echo ""
    echo "To test, run: pwsh -ExecutionPolicy Bypass -File test_linux.ps1"
else
    echo ""
    echo "Build failed with error code $?"
    exit 1
fi
