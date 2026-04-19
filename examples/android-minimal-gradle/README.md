# android-minimal-gradle

This example intentionally does not use the Android Gradle Plugin or the Gradle
wrapper. It builds a small APK offline with plain Gradle tasks that invoke the
SDK tools exposed by the `path:.#android` dev shell.

## Usage

```bash
nix develop path:.#android
cd examples/android-minimal-gradle
gradle assembleDebug
gradle verifyDebug
```

The APK lands at `build/outputs/apk/app-debug.apk`.
