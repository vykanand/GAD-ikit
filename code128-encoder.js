(function (root, factory) {
  const encoder = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = encoder;
  if (root) root.GadCode128Encoder = encoder;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  const patterns = [
    '11011001100', '11001101100', '11001100110', '10010011000', '10010001100',
    '10001001100', '10011001000', '10011000100', '10001100100', '11001001000',
    '11001000100', '11000100100', '10110011100', '10011011100', '10011001110',
    '10111001100', '10011101100', '10011100110', '11001110010', '11001011100',
    '11001001110', '11011100100', '11001110100', '11101101110', '11101001100',
    '11100101100', '11100100110', '11101100100', '11100110100', '11100110010',
    '11011011000', '11011000110', '11000110110', '10100011000', '10001011000',
    '10001000110', '10110001000', '10001101000', '10001100010', '11010001000',
    '11000101000', '11000100010', '10110111000', '10110001110', '10001101110',
    '10111011000', '10111000110', '10001110110', '11101110110', '11010001110',
    '11000101110', '11011101000', '11011100010', '11011101110', '11101011000',
    '11101000110', '11100010110', '11101101000', '11101100010', '11100011010',
    '11101111010', '11001000010', '11110001010', '10100110000', '10100001100',
    '10010110000', '10010000110', '10000101100', '10000100110', '10110010000',
    '10110000100', '10011010000', '10011000010', '10000110100', '10000110010',
    '11000010010', '11001010000', '11110111010', '11000010100', '10001111010',
    '10100111100', '10010111100', '10010011110', '10111100100', '10011110100',
    '10011110010', '11110100100', '11110010100', '11110010010', '11011011110',
    '11011110110', '11110110110', '10101111000', '10100011110', '10001011110',
    '10111101000', '10111100010', '11110101000', '11110100010', '10111011110',
    '10111101110', '11101011110', '11110101110', '11010000100', '11010010000',
    '11010011100', '1100011101011',
  ];

  function isValidPayload(value) {
    if (!/^\d{13}$/.test(value)) return false;
    let sum = 0;
    let multiplyByThree = true;
    for (let index = 11; index >= 0; index -= 1) {
      let digit = Number(value[index]);
      if (multiplyByThree) digit *= 3;
      sum += digit;
      multiplyByThree = !multiplyByThree;
    }
    return (10 - (sum % 10)) % 10 === Number(value[12]);
  }

  function encode(value) {
    if (!isValidPayload(value)) {
      throw new Error('Barcode value must be a valid 13-digit numeric code.');
    }

    const codewords = [104, Number(value[0]) + 16, 99];
    for (let index = 1; index < value.length; index += 2) {
      codewords.push(Number(value.slice(index, index + 2)));
    }

    const checksum = codewords.reduce(
      (sum, codeword, index) => sum + codeword * (index === 0 ? 1 : index),
      0,
    ) % 103;
    const encoded = [...codewords, checksum, 106]
      .map((codeword) => patterns[codeword])
      .join('');
    if (encoded.length !== 123 || /[^01]/.test(encoded)) {
      throw new Error('Code 128 encoder produced an invalid pattern.');
    }
    return encoded;
  }

  return { encode, isValidPayload };
});
