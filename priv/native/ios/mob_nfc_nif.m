// mob_nfc_nif.m — NFC (NDEF read) tier-1 plugin NIF, iOS (CoreNFC).
//
// Mirrors the mob_bluetooth iOS NIF: a static plugin NIF compiled with
// -DSTATIC_ERLANG_NIF_LIBNAME=mob_nfc_nif, so ERL_NIF_INIT emits the
// `mob_nfc_nif_nif_init` static-init symbol the driver table looks up.
// Delegate callbacks enif_send {:nfc, ...} to the pid captured at start.
//
// Uses NFCNDEFReaderSession (NDEF read). The detected NFCNDEFMessage is
// re-encoded to raw NDEF wire bytes and delivered as `{:nfc, :ndef, %{ndef:
// bytes, ...}}` — the same shape Android delivers, so the one Elixir parser
// (MobNfc.Ndef) serves both platforms.
//
// Requires the com.apple.developer.nfc.readersession.formats entitlement and
// an NFCReaderUsageDescription Info.plist key (see the plugin manifest /
// host_requirements). Reading is unavailable on the iOS Simulator.

#import <CoreNFC/CoreNFC.h>
#import <Foundation/Foundation.h>
#include <erl_nif.h>
#include <string.h>

// ── send helpers (enif_send from delegate callbacks) ─────────────────────
static void nfc_send_simple(const ErlNifPid *pid, const char *tag) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg =
      enif_make_tuple2(e, enif_make_atom(e, "nfc"), enif_make_atom(e, tag));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static void nfc_send_reason(const ErlNifPid *pid, const char *event,
                            const char *reason) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "nfc"), enif_make_atom(e, event),
                       enif_make_atom(e, reason));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static void nfc_send_ndef(const ErlNifPid *pid, NSData *ndef) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM ndef_bin;
  unsigned char *buf = enif_make_new_binary(e, ndef.length, &ndef_bin);
  if (ndef.length > 0)
    memcpy(buf, ndef.bytes, ndef.length);
  ERL_NIF_TERM empty_id;
  enif_make_new_binary(e, 0, &empty_id);
  // iOS NFCNDEFReaderSession's read path exposes neither the tag UID nor the
  // writable/capacity flags, so those are placeholders (tag_id "", writable
  // false, max_size 0) — the NDEF payload itself is complete.
  ERL_NIF_TERM keys[4] = {
      enif_make_atom(e, "tag_id"), enif_make_atom(e, "ndef"),
      enif_make_atom(e, "writable"), enif_make_atom(e, "max_size")};
  ERL_NIF_TERM vals[4] = {empty_id, ndef_bin, enif_make_atom(e, "false"),
                          enif_make_int(e, 0)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 4, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "nfc"),
                                      enif_make_atom(e, "ndef"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// {:nfc, :written, %{bytes: n}} — an NDEF write completed.
static void nfc_send_written(const ErlNifPid *pid, int nbytes) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[1] = {enif_make_atom(e, "bytes")};
  ERL_NIF_TERM vals[1] = {enif_make_int(e, nbytes)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 1, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "nfc"),
                                      enif_make_atom(e, "written"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// Lowercase hex string of an NSData UID (nil -> empty binary).
static ERL_NIF_TERM nfc_uid_binary(ErlNifEnv *e, NSData *uid) {
  if (uid == nil || uid.length == 0) {
    ERL_NIF_TERM empty;
    enif_make_new_binary(e, 0, &empty);
    return empty;
  }
  static const char *hex = "0123456789abcdef";
  const unsigned char *b = uid.bytes;
  ERL_NIF_TERM out;
  unsigned char *dst = enif_make_new_binary(e, uid.length * 2, &out);
  for (NSUInteger i = 0; i < uid.length; i++) {
    dst[i * 2] = (unsigned char)hex[(b[i] >> 4) & 0xF];
    dst[i * 2 + 1] = (unsigned char)hex[b[i] & 0xF];
  }
  return out;
}

// {:nfc, :tag, %{tag_id: <hex>, tech: <string>}} — a non-NDEF tag's UID + type.
static void nfc_send_tag(const ErlNifPid *pid, NSData *uid, const char *tech) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM keys[2] = {enif_make_atom(e, "tag_id"),
                          enif_make_atom(e, "tech")};
  ERL_NIF_TERM tech_bin;
  size_t tlen = strlen(tech);
  unsigned char *tb = enif_make_new_binary(e, tlen, &tech_bin);
  memcpy(tb, tech, tlen);
  ERL_NIF_TERM vals[2] = {nfc_uid_binary(e, uid), tech_bin};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 2, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "nfc"),
                                      enif_make_atom(e, "tag"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// Encode an NFCNDEFMessage to its raw NDEF wire bytes (inverse of
// MobNfc.Ndef.parse/1): per-record header (MB/ME/SR/IL flags + TNF), type
// length, payload length (1 or 4 bytes), optional id length, then
// type/id/payload.
static NSData *mob_ndef_message_to_bytes(NFCNDEFMessage *msg) {
  NSMutableData *out = [NSMutableData data];
  NSArray<NFCNDEFPayload *> *records = msg.records;
  NSUInteger n = records.count;
  for (NSUInteger i = 0; i < n; i++) {
    NFCNDEFPayload *r = records[i];
    NSData *type = r.type;
    NSData *identifier = r.identifier;
    NSData *payload = r.payload;
    uint8_t tnf = (uint8_t)(r.typeNameFormat & 0x07);
    BOOL sr = payload.length < 256;
    BOOL il = identifier.length > 0;
    uint8_t flags = tnf;
    if (i == 0)
      flags |= 0x80; // MB
    if (i == n - 1)
      flags |= 0x40; // ME
    if (sr)
      flags |= 0x10; // SR
    if (il)
      flags |= 0x08; // IL
    [out appendBytes:&flags length:1];
    uint8_t type_len = (uint8_t)type.length;
    [out appendBytes:&type_len length:1];
    if (sr) {
      uint8_t pl = (uint8_t)payload.length;
      [out appendBytes:&pl length:1];
    } else {
      uint32_t pl = (uint32_t)payload.length;
      uint8_t b[4] = {(uint8_t)(pl >> 24), (uint8_t)(pl >> 16),
                      (uint8_t)(pl >> 8), (uint8_t)pl};
      [out appendBytes:b length:4];
    }
    if (il) {
      uint8_t id_len = (uint8_t)identifier.length;
      [out appendBytes:&id_len length:1];
    }
    if (type_len)
      [out appendData:type];
    if (il)
      [out appendData:identifier];
    if (payload.length)
      [out appendData:payload];
  }
  return out;
}

// Parse raw NDEF wire bytes into an NFCNDEFMessage (inverse of
// mob_ndef_message_to_bytes / MobNfc.Ndef.parse). CoreNFC has no
// message-from-bytes initializer, so we rebuild NFCNDEFPayload records by hand.
// Returns nil on malformed input.
static NFCNDEFMessage *mob_bytes_to_ndef_message(NSData *data) {
  const uint8_t *b = data.bytes;
  NSUInteger len = data.length;
  NSUInteger i = 0;
  NSMutableArray<NFCNDEFPayload *> *records = [NSMutableArray array];
  while (i < len) {
    if (i + 2 > len)
      return nil;
    uint8_t flags = b[i++];
    uint8_t type_len = b[i++];
    BOOL sr = (flags & 0x10) != 0;
    BOOL il = (flags & 0x08) != 0;
    uint8_t tnf = flags & 0x07;
    uint32_t payload_len;
    if (sr) {
      if (i + 1 > len)
        return nil;
      payload_len = b[i++];
    } else {
      if (i + 4 > len)
        return nil;
      payload_len = ((uint32_t)b[i] << 24) | ((uint32_t)b[i + 1] << 16) |
                    ((uint32_t)b[i + 2] << 8) | (uint32_t)b[i + 3];
      i += 4;
    }
    uint8_t id_len = 0;
    if (il) {
      if (i + 1 > len)
        return nil;
      id_len = b[i++];
    }
    if (i + type_len > len || i + type_len + id_len > len ||
        (uint64_t)i + type_len + id_len + payload_len > len)
      return nil;
    NSData *type = [data subdataWithRange:NSMakeRange(i, type_len)];
    i += type_len;
    NSData *identifier = [data subdataWithRange:NSMakeRange(i, id_len)];
    i += id_len;
    NSData *payload = [data subdataWithRange:NSMakeRange(i, payload_len)];
    i += payload_len;
    NFCNDEFPayload *p =
        [[NFCNDEFPayload alloc] initWithFormat:(NFCTypeNameFormat)tnf
                                          type:type
                                    identifier:identifier
                                       payload:payload];
    if (p)
      [records addObject:p];
  }
  return [[NFCNDEFMessage alloc] initWithNDEFRecords:records];
}

// ── reader-session delegate ──────────────────────────────────────────────
@interface MobNfcReader : NSObject <NFCNDEFReaderSessionDelegate>
@property(nonatomic, assign) ErlNifPid pid;
@end

@implementation MobNfcReader

- (void)readerSessionDidBecomeActive:(NFCNDEFReaderSession *)session {
  nfc_send_simple(&_pid, "session_started");
}

- (void)readerSession:(NFCNDEFReaderSession *)session
       didDetectNDEFs:(NSArray<NFCNDEFMessage *> *)messages {
  for (NFCNDEFMessage *m in messages) {
    nfc_send_ndef(&_pid, mob_ndef_message_to_bytes(m));
  }
}

- (void)readerSession:(NFCNDEFReaderSession *)session
    didInvalidateWithError:(NSError *)error {
  const char *reason = "error";
  if ([error.domain isEqualToString:NFCErrorDomain]) {
    switch (error.code) {
    case NFCReaderSessionInvalidationErrorUserCanceled:
      reason = "user_cancel";
      break;
    case NFCReaderSessionInvalidationErrorSessionTimeout:
      reason = "timeout";
      break;
    case NFCReaderSessionInvalidationErrorFirstNDEFTagRead:
      reason = "done";
      break;
    default:
      reason = "error";
      break;
    }
  }
  nfc_send_reason(&_pid, "session_ended", reason);
}

@end

// ── raw-tag reader delegate (NFCTagReaderSession — non-NDEF tags) ─────────
@interface MobNfcTagReader : NSObject <NFCTagReaderSessionDelegate>
@property(nonatomic, assign) ErlNifPid pid;
@end

@implementation MobNfcTagReader

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session {
  nfc_send_simple(&_pid, "session_started");
}

- (void)tagReaderSession:(NFCTagReaderSession *)session
           didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags {
  id<NFCTag> tag = tags.firstObject;
  NSData *uid = nil;
  const char *tech = "unknown";
  if (tag) {
    switch (tag.type) {
    case NFCTagTypeMiFare:
      uid = [tag asNFCMiFareTag].identifier;
      tech = "MiFare";
      break;
    case NFCTagTypeISO7816Compatible:
      uid = [tag asNFCISO7816Tag].identifier;
      tech = "ISO7816";
      break;
    case NFCTagTypeISO15693:
      uid = [tag asNFCISO15693Tag].identifier;
      tech = "ISO15693";
      break;
    case NFCTagTypeFeliCa:
      uid = [tag asNFCFeliCaTag].currentIDm;
      tech = "FeliCa";
      break;
    default:
      break;
    }
  }
  nfc_send_tag(&_pid, uid, tech);
  session.alertMessage = @"Tag read";
  [session invalidateSession];
}

- (void)tagReaderSession:(NFCTagReaderSession *)session
    didInvalidateWithError:(NSError *)error {
  const char *reason = "error";
  if ([error.domain isEqualToString:NFCErrorDomain]) {
    switch (error.code) {
    case NFCReaderSessionInvalidationErrorUserCanceled:
      reason = "user_cancel";
      break;
    case NFCReaderSessionInvalidationErrorSessionTimeout:
      reason = "timeout";
      break;
    default:
      reason = "done";
      break;
    }
  }
  nfc_send_reason(&_pid, "session_ended", reason);
}

@end

// ── writer delegate (NFCNDEFReaderSession, didDetectTags → writeNDEF) ─────
// Implementing readerSession:didDetectTags: makes CoreNFC hand us a
// connectable NFCNDEFTag (didDetectNDEFs is then NOT called), which is the
// only way to write.
@interface MobNfcWriter : NSObject <NFCNDEFReaderSessionDelegate>
@property(nonatomic, assign) ErlNifPid pid;
@property(nonatomic, strong) NSData *payload; // raw NDEF message bytes to write
@end

@implementation MobNfcWriter

- (void)readerSessionDidBecomeActive:(NFCNDEFReaderSession *)session {
  nfc_send_simple(&_pid, "session_started");
}

- (void)readerSession:(NFCNDEFReaderSession *)session
        didDetectTags:(NSArray<__kindof id<NFCNDEFTag>> *)tags {
  id<NFCNDEFTag> tag = tags.firstObject;
  if (!tag) {
    [session restartPolling];
    return;
  }
  ErlNifPid pid = _pid;
  NSData *payloadBytes = _payload;
  [session connectToTag:tag
      completionHandler:^(NSError *connErr) {
        if (connErr) {
          nfc_send_reason(&pid, "error", "write_failed");
          [session invalidateSessionWithErrorMessage:@"Connection failed"];
          return;
        }
        [tag queryNDEFStatus:^(NFCNDEFStatus status, NSUInteger capacity,
                               NSError *qErr) {
          if (qErr || status == NFCNDEFStatusNotSupported) {
            nfc_send_reason(&pid, "error", "not_ndef");
            [session invalidateSessionWithErrorMessage:@"Not an NDEF tag"];
            return;
          }
          if (status == NFCNDEFStatusReadOnly) {
            nfc_send_reason(&pid, "error", "read_only");
            [session invalidateSessionWithErrorMessage:@"Tag is read-only"];
            return;
          }
          NFCNDEFMessage *msg = mob_bytes_to_ndef_message(payloadBytes);
          if (!msg) {
            nfc_send_reason(&pid, "error", "write_failed");
            [session invalidateSessionWithErrorMessage:@"Bad NDEF message"];
            return;
          }
          if (msg.length > capacity) {
            nfc_send_reason(&pid, "error", "too_small");
            [session
                invalidateSessionWithErrorMessage:@"Message too large for tag"];
            return;
          }
          [tag writeNDEF:msg
              completionHandler:^(NSError *wErr) {
                if (wErr) {
                  nfc_send_reason(&pid, "error", "write_failed");
                  [session invalidateSessionWithErrorMessage:@"Write failed"];
                } else {
                  nfc_send_written(&pid, (int)payloadBytes.length);
                  session.alertMessage = @"Written ✓";
                  [session invalidateSession];
                }
              }];
        }];
      }];
}

- (void)readerSession:(NFCNDEFReaderSession *)session
    didInvalidateWithError:(NSError *)error {
  const char *reason = "done";
  if ([error.domain isEqualToString:NFCErrorDomain]) {
    switch (error.code) {
    case NFCReaderSessionInvalidationErrorUserCanceled:
      reason = "user_cancel";
      break;
    case NFCReaderSessionInvalidationErrorSessionTimeout:
      reason = "timeout";
      break;
    default:
      reason = "done";
      break;
    }
  }
  nfc_send_reason(&_pid, "session_ended", reason);
}

@end

// One reader session at a time. Strong statics (ARC retains).
static MobNfcReader *g_reader = nil;
static NFCNDEFReaderSession *g_session = nil;
static MobNfcTagReader *g_tag_reader = nil;
static NFCTagReaderSession *g_tag_session = nil;
static MobNfcWriter *g_writer = nil;
static NFCNDEFReaderSession *g_write_session = nil;

// ── NIFs ─────────────────────────────────────────────────────────────────
static ERL_NIF_TERM nif_nfc_available(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_atom(env, NFCNDEFReaderSession.readingAvailable ? "true"
                                                                   : "false");
}

static ERL_NIF_TERM nif_nfc_start_reading(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  if (!NFCNDEFReaderSession.readingAvailable) {
    ErlNifPid p;
    enif_self(env, &p);
    nfc_send_reason(&p, "error", "unavailable");
    return enif_make_atom(env, "ok");
  }

  ErlNifPid pid;
  enif_self(env, &pid);

  NSString *alert = @"Hold your phone near an NFC tag";
  __block BOOL tag_mode = NO;
  ErlNifBinary bin;
  if (enif_inspect_binary(env, argv[0], &bin)) {
    NSData *d = [NSData dataWithBytes:bin.data length:bin.size];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
      if ([obj objectForKey:@"alert"])
        alert = [obj objectForKey:@"alert"];
      tag_mode = [[obj objectForKey:@"mode"] isEqual:@"tag"];
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_session) {
      [g_session invalidateSession];
      g_session = nil;
    }
    if (g_tag_session) {
      [g_tag_session invalidateSession];
      g_tag_session = nil;
    }
    if (g_write_session) {
      [g_write_session invalidateSession];
      g_write_session = nil;
    }
    if (tag_mode) {
      // Raw-tag mode: read any tag's UID + type (incl. non-NDEF smartcards).
      g_tag_reader = [[MobNfcTagReader alloc] init];
      g_tag_reader.pid = pid;
      // ISO14443 (incl. ISO7816 EMV) + ISO15693. FeliCa (ISO18092) omitted —
      // it needs a separate felica.systemcodes Info.plist key.
      g_tag_session = [[NFCTagReaderSession alloc]
          initWithPollingOption:NFCPollingISO14443 | NFCPollingISO15693
                       delegate:g_tag_reader
                          queue:dispatch_get_main_queue()];
      g_tag_session.alertMessage = alert;
      [g_tag_session beginSession];
    } else {
      g_reader = [[MobNfcReader alloc] init];
      g_reader.pid = pid;
      g_session = [[NFCNDEFReaderSession alloc]
                  initWithDelegate:g_reader
                             queue:dispatch_get_main_queue()
          invalidateAfterFirstRead:NO];
      g_session.alertMessage = alert;
      [g_session beginSession];
    }
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_nfc_start_writing(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  if (!NFCNDEFReaderSession.readingAvailable) {
    ErlNifPid p;
    enif_self(env, &p);
    nfc_send_reason(&p, "error", "unavailable");
    return enif_make_atom(env, "ok");
  }

  ErlNifPid pid;
  enif_self(env, &pid);

  NSString *alert = @"Hold your phone near a writable NFC tag";
  __block NSData *payload = nil;
  ErlNifBinary bin;
  if (enif_inspect_binary(env, argv[0], &bin)) {
    NSData *d = [NSData dataWithBytes:bin.data length:bin.size];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
      if ([obj objectForKey:@"alert"])
        alert = [obj objectForKey:@"alert"];
      id ndef_b64 = [obj objectForKey:@"ndef"];
      if ([ndef_b64 isKindOfClass:[NSString class]])
        payload = [[NSData alloc] initWithBase64EncodedString:ndef_b64
                                                     options:0];
    }
  }

  if (payload == nil) {
    nfc_send_reason(&pid, "error", "write_failed");
    return enif_make_atom(env, "ok");
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_session) {
      [g_session invalidateSession];
      g_session = nil;
    }
    if (g_tag_session) {
      [g_tag_session invalidateSession];
      g_tag_session = nil;
    }
    if (g_write_session) {
      [g_write_session invalidateSession];
      g_write_session = nil;
    }
    g_writer = [[MobNfcWriter alloc] init];
    g_writer.pid = pid;
    g_writer.payload = payload;
    g_write_session = [[NFCNDEFReaderSession alloc]
                initWithDelegate:g_writer
                           queue:dispatch_get_main_queue()
        invalidateAfterFirstRead:NO];
    g_write_session.alertMessage = alert;
    [g_write_session beginSession];
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_nfc_stop_reading(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_session) {
      [g_session invalidateSession];
      g_session = nil;
    }
    if (g_tag_session) {
      [g_tag_session invalidateSession];
      g_tag_session = nil;
    }
    if (g_write_session) {
      [g_write_session invalidateSession];
      g_write_session = nil;
    }
  });
  return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"nfc_available", 0, nif_nfc_available, 0},
    {"nfc_start_reading", 1, nif_nfc_start_reading, 0},
    {"nfc_start_writing", 1, nif_nfc_start_writing, 0},
    {"nfc_stop_reading", 0, nif_nfc_stop_reading, 0},
};

ERL_NIF_INIT(mob_nfc_nif, nif_funcs, NULL, NULL, NULL, NULL)
