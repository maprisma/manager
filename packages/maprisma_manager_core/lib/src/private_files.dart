/// Private files for F12's screenshots (Maprisma Playground's private_files.dart, the part the
/// screenshots need): libc gives what dart:io cannot say (0700 at creation, O_NOFOLLOW, O_EXCL,
/// files made relative to an opened folder). Linux only, as the Manager.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

final _libc = DynamicLibrary.open('libc.so.6');
final _malloc = _libc.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final _free = _libc.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
final _open = _libc
    .lookupFunction<Int32 Function(Pointer<Uint8>, Int32, Int32), int Function(Pointer<Uint8>, int, int)>('open');
final _openAt = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32), int Function(int, Pointer<Uint8>, int, int)>(
      'openat',
    );
final _unlinkAt = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>('unlinkat');
final _read = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('read');
final _write = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _fsync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
final _mkdir = _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Uint32), int Function(Pointer<Uint8>, int)>('mkdir');
final _getuid = _libc.lookupFunction<Uint32 Function(), int Function()>('getuid');
final _statx = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>)
    >('statx');
final _errnoLocation = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');
final _strerror = _libc.lookupFunction<Pointer<Uint8> Function(Int32), Pointer<Uint8> Function(int)>('strerror');

const _oWronly = 1, _oCreat = 0x40, _oExcl = 0x80, _oNonblock = 0x800;
const _oDirectory = 0x10000, _oNofollow = 0x20000, _oCloexec = 0x80000;

Pointer<Uint8> _allocate(int bytes) {
  final ptr = _malloc(bytes).cast<Uint8>();
  if (ptr.address == 0) throw StateError('Cannot allocate a file buffer.');
  return ptr;
}

Pointer<Uint8> _text(String text) {
  final bytes = utf8.encode(text);
  if (bytes.contains(0)) throw ArgumentError('Invalid file path.');
  final ptr = _allocate(bytes.length + 1);
  ptr.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return ptr;
}

/// The last libc error as an OSError (its own English text).
OSError _lastError() {
  final code = _errnoLocation().value;
  final text = _strerror(code);
  var length = 0;
  while (text[length] != 0) {
    length++;
  }
  return OSError(utf8.decode(text.asTypedList(length), allowMalformed: true), code);
}

int get fileOwnerUid => _getuid();

/// Owner, links, mode, inode and size (Linux statx: a stable layout on every architecture).
({int uid, int links, int mode, int inode, int size})? fileIdentity(String path, {int fd = -100}) {
  final name = _text(path), buffer = _allocate(256);
  try {
    // AT_EMPTY_PATH for a handle, AT_SYMLINK_NOFOLLOW always.
    if (_statx(fd, name, (path.isEmpty ? 0x1000 : 0) | 0x100, 0x7ff, buffer) != 0) return null;
    final b = buffer.asTypedList(256).buffer.asByteData();
    return (
      uid: b.getUint32(20, Endian.host),
      links: b.getUint32(16, Endian.host),
      mode: b.getUint16(28, Endian.host),
      inode: b.getUint64(32, Endian.host),
      size: b.getUint64(40, Endian.host),
    );
  } finally {
    _free(name.cast());
    _free(buffer.cast());
  }
}

/// A bounded read of a regular file, never through a final link (O_NOFOLLOW) and never blocking on
/// a FIFO put in its place (O_NONBLOCK); '' when it is missing, something else or too big.
String readRegularNoFollow(String path, {int maxBytes = 512 * 1024}) {
  if (maxBytes < 0) throw ArgumentError('Invalid file size limit.');
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return '';
    final name = _text(path);
    int fd;
    try {
      fd = _open(name, _oNofollow | _oNonblock | _oCloexec, 0);
    } finally {
      _free(name.cast());
    }
    if (fd < 0) return '';
    final buffer = _allocate(maxBytes + 1);
    try {
      final identity = fileIdentity('', fd: fd);
      if (identity == null || identity.mode & 0xf000 != 0x8000) return '';
      var total = 0;
      while (total <= maxBytes) {
        final count = _read(fd, buffer + total, maxBytes + 1 - total);
        if (count < 0) return '';
        if (count == 0) break;
        total += count;
      }
      return total > maxBytes ? '' : utf8.decode(buffer.asTypedList(total), allowMalformed: true);
    } finally {
      _close(fd);
      _free(buffer.cast());
    }
  } on Object {
    return '';
  }
}

