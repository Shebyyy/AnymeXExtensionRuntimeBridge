/*
 * Minimal JNI header for AnymeX Extension Runtime Bridge (iOS)
 *
 * This header provides just enough JNI type definitions and function
 * declarations to compile the Swift plugin that embeds OpenJDK Zero VM
 * on iOS ARM64. It covers all functions used by the plugin's JNI calls.
 *
 * Based on the JNI specification (JNI_VERSION_1_8) and OpenJDK Zero VM.
 * Not intended for general-purpose JNI development — only for this plugin.
 */

#ifndef JNI_H_INCLUDED
#define JNI_H_INCLUDED

#include <stdint.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================= */
/* JNI Primitive Types                                                       */
/* ========================================================================= */

typedef int8_t    jbyte;
typedef int16_t   jshort;
typedef uint16_t  jchar;
typedef int32_t   jint;
typedef int64_t   jlong;
typedef float     jfloat;
typedef double    jdouble;
typedef uint8_t   jboolean;

typedef jint      jsize;

/* JNI object types (opaque pointers) */
typedef void*     jobject;
typedef jobject   jclass;
typedef jobject   jstring;
typedef jobject   jthrowable;
typedef jobject   jweak;
typedef jobject   jarray;
typedef jobject   jobjectArray;
typedef jobject   jbooleanArray;
typedef jobject   jbyteArray;
typedef jobject   jcharArray;
typedef jobject   jshortArray;
typedef jobject   jintArray;
typedef jobject   jlongArray;
typedef jobject   jfloatArray;
typedef jobject   jdoubleArray;

typedef struct _jfieldID*   jfieldID;
typedef struct _jmethodID* jmethodID;

/* ========================================================================= */
/* JNI Constants                                                             */
/* ========================================================================= */

#define JNI_FALSE 0
#define JNI_TRUE  1

#define JNI_VERSION_1_1 0x00010001
#define JNI_VERSION_1_2 0x00010002
#define JNI_VERSION_1_4 0x00010004
#define JNI_VERSION_1_6 0x00010006
#define JNI_VERSION_1_8 0x00010008
#define JNI_VERSION_9   0x00090000
#define JNI_VERSION_10  0x000a0000

#define JNI_OK          0
#define JNI_ERR         (-1)
#define JNI_EDETACHED   (-2)
#define JNI_EVERSION    (-3)
#define JNI_ENOMEM      (-4)
#define JNI_EEXIST      (-5)
#define JNI_EINVAL      (-6)

/* JNI Abstract Method & Constructor name/signature constants */
#define JNI_ABORT 0

/* ========================================================================= */
/* JNI Invocation Structures                                                 */
/* ========================================================================= */

typedef struct JavaVMOption {
    char* optionString;
    void* extraInfo;
} JavaVMOption;

typedef struct JavaVMInitArgs {
    jint    version;
    jint    nOptions;
    JavaVMOption* options;
    jboolean ignoreUnrecognized;
} JavaVMInitArgs;

typedef struct JavaVMAttachArgs {
    jint    version;
    char*   name;
    jobject group;
} JavaVMAttachArgs;

/* ========================================================================= */
/* Forward Declarations of JNI Function Tables                               */
/* ========================================================================= */

struct JNINativeInterface_;
struct JNIInvokeInterface_;

/* ========================================================================= */
/* JNIEnv                                                                    */
/* ========================================================================= */

/*
 * JNIEnv is actually a pointer to a struct whose first field is a pointer
 * to the JNINativeInterface_ function table. This matches the standard
 * JNI layout used by OpenJDK Zero VM.
 */
typedef const struct JNINativeInterface_*  JNINativeInterface_Ptr;
typedef struct JNIEnv_ {
    JNINativeInterface_Ptr functions;
} JNIEnv;

/* ========================================================================= */
/* JavaVM                                                                    */
/* ========================================================================= */

