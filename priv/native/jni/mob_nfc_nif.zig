//! mob_nfc_nif — NFC (NDEF read) tier-1 ZIG plugin NIF (Android side).
//!
//! Mirrors the mob_bluetooth plugin's zig/JNI seam. The Kotlin side is the
//! plugin-owned bridge `io.mob.nfc.MobNfcBridge`; the JNI delivery thunks live
//! in the sibling `mob_nfc_jni.c`.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through the named imports `@import("erts")`
//! (→ mob_erts.zig) and `@import("jni")` (→ mob_zig.zig). `get_jenv` + `g_jvm`
//! are mob-core exports linked into the same `.so` (extern-declared, not
//! duplicated).
//!
//! Outbound: `nfc_*` NIFs call the cached `MobNfcBridge` static methods.
//! Inbound: the C thunks call the `mob_deliver_nfc_*` exports below, which
//! `enif_send` a `{:nfc, ...}` message to the pid captured at call time.
//!
//! NDEF is delivered RAW (`NdefMessage.toByteArray()`); the Elixir
//! `MobNfc.Ndef` parses it — one testable parser, no zig/objc duplication.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache (cached by nativeRegister) ──
const NfcMethods = struct {
    available: jni.JMethodID = null,
    start_reading: jni.JMethodID = null,
    start_writing: jni.JMethodID = null,
    stop_reading: jni.JMethodID = null,
};
var g_nfc: NfcMethods = .{};
var g_nfc_cls: jni.JClass = null;

export fn Java_io_mob_nfc_MobNfcBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_nfc_cls = jni.newGlobalRef(jenv, cls);
    if (g_nfc_cls == null) return;
    g_nfc.available = jni.getStaticMethodID(jenv, cls, "nfc_available", "()Z");
    g_nfc.start_reading = jni.getStaticMethodID(jenv, cls, "nfc_start_reading", "(JLjava/lang/String;)V");
    g_nfc.start_writing = jni.getStaticMethodID(jenv, cls, "nfc_start_writing", "(JLjava/lang/String;)V");
    g_nfc.stop_reading = jni.getStaticMethodID(jenv, cls, "nfc_stop_reading", "(J)V");
}

// ── helpers ──
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return @bitCast(pid.pid);
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return .{ .pid = @bitCast(jpid) };
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

fn nfcUnsupported(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "unsupported") });
}

fn makeBinary(env: ?*erts.ErlNifEnv, ptr: [*]const u8, len: usize) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(len, &bin) == 0) return erts.atom(env, "nil");
    if (len > 0) @memcpy(bin.data[0..len], ptr[0..len]);
    return erts.enif_make_binary(env, &bin);
}

fn cstrBinary(env: ?*erts.ErlNifEnv, s: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const p = s orelse return makeBinary(env, "", 0);
    return makeBinary(env, p, std.mem.len(p));
}

// ── NIFs ──
export fn nif_nfc_available(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_nfc.available == null) return erts.atom(env, "false");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "false");
    defer detachIfAttached(attached);
    const r = jenv.*.CallStaticBooleanMethod.?(jenv, g_nfc_cls, g_nfc.available);
    return if (r != 0) erts.atom(env, "true") else erts.atom(env, "false");
}

// Shared: call a (JLjava/lang/String;)V bridge method with the caller's pid and
// argv[0] (the opts JSON binary) marshalled to a Java String.
fn startWithJson(
    env: ?*erts.ErlNifEnv,
    argv: [*]const erts.ERL_NIF_TERM,
    method: jni.JMethodID,
) erts.ERL_NIF_TERM {
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    // argv[0] is the opts JSON binary — hand it to Kotlin as a String (NUL-term copy).
    var jstr: jni.JString = null;
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &bin) != 0) {
        const buf = jni.malloc(bin.size + 1) orelse return erts.atom(env, "error");
        const dst: [*]u8 = @ptrCast(buf);
        @memcpy(dst[0..bin.size], bin.data[0..bin.size]);
        dst[bin.size] = 0;
        jstr = jni.newStringUTF(jenv, @ptrCast(buf));
        jni.free(buf);
    }
    jenv.*.CallStaticVoidMethod.?(jenv, g_nfc_cls, method, pidToJlong(pid), jstr);
    if (jstr != null) jni.deleteLocalRef(jenv, jstr);
    return erts.ok(env);
}

export fn nif_nfc_start_reading(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_nfc.start_reading == null) return nfcUnsupported(env);
    return startWithJson(env, argv, g_nfc.start_reading);
}

export fn nif_nfc_start_writing(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_nfc.start_writing == null) return nfcUnsupported(env);
    return startWithJson(env, argv, g_nfc.start_writing);
}

export fn nif_nfc_stop_reading(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_nfc.stop_reading == null) return nfcUnsupported(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_nfc_cls, g_nfc.stop_reading, pidToJlong(pid));
    return erts.ok(env);
}

// ── deliveries (called from mob_nfc_jni.c thunks) ──
pub export fn mob_deliver_nfc_session_started(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "session_started") });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_nfc_ndef(
    pid_long: jni.JLong,
    tag_id: ?[*:0]const u8,
    ndef_ptr: ?[*]const u8,
    ndef_len: c_int,
    writable: c_int,
    max_size: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ndef_bin = if (ndef_ptr) |p| makeBinary(env, p, @intCast(@max(ndef_len, 0))) else makeBinary(env, "", 0);
    const writable_atom = if (writable != 0) erts.atom(env, "true") else erts.atom(env, "false");
    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "tag_id"),
        erts.atom(env, "ndef"),
        erts.atom(env, "writable"),
        erts.atom(env, "max_size"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        cstrBinary(env, tag_id),
        ndef_bin,
        writable_atom,
        erts.enif_make_int(env, max_size),
    };
    const map = erts.makeMap(env, &keys, &vals) orelse erts.atom(env, "nil");
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "ndef"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_nfc_tag(
    pid_long: jni.JLong,
    tag_id: ?[*:0]const u8,
    tech: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const keys = [_]erts.ERL_NIF_TERM{ erts.atom(env, "tag_id"), erts.atom(env, "tech") };
    const vals = [_]erts.ERL_NIF_TERM{ cstrBinary(env, tag_id), cstrBinary(env, tech) };
    const map = erts.makeMap(env, &keys, &vals) orelse erts.atom(env, "nil");
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "tag"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_nfc_written(pid_long: jni.JLong, nbytes: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const keys = [_]erts.ERL_NIF_TERM{erts.atom(env, "bytes")};
    const vals = [_]erts.ERL_NIF_TERM{erts.enif_make_int(env, nbytes)};
    const map = erts.makeMap(env, &keys, &vals) orelse erts.atom(env, "nil");
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "written"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_nfc_session_ended(pid_long: jni.JLong, reason: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const r = if (reason) |p| erts.enif_make_atom(env, p) else erts.atom(env, "done");
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "session_ended"), r });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_nfc_error(pid_long: jni.JLong, reason: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const r = if (reason) |p| erts.enif_make_atom(env, p) else erts.atom(env, "error");
    const msg = erts.makeTuple(env, .{ erts.atom(env, "nfc"), erts.atom(env, "error"), r });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "nfc_available", .arity = 0, .fptr = nif_nfc_available, .flags = 0 },
    .{ .name = "nfc_start_reading", .arity = 1, .fptr = nif_nfc_start_reading, .flags = 0 },
    .{ .name = "nfc_start_writing", .arity = 1, .fptr = nif_nfc_start_writing, .flags = 0 },
    .{ .name = "nfc_stop_reading", .arity = 0, .fptr = nif_nfc_stop_reading, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_nfc_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_nfc_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
