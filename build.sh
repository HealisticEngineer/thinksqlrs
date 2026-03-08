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

# Read current version from Cargo.toml and increment patch
CURRENT_VERSION=$(grep '^version' Cargo.toml | head -1 | sed 's/.*"\(.*\)"/\1/' | tr -d '\r')
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"

echo "Incrementing version: $CURRENT_VERSION -> $NEW_VERSION"
echo ""

# Update Cargo.toml
sed -i "s/version = \"$CURRENT_VERSION\"/version = \"$NEW_VERSION\"/" Cargo.toml

cargo build --release

if [ $? -eq 0 ]; then
    echo ""
    echo "========================================"
    echo "Build successful!  Version: $NEW_VERSION"
    echo "Library location: target/release/libsqlthinkrs.so"
    echo "========================================"

    echo ""
    echo "Deploying .so to Linux PowerShell module..."
    cp -f target/release/libsqlthinkrs.so module/linux/SQLThinkRS/libsqlthinkrs.so
    echo "  [OK] Copied libsqlthinkrs.so"

    echo "Updating module version to $NEW_VERSION..."
    sed -i "s/ModuleVersion     = '[^']*'/ModuleVersion     = '$NEW_VERSION'/" module/linux/SQLThinkRS/SQLThinkRS.psd1
    echo "  [OK] Updated Linux module manifest"

    echo ""
    echo "To test, run: pwsh -ExecutionPolicy Bypass -File test_linux.ps1"
else
    EXITCODE=$?
    echo ""
    echo "Build failed with error code $EXITCODE"
    # Revert Cargo.toml version on failure
    sed -i "s/version = \"$NEW_VERSION\"/version = \"$CURRENT_VERSION\"/" Cargo.toml
    echo "Reverted Cargo.toml version to $CURRENT_VERSION"
    exit $EXITCODE
fi
