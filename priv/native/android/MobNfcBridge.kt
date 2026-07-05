// MobNfcBridge.kt — plugin-owned Kotlin bridge class for mob_nfc.
//
// Mirrors mob_bluetooth's bridge. Re-homed to the plugin's OWN package
// `io.mob.nfc` so the JNI thunk symbol names
// (`Java_io_mob_nfc_MobNfcBridge_*`) are package-stable and shippable (they
// live in the sibling mob_nfc_jni.c).
//
// Registration: mob_dev copies this file into the app Kotlin sourceSet and
// generates `MobPluginBootstrap.registerAll(activity)` (called from
// MainActivity.onCreate) which invokes `register()` then `setActivity()`.
// `register()` calls the `nativeRegister` thunk (zig NIF), which caches THIS
// class's jclass + nfc_* method ids. The NIF's outbound CallStaticVoidMethod
// uses that cache; the `nativeDeliverNfc*` externs resolve to mob_nfc_jni.c.
//
// NFC reading uses NfcAdapter reader mode (enableReaderMode) — foreground
// dispatch while the activity is resumed. The reader callback fires on a binder
// thread; delivery `nativeDeliverNfc*` → enif_send is thread-safe.
package io.mob.nfc

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import java.lang.ref.WeakReference

object MobNfcBridge : io.mob.plugin.MobActivityAware {

  // ── Bridge-class registration (caches this jclass + nfc_* method ids) ────
  @JvmStatic external fun nativeRegister()

  @JvmStatic
  fun register() {
    nativeRegister()
  }

  private var activityRef: WeakReference<Activity>? = null

  // Not @JvmStatic: overrides MobActivityAware.setActivity (illegal to be
  // @JvmStatic on an interface override in an object). Called via instance
  // dispatch from the generated bootstrap.
  override fun setActivity(activity: Activity) {
    activityRef = WeakReference(activity)
  }

  private fun activity(): Activity? = activityRef?.get()

  // One reader session at a time in this cut.
  @Volatile private var adapter: NfcAdapter? = null

  // ── Static methods the NIF calls (signatures cached by nativeRegister) ───

  /** True when the device has an NFC radio present and enabled. */
  @JvmStatic
  fun nfc_available(): Boolean {
    val act = activity() ?: return false
    val a = NfcAdapter.getDefaultAdapter(act) ?: return false
    return a.isEnabled
  }

  /** Start reader mode; NDEF/tag events flow back to `pid`. */
  @JvmStatic
  fun nfc_start_reading(pid: Long, optsJson: String?) {
    val act =
        activity()
            ?: run {
              nativeDeliverNfcError(pid, "no_activity")
              return
            }
    val a = NfcAdapter.getDefaultAdapter(act)
    if (a == null) {
      nativeDeliverNfcError(pid, "unavailable")
      return
    }
    if (!a.isEnabled) {
      nativeDeliverNfcError(pid, "disabled")
      return
    }
    adapter = a
    val flags =
        NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
    act.runOnUiThread {
      try {
        a.enableReaderMode(act, { tag -> onTag(pid, tag) }, flags, null)
        nativeDeliverNfcSessionStarted(pid)
      } catch (_: Throwable) {
        nativeDeliverNfcError(pid, "start_failed")
      }
    }
  }

  /** Stop the reader session started by `pid`. */
  @JvmStatic
  fun nfc_stop_reading(pid: Long) {
    val act = activity()
    val a = adapter
    if (act != null && a != null) {
      act.runOnUiThread {
        try {
          a.disableReaderMode(act)
        } catch (_: Throwable) {}
        nativeDeliverNfcSessionEnded(pid, "done")
      }
    } else {
      nativeDeliverNfcSessionEnded(pid, "done")
    }
  }

  // Reader callback (binder thread): read NDEF if present, else report the tag.
  private fun onTag(pid: Long, tag: Tag) {
    val tagId = tag.id?.joinToString("") { "%02x".format(it.toInt() and 0xFF) } ?: ""
    val ndef = Ndef.get(tag)
    if (ndef == null) {
      val tech = tag.techList?.joinToString(",") ?: ""
      nativeDeliverNfcTag(pid, tagId, tech)
      return
    }
    try {
      ndef.connect()
      val msg = ndef.ndefMessage ?: ndef.cachedNdefMessage
      val bytes = msg?.toByteArray() ?: ByteArray(0)
      nativeDeliverNfcNdef(pid, tagId, bytes, ndef.isWritable, ndef.maxSize)
    } catch (_: Throwable) {
      nativeDeliverNfcError(pid, "read_failed")
    } finally {
      try {
        ndef.close()
      } catch (_: Throwable) {}
    }
  }

  // ── delivery externs (resolve to mob_nfc_jni.c thunks) ───────────────────
  @JvmStatic external fun nativeDeliverNfcSessionStarted(pid: Long)

  @JvmStatic
  external fun nativeDeliverNfcNdef(
      pid: Long,
      tagId: String,
      ndef: ByteArray,
      writable: Boolean,
      maxSize: Int
  )

  @JvmStatic external fun nativeDeliverNfcTag(pid: Long, tagId: String, tech: String)

  @JvmStatic external fun nativeDeliverNfcSessionEnded(pid: Long, reason: String)

  @JvmStatic external fun nativeDeliverNfcError(pid: Long, reason: String)
}
