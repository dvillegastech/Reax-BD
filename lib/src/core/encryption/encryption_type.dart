/// Encryption algorithms supported by ReaxDB.
///
/// The effective algorithm is always reported honestly by
/// `EncryptionEngine.getMetadata()`; ReaxDB never silently downgrades from a
/// requested algorithm to a weaker one. If a platform cannot run the requested
/// cipher, engine construction throws an `EncryptionException` instead.
enum EncryptionType {
  /// No encryption. Values are stored as plaintext.
  none,

  /// Repeating-key XOR obfuscation.
  ///
  /// **This is NOT encryption and provides NO confidentiality against any
  /// motivated attacker.** It only prevents values from being casually
  /// readable in a hex dump. It is trivially broken with known plaintext or
  /// frequency analysis and has no integrity protection. Use
  /// [EncryptionType.aes256] for any data that actually needs protection.
  obfuscation,

  /// AES-256-GCM authenticated encryption.
  ///
  /// Industry-standard confidentiality and integrity. Every value is
  /// encrypted with a fresh random 96-bit IV and carries a 128-bit
  /// authentication tag; tampering is detected on decrypt.
  aes256;

  /// Compatibility alias for the ReaxDB 1.x name of [obfuscation].
  ///
  /// The value is identical, only the name changed: XOR was never encryption
  /// and the 1.x name suggested otherwise. Note that a `switch` over
  /// [EncryptionType] must match [obfuscation]; `case EncryptionType.xor`
  /// is not a valid pattern because this is a constant, not an enum value.
  @Deprecated('Renamed to EncryptionType.obfuscation. Removed in 3.0.')
  static const EncryptionType xor = EncryptionType.obfuscation;
}

/// Human-readable descriptions of each [EncryptionType].
extension EncryptionTypeExtension on EncryptionType {
  /// Human-readable name.
  String get displayName {
    switch (this) {
      case EncryptionType.none:
        return 'No Encryption';
      case EncryptionType.obfuscation:
        return 'XOR Obfuscation (NOT encryption)';
      case EncryptionType.aes256:
        return 'AES-256-GCM';
    }
  }

  /// Honest security level description.
  String get securityLevel {
    switch (this) {
      case EncryptionType.none:
        return 'None - plaintext';
      case EncryptionType.obfuscation:
        return 'None - obfuscation only, trivially reversible, no integrity';
      case EncryptionType.aes256:
        return 'High - authenticated encryption (AES-256-GCM)';
    }
  }

  /// Rough performance impact description.
  String get performanceImpact {
    switch (this) {
      case EncryptionType.none:
        return 'No impact';
      case EncryptionType.obfuscation:
        return 'Minimal';
      case EncryptionType.aes256:
        return 'Moderate';
    }
  }

  /// Whether this type requires key material.
  bool get requiresKey {
    switch (this) {
      case EncryptionType.none:
        return false;
      case EncryptionType.obfuscation:
      case EncryptionType.aes256:
        return true;
    }
  }
}