/// A folder of this account's that only it can open (0700 from the start); its parents are made
/// as usual. An existing folder is left as it is; a link or a file in its place is refused.
void makePrivateFolder(String path) {
  final there = FileSystemEntity.typeSync(path, followLinks: false);
  if (there == FileSystemEntityType.directory) return;
  if (there != FileSystemEntityType.notFound) {
    throw FileSystemException('mkdir', path, const OSError('File exists', 17));
  }
  Directory(File(path).parent.path).createSync(recursive: true);
  final name = _text(path);
  try {
    if (_mkdir(name, 0x1c0) != 0) {
      final error = _lastError(); // before any other call can change errno
      // Made meanwhile by someone else: fine when it is a real folder.
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
        throw FileSystemException('mkdir', path, error);
      }
    }
  } finally {
    _free(name.cast());
  }
}

/// Tests only: a write of a new file fails after this many bytes (a full disk, an I/O error).
int? debugFailWriteAfter;

/// Tests only: every write call writes at most this many bytes (short writes).
int? debugShortWrite;

/// Tests only: write calls return 0 (nothing written, no error).
bool debugWriteReturnsZero = false;

/// A handle on a folder of this account's that only it may write to: made 0700 when missing; used
/// only when it is a real folder (opened with O_NOFOLLOW|O_DIRECTORY, so no link), owned by this
/// account and not writable by group or others (checked on the opened handle). Files are made
/// relative to that handle, so the folder cannot be swapped between the check and the write.
final class PrivateFolder {
  PrivateFolder._(this.path, this._fd);

  factory PrivateFolder.open(String path) {
    makePrivateFolder(path);
    final name = _text(path);
    int fd;
    try {
      fd = _open(name, _oDirectory | _oNofollow | _oCloexec, 0); // O_RDONLY
    } finally {
      _free(name.cast());
    }
    if (fd < 0) throw FileSystemException('open', path, _lastError());
    final info = fileIdentity('', fd: fd);
    if (info == null || info.mode & 0xf000 != 0x4000 || info.uid != fileOwnerUid || info.mode & 0x12 != 0) {
      _close(fd);
      throw FileSystemException('not a private folder of yours', path, const OSError('Permission denied', 13));
    }
    return PrivateFolder._(path, fd);
  }

  final String path;
  int _fd;

  static void _plain(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw ArgumentError.value(name, 'name', 'not a plain file name');
    }
  }

  /// Something of that name is in the folder (also a link that points nowhere).
  bool taken(String name) {
    _plain(name);
    return fileIdentity(name, fd: _fd) != null;
  }

  /// A new file of our own in the folder (0600, never through a link, never over an existing
  /// file), written completely and synced, or removed again.
  void writeNew(String name, List<int> bytes) {
    _plain(name);
    final where = '$path/$name';
    final cName = _text(name);
    try {
      final out = _openAt(_fd, cName, _oWronly | _oNofollow | _oCloexec | _oCreat | _oExcl, 0x180);
      if (out < 0) throw FileSystemException('open', where, _lastError());
      final buffer = _allocate(bytes.isEmpty ? 1 : bytes.length);
      var ok = false;
      try {
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final limit = debugFailWriteAfter;
          if (limit != null && offset >= limit) {
            throw FileSystemException('write', where, const OSError('No space left on device', 28));
          }
          var want = bytes.length - offset;
          if (limit != null) want = want.clamp(1, limit - offset);
          final short = debugShortWrite;
          if (short != null && short > 0 && want > short) want = short;
          final n = debugWriteReturnsZero ? 0 : _write(out, buffer + offset, want); // short: the loop goes on
          if (n < 0) throw FileSystemException('write', where, _lastError());
          if (n == 0) throw FileSystemException('write', where, const OSError('Nothing was written', 5));
          offset += n;
        }
        if (_fsync(out) != 0) throw FileSystemException('fsync', where, _lastError());
        ok = true;
      } finally {
        _free(buffer.cast());
        _close(out);
        if (!ok) _unlinkAt(_fd, cName, 0); // nothing half-written is left behind
      }
    } finally {
      _free(cName.cast());
    }
  }

  void close() {
    if (_fd >= 0) {
      _close(_fd);
      _fd = -1;
    }
  }
}