typedef const struct JNIInvokeInterface_*  JNIInvokeInterface_Ptr;
typedef struct JavaVM_ {
    JNIInvokeInterface_Ptr functions;
} JavaVM;

/* ========================================================================= */
/* JNINativeInterface — Complete Function Table                              */
/*                                                                           */
/* Every function pointer MUST be in the exact order specified by the JNI   */
 * specification. Wrong offsets will cause crashes when calling any JNI    */
 * function through the table.                                             */
/* ========================================================================= */

struct JNINativeInterface_ {
    /* Reserved slots for C++ virtual table compatibility */
    void* reserved0;
    void* reserved1;
    void* reserved2;
    void* reserved3;

    /* Interface Version */
    jint        (*GetVersion)(JNIEnv*);

    /* Class Operations */
    jclass      (*DefineClass)(JNIEnv*, const char*, jobject, const jbyte*, jsize);
    jclass      (*FindClass)(JNIEnv*, const char*);

    /* Reflection */
    jobject     (*FromReflectedMethod)(JNIEnv*, jobject);
    jobject     (*FromReflectedField)(JNIEnv*, jobject);
    jobject     (*ToReflectedMethod)(JNIEnv*, jclass, jmethodID);

    /* Class / Object Hierarchy */
    jclass      (*GetSuperclass)(JNIEnv*, jclass);
    jboolean    (*IsAssignableFrom)(JNIEnv*, jclass, jclass);
    jobject     (*ToReflectedField)(JNIEnv*, jclass, jfieldID, jboolean);

    /* Throwing Exceptions */
    jint        (*Throw)(JNIEnv*, jthrowable);
    jint        (*ThrowNew)(JNIEnv*, jclass, const char*);
    jthrowable  (*ExceptionOccurred)(JNIEnv*);
    void        (*ExceptionDescribe)(JNIEnv*);
    void        (*ExceptionClear)(JNIEnv*);
    void        (*FatalError)(JNIEnv*, const char*);

    /* Local Reference Management */
    jint        (*PushLocalFrame)(JNIEnv*, jint);
    jobject     (*PopLocalFrame)(JNIEnv*, jobject);

    /* Global / Local Reference Management */
    jobject     (*NewGlobalRef)(JNIEnv*, jobject);
    void        (*DeleteGlobalRef)(JNIEnv*, jobject);
    void        (*DeleteLocalRef)(JNIEnv*, jobject);
    jboolean    (*IsSameObject)(JNIEnv*, jobject, jobject);
    jobject     (*NewLocalRef)(JNIEnv*, jobject);
    jint        (*EnsureLocalCapacity)(JNIEnv*, jint);

    /* Object Allocation */
    jobject     (*AllocObject)(JNIEnv*, jclass);
    jobject     (*NewObject)(JNIEnv*, jclass, jmethodID, ...);
    jobject     (*NewObjectV)(JNIEnv*, jclass, jmethodID, va_list);
    jobject     (*NewObjectA)(JNIEnv*, jclass, jmethodID, const jvalue*);

    /* Object Class / Instance Check */
    jclass      (*GetObjectClass)(JNIEnv*, jobject);
    jboolean    (*IsInstanceOf)(JNIEnv*, jobject, jclass);

    /* Method ID */
    jmethodID   (*GetMethodID)(JNIEnv*, jclass, const char*, const char*);

