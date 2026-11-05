import 'dart:typed_data';

/// Writes [value], 0 or more, as the varint of `battle_protocol`'s binary
/// format: seven bits a byte, lowest first.
void writeCount(BytesBuilder bytes, int value) {
  var rest = value;
  while (rest >= 0x80) {
    bytes.addByte(rest % 0x80 + 0x80);
    rest ~/= 0x80;
  }
  bytes.addByte(rest);
}

/// The varint of [bytes] at [offset], and the offset after it; null when
/// [bytes] end before it does.
(int, int)? readCount(Uint8List bytes, int offset) {
  var value = 0;
  var scale = 1;
  for (var at = offset; at < bytes.length; at++) {
    final byte = bytes[at];
    value += (byte % 0x80) * scale;
    if (byte < 0x80) return (value, at + 1);
    scale *= 0x80;
  }
  return null;
}

/// Whether [bytes] hold [prefix] at [offset].
bool startsWith(Uint8List bytes, List<int> prefix, [int offset = 0]) {
  if (bytes.length < offset + prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[offset + i] != prefix[i]) return false;
  }
  return true;
}

/// Throws an [ArgumentError] unless [battleId] can name a file: letters,
/// digits, `.`, `-` and `_`, starting with a letter or a digit, at most
/// [maxLength] characters.
void checkFileName(String battleId, {int maxLength = 255}) {
  if (battleId.length > maxLength ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(battleId)) {
    throw ArgumentError.value(battleId, 'battleId', 'cannot name a file');
  }
}
