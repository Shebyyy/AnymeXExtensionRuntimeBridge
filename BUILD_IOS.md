# Building the iOS Runtime Bridge

This guide explains how to build the AnymeX Extension Runtime Bridge with iOS support.

## Overview

The iOS bridge embeds **OpenJDK Zero VM** (from `openjdk/mobile`) as a **static library** (`libjvm.a`) into the Flutter app. This allows running Java/Kotlin extension JARs directly on iOS — no App Store submission required.

## Architecture

```
Dart (IosFfiBridge) ──(FFI)──> Swift (@_cdecl functions)
                                      │
                                      ├── JNI_CreateJavaVM() → libjvm.a (Zero VM)
                                      ├── AttachCurrentThread()
                                      └── CallStaticObjectMethodA()
                                              │
                                              ▼
                                    IosExtensionLoader.java
                                    (inside anymex_ios_runtime.jar)
                                              │
                                              ├── AniyomiSourceMethods.kt (reuse)
                                              ├── CloudStreamExtensionLoader.kt (reuse)
                                              ├── KotatsuExtensionLoader.kt (reuse)
                                              ├── ChildFirstURLClassLoader.kt (reuse)
                                              ├── ApkConverter.kt (reuse, dex2jar embedded)
                                              └── Android API stubs (reuse)
```

## Prerequisites

- **macOS** with Xcode 15+
- **JDK 24** for macOS (boot JDK for building)
- **Homebrew**: `brew install autoconf cmake`

## Step 1: Build OpenJDK Zero VM for iOS

```bash
# Download support libraries (libffi + cups prebuilt for iOS)
curl -L -o mobile-support.zip https://download2.gluonhq.com/mobile/mobile-support-20250106.zip
unzip mobile-support.zip -d ~/mobile-support

# Clone OpenJDK Mobile
git clone git@github.com:openjdk/mobile.git
cd mobile
sh configure \
  --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios \
  --with-libffi-include=~/mobile-support/libffi/include \
  --with-libffi-lib=~/mobile-support/libffi/libs \
  --with-cups-include=~/mobile-support/cups-2.3.6 \
  --with-sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk

# Build static JVM
make CONF=ios-aarch64-zero-release static-libs-image
```

Output: `build/ios-aarch64-zero-release/images/static-libs/`

## Step 2: Copy Static Libraries to iOS Plugin

```bash
BRIDGE_DIR=/path/to/AnymeXExtensionRuntimeBridge
JVM_BUILD=~/mobile/build/ios-aarch64-zero-release/images/static-libs

# Copy all static libraries
mkdir -p $BRIDGE_DIR/ios/libs
cp $JVM_BUILD/lib/zero/libjvm.a $BRIDGE_DIR/ios/libs/
cp $JVM_BUILD/lib/libjava.a $BRIDGE_DIR/ios/libs/
cp $JVM_BUILD/lib/libnet.a $BRIDGE_DIR/ios/libs/
cp $JVM_BUILD/lib/libnio.a $BRIDGE_DIR/ios/libs/
cp $JVM_BUILD/lib/libzip.a $BRIDGE_DIR/ios/libs/
cp $JVM_BUILD/lib/libverify.a $BRIDGE_DIR/ios/libs/
cp ~/mobile-support/libffi/libs/lib/libffi.a $BRIDGE_DIR/ios/libs/

# Copy JDK classes (needed at runtime by the Zero interpreter)
mkdir -p $BRIDGE_DIR/ios/libs/classes
cp -r $JVM_BUILD/lib/*.jar $BRIDGE_DIR/ios/libs/classes/ 2>/dev/null || true
```

## Step 3: Build the iOS Runtime JAR

```bash
cd $BRIDGE_DIR

# Build with Gradle (combines IosExtensionLoader.java + Desktop Kotlin code + Android stubs)
cd RuntimeBridges
cd Desktop && ./gradlew jar && cd ..
cd iOS && javac -cp "../Desktop/build/libs/desktop_bridge.jar" \
  -d ../Desktop/build/classes \
  src/main/java/com/anymex/ios/IosExtensionLoader.java
cd ../Desktop
njar cvf anymex_ios_runtime.jar \
  -C build/classes . \
  -C build/libs/desktop_bridge.jar .
cp anymex_ios_runtime.jar ../../ios/libs/
```

## Step 4: Build the Flutter App

```bash
cd /path/to/AnymeX  # main app
flutter pub get
flutter build ios --release --no-codesign
```

## Step 5: Install on Device

```bash
# Via Xcode (open the Runner.xcworkspace)
open ios/Runner.xcworkspace

# Or via command line (sideload)
devicectl device install build/ios/iphoneos/Runner.app
```

## File Structure

```
ios/
├── Classes/
│   ├── SwiftAnymexExtensionRuntimeBridgePlugin.swift   # FFI → JNI bridge
│   ├── AnymexExtensionRuntimeBridgePlugin.m            # ObjC registrar
│   ├── AnymexExtensionRuntimeBridgePlugin.h
│   ├── SwiftAnymexExtensionRuntimeBridgePlugin-Bridging-Header.h
│   └── jni.h                                           # Minimal JNI types
├── include/
│   └── jni.h                                           # Full JNI header
├── libs/
│   ├── libjvm.a                                        # OpenJDK Zero VM (static)
│   ├── libjava.a                                       # Java native libs
│   ├── libnet.a / libnio.a / libzip.a / libverify.a
│   ├── libffi.a                                        # Foreign Function Interface
│   ├── anymex_ios_runtime.jar                          # Extension loader JAR
│   └── classes/                                        # JDK runtime classes
├── anymex_extension_runtime_bridge.podspec
└── Resources/
    └── PrivacyInfo.xcprivacy

lib/
├── Runtime/
│   ├── Bridge/
│   │   ├── IosFfiBridge.dart                           # Dart FFI bindings
│   │   ├── BridgeDispatcher.dart                        # Updated with iOS mode
│   │   ├── JniBridge.dart
│   │   └── SidecarBridge.dart
│   ├── IosExtensionBase.dart                           # iOS base class
│   ├── RuntimeDownloader.dart                          # Updated for iOS
│   └── RuntimePaths.dart                               # Updated for iOS
├── Services/
│   ├── AniyomiDesktop/
│   │   └── IosAniyomiExtensions.dart                   # iOS Aniyomi
│   ├── CloudStreamDesktop/
│   │   └── IosCloudStreamExtensions.dart               # iOS CloudStream
│   └── KotatsuDesktop/
│       └── IosKotatsuExtensions.dart                   # iOS Kotatsu
├── AnymeXBridge.dart                                   # isSupportedPlatform = true
└── ExtensionManager.dart                               # Registers iOS managers

RuntimeBridges/iOS/
└── src/main/java/com/anymex/ios/
    └── IosExtensionLoader.java                          # Java entry point
```

## Performance Notes

- The **Zero interpreter** is ~10-50x slower than JIT for CPU-heavy code
- Extensions are mostly **network I/O bound** (fetching pages, parsing HTML)
- The bottleneck is **network latency**, not bytecode execution
- Expected performance: **acceptable** for extension loading and page fetching

## Troubleshooting

### `JNI_CreateJavaVM` returns -1
- Check all static libs are in `ios/libs/`
- Verify libffi.a was built for arm64 iOS

### ClassNotFoundError for extension classes
- Ensure `anymex_ios_runtime.jar` is on the classpath
- Check the Android stubs are included in the JAR

### Linker errors (`undefined symbol`)
- Make sure `OTHER_LDFLAGS` includes `-lstdc++ -lc++`
- Verify `LIBRARY_SEARCH_PATHS` points to `ios/libs/`
