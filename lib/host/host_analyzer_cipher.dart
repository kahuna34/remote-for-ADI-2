import 'dart:typed_data';

/// RFC 8439 ChaCha20. Used only inside the existing encrypt-then-HMAC envelope;
/// never use this unauthenticated primitive on its own. Each session/direction
/// has a derived key and every message sequence provides a unique nonce.
Uint8List hostAnalyzerCipher(List<int> input, List<int> key, List<int> nonce) {
  if (key.length != 32 || nonce.length != 12) {
    throw ArgumentError('ChaCha20 key/nonce');
  }
  final k = ByteData.sublistView(Uint8List.fromList(key));
  final n = ByteData.sublistView(Uint8List.fromList(nonce));
  final output = Uint8List(input.length);
  int rotate(int x, int bits) =>
      ((x << bits) | (x >> (32 - bits))) & 0xffffffff;
  for (
    var offset = 0, counter = 1;
    offset < input.length;
    offset += 64, counter++
  ) {
    final state = <int>[
      0x61707865,
      0x3320646e,
      0x79622d32,
      0x6b206574,
      for (var i = 0; i < 8; i++) k.getUint32(i * 4, Endian.little),
      counter,
      for (var i = 0; i < 3; i++) n.getUint32(i * 4, Endian.little),
    ];
    final x = List<int>.of(state);
    void quarter(int a, int b, int c, int d) {
      x[a] = (x[a] + x[b]) & 0xffffffff;
      x[d] = rotate(x[d] ^ x[a], 16);
      x[c] = (x[c] + x[d]) & 0xffffffff;
      x[b] = rotate(x[b] ^ x[c], 12);
      x[a] = (x[a] + x[b]) & 0xffffffff;
      x[d] = rotate(x[d] ^ x[a], 8);
      x[c] = (x[c] + x[d]) & 0xffffffff;
      x[b] = rotate(x[b] ^ x[c], 7);
    }

    for (var round = 0; round < 10; round++) {
      quarter(0, 4, 8, 12);
      quarter(1, 5, 9, 13);
      quarter(2, 6, 10, 14);
      quarter(3, 7, 11, 15);
      quarter(0, 5, 10, 15);
      quarter(1, 6, 11, 12);
      quarter(2, 7, 8, 13);
      quarter(3, 4, 9, 14);
    }
    final block = ByteData(64);
    for (var i = 0; i < 16; i++) {
      block.setUint32(i * 4, (x[i] + state[i]) & 0xffffffff, Endian.little);
    }
    for (var i = 0; i < 64 && offset + i < input.length; i++) {
      output[offset + i] = input[offset + i] ^ block.getUint8(i);
    }
  }
  return output;
}