    /* --- Instance Method Calls (virtual) --- */
    jobject     (*CallObjectMethod)(JNIEnv*, jobject, jmethodID, ...);
    jobject     (*CallObjectMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jobject     (*CallObjectMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jboolean    (*CallBooleanMethod)(JNIEnv*, jobject, jmethodID, ...);
    jboolean    (*CallBooleanMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jboolean    (*CallBooleanMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jbyte       (*CallByteMethod)(JNIEnv*, jobject, jmethodID, ...);
    jbyte       (*CallByteMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jbyte       (*CallByteMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jchar       (*CallCharMethod)(JNIEnv*, jobject, jmethodID, ...);
    jchar       (*CallCharMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jchar       (*CallCharMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jshort      (*CallShortMethod)(JNIEnv*, jobject, jmethodID, ...);
    jshort      (*CallShortMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jshort      (*CallShortMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jint        (*CallIntMethod)(JNIEnv*, jobject, jmethodID, ...);
    jint        (*CallIntMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jint        (*CallIntMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jlong       (*CallLongMethod)(JNIEnv*, jobject, jmethodID, ...);
    jlong       (*CallLongMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jlong       (*CallLongMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jfloat      (*CallFloatMethod)(JNIEnv*, jobject, jmethodID, ...);
    jfloat      (*CallFloatMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jfloat      (*CallFloatMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    jdouble     (*CallDoubleMethod)(JNIEnv*, jobject, jmethodID, ...);
    jdouble     (*CallDoubleMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    jdouble     (*CallDoubleMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);
    void        (*CallVoidMethod)(JNIEnv*, jobject, jmethodID, ...);
    void        (*CallVoidMethodV)(JNIEnv*, jobject, jmethodID, va_list);
    void        (*CallVoidMethodA)(JNIEnv*, jobject, jmethodID, const jvalue*);

    /* --- Instance Method Calls (non-virtual) --- */
    jobject     (*CallNonvirtualObjectMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jobject     (*CallNonvirtualObjectMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jobject     (*CallNonvirtualObjectMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jboolean    (*CallNonvirtualBooleanMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jboolean    (*CallNonvirtualBooleanMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jboolean    (*CallNonvirtualBooleanMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jbyte       (*CallNonvirtualByteMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jbyte       (*CallNonvirtualByteMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jbyte       (*CallNonvirtualByteMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jchar       (*CallNonvirtualCharMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jchar       (*CallNonvirtualCharMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jchar       (*CallNonvirtualCharMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jshort      (*CallNonvirtualShortMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jshort      (*CallNonvirtualShortMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jshort      (*CallNonvirtualShortMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jint        (*CallNonvirtualIntMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jint        (*CallNonvirtualIntMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jint        (*CallNonvirtualIntMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jlong       (*CallNonvirtualLongMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jlong       (*CallNonvirtualLongMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jlong       (*CallNonvirtualLongMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jfloat      (*CallNonvirtualFloatMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jfloat      (*CallNonvirtualFloatMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jfloat      (*CallNonvirtualFloatMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    jdouble     (*CallNonvirtualDoubleMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    jdouble     (*CallNonvirtualDoubleMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    jdouble     (*CallNonvirtualDoubleMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);
    void        (*CallNonvirtualVoidMethod)(JNIEnv*, jobject, jclass, jmethodID, ...);
    void        (*CallNonvirtualVoidMethodV)(JNIEnv*, jobject, jclass, jmethodID, va_list);
    void        (*CallNonvirtualVoidMethodA)(JNIEnv*, jobject, jclass, jmethodID, const jvalue*);

    /* --- Instance Field Access --- */
    jfieldID    (*GetFieldID)(JNIEnv*, jclass, const char*, const char*);
    jobject     (*GetObjectField)(JNIEnv*, jobject, jfieldID);
    jboolean    (*GetBooleanField)(JNIEnv*, jobject, jfieldID);
    jbyte       (*GetByteField)(JNIEnv*, jobject, jfieldID);
    jchar       (*GetCharField)(JNIEnv*, jobject, jfieldID);
    jshort      (*GetShortField)(JNIEnv*, jobject, jfieldID);
    jint        (*GetIntField)(JNIEnv*, jobject, jfieldID);
    jlong       (*GetLongField)(JNIEnv*, jobject, jfieldID);
    jfloat      (*GetFloatField)(JNIEnv*, jobject, jfieldID);
    jdouble     (*GetDoubleField)(JNIEnv*, jobject, jfieldID);
    void        (*SetObjectField)(JNIEnv*, jobject, jfieldID, jobject);
    void        (*SetBooleanField)(JNIEnv*, jobject, jfieldID, jboolean);
    void        (*SetByteField)(JNIEnv*, jobject, jfieldID, jbyte);
    void        (*SetCharField)(JNIEnv*, jobject, jfieldID, jchar);
    void        (*SetShortField)(JNIEnv*, jobject, jfieldID, jshort);
    void        (*SetIntField)(JNIEnv*, jobject, jfieldID, jint);
    void        (*SetLongField)(JNIEnv*, jobject, jfieldID, jlong);
    void        (*SetFloatField)(JNIEnv*, jobject, jfieldID, jfloat);
    void        (*SetDoubleField)(JNIEnv*, jobject, jfieldID, jdouble);

    /* --- Static Method Operations --- */
    jmethodID   (*GetStaticMethodID)(JNIEnv*, jclass, const char*, const char*);

    /* --- Static Method Calls --- */
    jobject     (*CallStaticObjectMethod)(JNIEnv*, jclass, jmethodID, ...);
    jobject     (*CallStaticObjectMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jobject     (*CallStaticObjectMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jboolean    (*CallStaticBooleanMethod)(JNIEnv*, jclass, jmethodID, ...);
    jboolean    (*CallStaticBooleanMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jboolean    (*CallStaticBooleanMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jbyte       (*CallStaticByteMethod)(JNIEnv*, jclass, jmethodID, ...);
    jbyte       (*CallStaticByteMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jbyte       (*CallStaticByteMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jchar       (*CallStaticCharMethod)(JNIEnv*, jclass, jmethodID, ...);
    jchar       (*CallStaticCharMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jchar       (*CallStaticCharMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jshort      (*CallStaticShortMethod)(JNIEnv*, jclass, jmethodID, ...);
    jshort      (*CallStaticShortMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jshort      (*CallStaticShortMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jint        (*CallStaticIntMethod)(JNIEnv*, jclass, jmethodID, ...);
    jint        (*CallStaticIntMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jint        (*CallStaticIntMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jlong       (*CallStaticLongMethod)(JNIEnv*, jclass, jmethodID, ...);
    jlong       (*CallStaticLongMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jlong       (*CallStaticLongMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jfloat      (*CallStaticFloatMethod)(JNIEnv*, jclass, jmethodID, ...);
    jfloat      (*CallStaticFloatMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jfloat      (*CallStaticFloatMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    jdouble     (*CallStaticDoubleMethod)(JNIEnv*, jclass, jmethodID, ...);
    jdouble     (*CallStaticDoubleMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    jdouble     (*CallStaticDoubleMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);
    void        (*CallStaticVoidMethod)(JNIEnv*, jclass, jmethodID, ...);
    void        (*CallStaticVoidMethodV)(JNIEnv*, jclass, jmethodID, va_list);
    void        (*CallStaticVoidMethodA)(JNIEnv*, jclass, jmethodID, const jvalue*);

    /* --- Static Field Access --- */
    jfieldID    (*GetStaticFieldID)(JNIEnv*, jclass, const char*, const char*);
    jobject     (*GetStaticObjectField)(JNIEnv*, jclass, jfieldID);
    jboolean    (*GetStaticBooleanField)(JNIEnv*, jclass, jfieldID);
    jbyte       (*GetStaticByteField)(JNIEnv*, jclass, jfieldID);
    jchar       (*GetStaticCharField)(JNIEnv*, jclass, jfieldID);
    jshort      (*GetStaticShortField)(JNIEnv*, jclass, jfieldID);
    jint        (*GetStaticIntField)(JNIEnv*, jclass, jfieldID);
    jlong       (*GetStaticLongField)(JNIEnv*, jclass, jfieldID);
    jfloat      (*GetStaticFloatField)(JNIEnv*, jclass, jfieldID);
    jdouble     (*GetStaticDoubleField)(JNIEnv*, jclass, jfieldID);
    void        (*SetStaticObjectField)(JNIEnv*, jclass, jfieldID, jobject);
    void        (*SetStaticBooleanField)(JNIEnv*, jclass, jfieldID, jboolean);
    void        (*SetStaticByteField)(JNIEnv*, jclass, jfieldID, jbyte);
    void        (*SetStaticCharField)(JNIEnv*, jclass, jfieldID, jchar);
    void        (*SetStaticShortField)(JNIEnv*, jclass, jfieldID, jshort);
    void        (*SetStaticIntField)(JNIEnv*, jclass, jfieldID, jint);
    void        (*SetStaticLongField)(JNIEnv*, jclass, jfieldID, jlong);
    void        (*SetStaticFloatField)(JNIEnv*, jclass, jfieldID, jfloat);
    void        (*SetStaticDoubleField)(JNIEnv*, jclass, jfieldID, jdouble);

    /* --- String Operations --- */
    jstring     (*NewString)(JNIEnv*, const jchar*, jsize);
    jsize       (*GetStringLength)(JNIEnv*, jstring);
    const jchar* (*GetStringChars)(JNIEnv*, jstring, jboolean*);
    void        (*ReleaseStringChars)(JNIEnv*, jstring, const jchar*);
    jstring     (*NewStringUTF)(JNIEnv*, const char*);
    jsize       (*GetStringUTFLength)(JNIEnv*, jstring);
    const char* (*GetStringUTFChars)(JNIEnv*, jstring, jboolean*);
    void        (*ReleaseStringUTFChars)(JNIEnv*, jstring, const char*);

    /* --- Array Operations --- */
    jsize       (*GetArrayLength)(JNIEnv*, jarray);
    jobjectArray(*NewObjectArray)(JNIEnv*, jsize, jclass, jobject);
    jobject     (*GetObjectArrayElement)(JNIEnv*, jobjectArray, jsize);
    void        (*SetObjectArrayElement)(JNIEnv*, jobjectArray, jsize, jobject);
    jbooleanArray (*NewBooleanArray)(JNIEnv*, jsize);
    jbyteArray  (*NewByteArray)(JNIEnv*, jsize);
    jcharArray  (*NewCharArray)(JNIEnv*, jsize);
    jshortArray (*NewShortArray)(JNIEnv*, jsize);
    jintArray   (*NewIntArray)(JNIEnv*, jsize);
    jlongArray  (*NewLongArray)(JNIEnv*, jsize);
    jfloatArray (*NewFloatArray)(JNIEnv*, jsize);
    jdoubleArray(*NewDoubleArray)(JNIEnv*, jsize);
    jboolean*   (*GetBooleanArrayElements)(JNIEnv*, jbooleanArray, jboolean*);
    jbyte*      (*GetByteArrayElements)(JNIEnv*, jbyteArray, jboolean*);
    jchar*      (*GetCharArrayElements)(JNIEnv*, jcharArray, jboolean*);
    jshort*     (*GetShortArrayElements)(JNIEnv*, jshortArray, jboolean*);
    jint*       (*GetIntArrayElements)(JNIEnv*, jintArray, jboolean*);
    jlong*      (*GetLongArrayElements)(JNIEnv*, jlongArray, jboolean*);
    jfloat*     (*GetFloatArrayElements)(JNIEnv*, jfloatArray, jboolean*);
    jdouble*    (*GetDoubleArrayElements)(JNIEnv*, jdoubleArray, jboolean*);
    void        (*ReleaseBooleanArrayElements)(JNIEnv*, jbooleanArray, jboolean*, jint);
    void        (*ReleaseByteArrayElements)(JNIEnv*, jbyteArray, jbyte*, jint);
    void        (*ReleaseCharArrayElements)(JNIEnv*, jcharArray, jchar*, jint);
    void        (*ReleaseShortArrayElements)(JNIEnv*, jshortArray, jshort*, jint);
    void        (*ReleaseIntArrayElements)(JNIEnv*, jintArray, jint*, jint);
    void        (*ReleaseLongArrayElements)(JNIEnv*, jlongArray, jlong*, jint);
    void        (*ReleaseFloatArrayElements)(JNIEnv*, jfloatArray, jfloat*, jint);
    void        (*ReleaseDoubleArrayElements)(JNIEnv*, jdoubleArray, jdouble*, jint);
    void        (*GetBooleanArrayRegion)(JNIEnv*, jbooleanArray, jsize, jsize, jboolean*);
    void        (*GetByteArrayRegion)(JNIEnv*, jbyteArray, jsize, jsize, jbyte*);
    void        (*GetCharArrayRegion)(JNIEnv*, jcharArray, jsize, jsize, jchar*);
    void        (*GetShortArrayRegion)(JNIEnv*, jshortArray, jsize, jsize, jshort*);
    void        (*GetIntArrayRegion)(JNIEnv*, jintArray, jsize, jsize, jint*);
    void        (*GetLongArrayRegion)(JNIEnv*, jlongArray, jsize, jsize, jlong*);
    void        (*GetFloatArrayRegion)(JNIEnv*, jfloatArray, jsize, jsize, jfloat*);
    void        (*GetDoubleArrayRegion)(JNIEnv*, jdoubleArray, jsize, jsize, jdouble*);
    void        (*SetBooleanArrayRegion)(JNIEnv*, jbooleanArray, jsize, jsize, const jboolean*);
    void        (*SetByteArrayRegion)(JNIEnv*, jbyteArray, jsize, jsize, const jbyte*);
    void        (*SetCharArrayRegion)(JNIEnv*, jcharArray, jsize, jsize, const jchar*);
    void        (*SetShortArrayRegion)(JNIEnv*, jshortArray, jsize, jsize, const jshort*);
    void        (*SetIntArrayRegion)(JNIEnv*, jintArray, jsize, jsize, const jint*);
    void        (*SetLongArrayRegion)(JNIEnv*, jlongArray, jsize, jsize, const jlong*);
    void        (*SetFloatArrayRegion)(JNIEnv*, jfloatArray, jsize, jsize, const jfloat*);
    void        (*SetDoubleArrayRegion)(JNIEnv*, jdoubleArray, jsize, jsize, const jdouble*);

    /* --- Native Method Registration --- */
    jint        (*RegisterNatives)(JNIEnv*, jclass, const JNINativeMethod*, jint);
    jint        (*UnregisterNatives)(JNIEnv*, jclass);

    /* --- Monitor Operations --- */
    jint        (*MonitorEnter)(JNIEnv*, jobject);
    jint        (*MonitorExit)(JNIEnv*, jobject);

    /* --- JavaVM Access --- */
    jint        (*GetJavaVM)(JNIEnv*, JavaVM**);

    /* --- JNI 1.2 Extensions --- */
    void        (*GetStringRegion)(JNIEnv*, jstring, jsize, jsize, jchar*);
    void        (*GetStringUTFRegion)(JNIEnv*, jstring, jsize, jsize, char*);
    void*       (*GetPrimitiveArrayCritical)(JNIEnv*, jarray, jboolean*);
    void        (*ReleasePrimitiveArrayCritical)(JNIEnv*, jarray, void*, jint);
    const jchar* (*GetStringCritical)(JNIEnv*, jstring, jboolean*);
    void        (*ReleaseStringCritical)(JNIEnv*, jstring, const jchar*);
    jweak       (*NewWeakGlobalRef)(JNIEnv*, jobject);
    void        (*DeleteWeakGlobalRef)(JNIEnv*, jweak);
    jboolean    (*ExceptionCheck)(JNIEnv*);

    /* --- JNI 1.4 Extensions --- */
    void        (*NewDirectByteBuffer)(JNIEnv*, void*, jlong);
    void*       (*GetDirectBufferAddress)(JNIEnv*, jobject);
    jlong       (*GetDirectBufferCapacity)(JNIEnv*, jobject);

    /* --- Object Pointer Type (added in JNI for some platforms) --- */
    jobjectRefType (*GetObjectRefType)(JNIEnv*, jobject);
};

/* ========================================================================= */
/* JNIInvokeInterface — JavaVM Function Table                               */
/* ========================================================================= */

struct JNIInvokeInterface_ {
    void* reserved0;
    void* reserved1;
    void* reserved2;

    jint (*DestroyJavaVM)(JavaVM*);
    jint (*AttachCurrentThread)(JavaVM*, void** penv, void* args);
    jint (*DetachCurrentThread)(JavaVM*);
    jint (*GetEnv)(JavaVM*, void** penv, jint version);
    jint (*AttachCurrentThreadAsDaemon)(JavaVM*, void** penv, void* args);
};

/* ========================================================================= */
/* JNI NativeMethod Registration Structure                                  */
/* ========================================================================= */

typedef struct JNINativeMethod {
    const char* name;
    const char* signature;
    void*       fnPtr;
} JNINativeMethod;

/* ========================================================================= */
/* jvalue union for CallStaticObjectMethodA / NewObjectA etc.              */
/* ========================================================================= */

typedef union jvalue {
    jboolean    z;
    jbyte       b;
    jchar       c;
    jshort      s;
    jint        i;
    jlong       j;
    jfloat      f;
    jdouble     d;
    jobject     l;
} jvalue;

/* ========================================================================= */
/* Object Reference Type Enum                                               */
/* ========================================================================= */

typedef enum {
    JNIInvalidRefType    = 0,
    JNILocalRefType      = 1,
    JNIGlobalRefType     = 2,
    JNIWeakGlobalRefType = 3
} jobjectRefType;

/* ========================================================================= */
/* Global JNI Invocation API Functions                                     */
/*                                                                           */
 * These are the symbols exported by libjvm.a (OpenJDK Zero VM) that we    */
 * call from the Swift plugin.                                              */
/* ========================================================================= */

#ifdef __cplusplus
#define JNI_EXIMPORT extern "C"
#else
#define JNI_EXIMPORT extern
#endif

/*
 * JNI_CreateJavaVM — Creates a new Java Virtual Machine.
 *
 * Parameters:
 *   pvm    - [out] Pointer to receive the created JavaVM pointer.
 *   penv   - [out] Pointer to receive the initial JNIEnv pointer.
 *   args   - [in]  Pointer to JavaVMInitArgs with JVM options.
 *
 * Returns: JNI_OK (0) on success, or a negative JNI error code.
 */
JNI_EXIMPORT jint JNI_CreateJavaVM(JavaVM** pvm, void** penv, void* args);

/*
 * JNI_GetDefaultJavaVMInitArgs — Fills in default values for JavaVMInitArgs.
 *
 * Parameters:
 *   args - [in/out] Pointer to JavaVMInitArgs; version must be set first.
 *
 * Returns: JNI_OK on success, or JNI_EVERSION if the version is unsupported.
 */
JNI_EXIMPORT jint JNI_GetDefaultJavaVMInitArgs(void* args);

/*
 * JNI_GetCreatedJavaVMs — Returns all Java VMs that have been created.
 *
 * Parameters:
 *   vmBuf - [out] Buffer to receive JavaVM pointers.
 *   bufLen - [in] Number of entries in the buffer.
 *   nVMs  - [out] Pointer to receive the number of VMs written.
 *
 * Returns: JNI_OK on success.
 */
JNI_EXIMPORT jint JNI_GetCreatedJavaVMs(JavaVM** vmBuf, jsize bufLen, jsize* nVMs);

#undef JNI_EXIMPORT

#ifdef __cplusplus
}
#endif

#endif /* JNI_H_INCLUDED */
