# GenieX resolves its Java entry points from native code.
#
# libnpu_jni.so looks its classes up by name at runtime
# (FindClass/GetStaticMethodID on com.geniex.sdk.*). R8 renames them in a
# release build, the lookup returns null, and ART aborts the process with
# "JNI DETECTED ERROR IN APPLICATION: java_class == null". The AAR ships no
# consumer rules, so they are declared here.
-keep class com.geniex.** { *; }

# sherpa-onnx does the same thing with fields, not just classes:
# libsherpa-onnx-jni.so resolves `decodingMethod`, `featConfig`, `modelConfig`
# and friends with GetFieldID. Obfuscating the field name makes the lookup fail
# with `NoSuchFieldError: no "Ljava/lang/String;" field "decodingMethod"`,
# OfflineRecognizer's constructor throws, and speech recognition cannot start at
# all. The AAR ships no consumer rules either.
-keep class com.k2fsa.sherpa.onnx.** { *; }

# Every `external fun` binds through a JNI symbol derived from the declaring
# class and method name, so obfuscating either side breaks the link.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# Flutter platform views, MethodChannel handlers and reflection-based plugins
# resolve by name, and generic signatures keep Kotlin's suspend/continuation
# shapes intact.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
