# --- Flutter / Dart ---------------------------------------------------------
# The Flutter engine communicates with plugins via reflection on class names.
-dontwarn io.flutter.**
-keep class io.flutter.** { *; }

# --- youtubedl-android library ----------------------------------------------
# The library runs bundled Python/yt-dlp and uses reflection-heavy helper
# libraries (Commons Compress zip parsing, Commons IO). Keep it intact.
-keep class com.yausername.** { *; }

# --- Apache Commons Compress (zip only) -------------------------------------
# ExtraField subclasses are instantiated reflectively through the ExtraField
# registry while parsing zip extra fields. R8 shrinks their constructors
# away (leaving empty abstract classes), which makes zip parsing throw
# "class X is not a concrete class" at runtime (see ASF COMPRESS-512).
# Keep only the zip package — broader keeps force R8 to retain 7z/XZ code
# paths whose optional dependencies (org.tukaani.xz) are not bundled.
-keep class org.apache.commons.compress.archivers.zip.** { *; }

# --- Apache Commons IO ------------------------------------------------------
-keep class org.apache.commons.io.** { *; }
