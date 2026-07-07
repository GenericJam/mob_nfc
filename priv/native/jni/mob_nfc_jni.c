// mob_nfc_jni.c — JNI delivery thunks for the mob_nfc plugin.
//
// Mirrors mob_bluetooth_jni.c: compiled as a plain C object via the plugin
// `jni_source` pipeline (build.zig `-Dplugin_jni_sources`) — NOT a NIF init
// (no STATIC_ERLANG_NIF_LIBNAME). Each thunk unmarshals the Java args from
// MobNfcBridge's `nativeDeliverNfc*` externs into C primitives, calls the
// matching `mob_deliver_nfc_*` export (defined in the sibling zig NIF
// `mob_nfc_nif.zig`, linked into the same .so), then releases.

#include <jni.h>
#include <stddef.h>

// ── mob_deliver_nfc_* prototypes (mirror the zig export signatures) ──
void mob_deliver_nfc_session_started(jlong pid);
void mob_deliver_nfc_ndef(jlong pid, const char *tag_id, const unsigned char *ndef,
                          int ndef_len, int writable, int max_size);
void mob_deliver_nfc_tag(jlong pid, const char *tag_id, const char *tech);
void mob_deliver_nfc_written(jlong pid, int nbytes);
void mob_deliver_nfc_session_ended(jlong pid, const char *reason);
void mob_deliver_nfc_error(jlong pid, const char *reason);

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcSessionStarted(JNIEnv *env, jclass cls,
                                                            jlong pid) {
  (void)env;
  (void)cls;
  mob_deliver_nfc_session_started(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcNdef(JNIEnv *env, jclass cls, jlong pid,
                                                  jstring tag_id, jbyteArray ndef,
                                                  jboolean writable, jint max_size) {
  (void)cls;
  const char *c_tag = tag_id ? (*env)->GetStringUTFChars(env, tag_id, NULL) : NULL;
  jbyte *buf = ndef ? (*env)->GetByteArrayElements(env, ndef, NULL) : NULL;
  jsize len = ndef ? (*env)->GetArrayLength(env, ndef) : 0;
  mob_deliver_nfc_ndef(pid, c_tag ? c_tag : "", (const unsigned char *)buf, (int)len,
                       writable ? 1 : 0, (int)max_size);
  if (buf) (*env)->ReleaseByteArrayElements(env, ndef, buf, JNI_ABORT);
  if (c_tag) (*env)->ReleaseStringUTFChars(env, tag_id, c_tag);
}

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcTag(JNIEnv *env, jclass cls, jlong pid,
                                                 jstring tag_id, jstring tech) {
  (void)cls;
  const char *c_tag = tag_id ? (*env)->GetStringUTFChars(env, tag_id, NULL) : NULL;
  const char *c_tech = tech ? (*env)->GetStringUTFChars(env, tech, NULL) : NULL;
  mob_deliver_nfc_tag(pid, c_tag ? c_tag : "", c_tech ? c_tech : "");
  if (c_tag) (*env)->ReleaseStringUTFChars(env, tag_id, c_tag);
  if (c_tech) (*env)->ReleaseStringUTFChars(env, tech, c_tech);
}

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcWritten(JNIEnv *env, jclass cls, jlong pid,
                                                     jint bytes) {
  (void)env;
  (void)cls;
  mob_deliver_nfc_written(pid, (int)bytes);
}

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcSessionEnded(JNIEnv *env, jclass cls,
                                                          jlong pid, jstring reason) {
  (void)cls;
  const char *c_reason = reason ? (*env)->GetStringUTFChars(env, reason, NULL) : NULL;
  mob_deliver_nfc_session_ended(pid, c_reason ? c_reason : "done");
  if (c_reason) (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_nfc_MobNfcBridge_nativeDeliverNfcError(JNIEnv *env, jclass cls, jlong pid,
                                                   jstring reason) {
  (void)cls;
  const char *c_reason = reason ? (*env)->GetStringUTFChars(env, reason, NULL) : NULL;
  mob_deliver_nfc_error(pid, c_reason ? c_reason : "error");
  if (c_reason) (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}
