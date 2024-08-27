import 'dart:async';
import 'dart:convert';

import 'package:ad_hoc_ident/ad_hoc_ident.dart';
import 'package:ad_hoc_ident_nfc/ad_hoc_ident_nfc.dart' as ident;
import 'package:flutter/services.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:uuid/uuid.dart';

/// Exception thrown when starting the NfcScanner while NFC is not available.
class NfcUnavailableException implements Exception {
  static const String _defaultMessage = 'NFC is not available.';

  /// The [message] of the exception.
  final String message;

  /// Creates a new [NfcUnavailableException] with the given [message].
  const NfcUnavailableException([this.message = _defaultMessage]);

  @override
  String toString() {
    return message;
  }
}

/// Tries to detect an [AdHocIdentity] from an [NfcTag].
class NfcKitNfcScanner implements ident.NfcScanner {
  final StreamController<AdHocIdentity?> _controller =
      StreamController.broadcast();
  final StreamController<bool> _idleController = StreamController.broadcast();

  bool _isRunning = false;
  Future<void> _process = Future.value();

  /// Whether the scanner is currently idling after a previous detection
  /// or not.
  ///
  /// This stream can be used to display to the user that the NfcScanner does
  /// currently not accept new tags.
  Stream<bool> get isIdle => _idleController.stream;

  final Duration _idleDuration;
  final bool _singleScan;

  @override
  AdHocIdentityDetector<ident.NfcTag> detector;

  @override
  AdHocIdentityEncrypter encrypter;

  /// Creates a [NfcKitNfcScanner] that scans a single tag when started.
  NfcKitNfcScanner.singleScan({
    required this.detector,
    required this.encrypter,
  })  : _singleScan = true,
        _idleDuration = Duration.zero;

  /// Creates a [NfcKitNfcScanner] that automatically polls for the next tag
  /// after it finished processing.
  ///
  /// Note that this might lead to a tag being discovered over and over in a
  /// short time, if no appropriate [idleDuration] is set. The scanner will
  /// wait for the [idleDuration] before restarting the tag poll mechanism.
  NfcKitNfcScanner.repeatPolling({
    required this.detector,
    required this.encrypter,
    required Duration idleDuration,
  })  : _idleDuration = idleDuration,
        _singleScan = false;

  @override
  void close() {
    stop();
    _controller.close();
  }

  @override
  Future<bool> isAvailable() async =>
      await FlutterNfcKit.nfcAvailability == NFCAvailability.available;

  @override
  Future<void> restart() async {
    try {
      await stop();
    } catch (_) {
      // ignore
    }
    await start();
  }

  @override
  Future<void> start() async {
    final available = await isAvailable();
    if (!available) {
      throw const NfcUnavailableException();
    }

    final wasRunning = _isRunning;
    _isRunning = true;
    if (!wasRunning) {
      try {
        await _process;
      } catch (_) {
        // ignore
      }
      _process = _pollForTag(); // start the loop, don't await the result
    }
  }

  Future<void> _pollForTag() async {
    try {
      final tag = await FlutterNfcKit.poll(timeout: const Duration(days: 1));
      final identTag = await _toIdentTag(tag);
      final identity = await detector.detect(identTag);
      if (identity == null) {
        return;
      }
      Future<void> finishFuture = _tryFinish();
      final encryptedIdentity = await encrypter.encrypt(identity);
      _controller.add(encryptedIdentity);
      await finishFuture;
    } on PlatformException catch (error, stackTrace) {
      if (error.code == '408') {
        // ignore code 408, which is the expected polling timeout expiration.
        // timeouts will have finished the nfc connection already.
        return;
      }

      await _onError(error, stackTrace);
    } catch (error, stackTrace) {
      await _onError(error, stackTrace);
    } finally {
      if (_isRunning && !_singleScan) {
        _idleController.add(true);
        await Future.delayed(_idleDuration);
        _idleController.add(false);
        if (_isRunning && !_singleScan) {
          _process = _pollForTag();
        }
      }
    }
  }

  Future<void> _onError(Object error, StackTrace? stackTrace) async {
    await _tryFinish();
    _controller.addError(error, stackTrace);
  }

  Future<void> _tryFinish() async {
    try {
      await FlutterNfcKit.finish();
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> stop() async {
    final wasRunning = _isRunning;
    _isRunning = false;
    if (wasRunning) {
      await _tryFinish();
    }
    await _process;
  }

  @override
  Stream<AdHocIdentity?> get stream => _controller.stream;

  Future<ident.NfcTag> _toIdentTag(NFCTag tag) async {
    const handle = Uuid();
    final tagIdentifierBytes =
        tag.type != NFCTagType.unknown ? utf8.encode(tag.id) : null;
    final identTag = _NfcKitNfcTag(
      handle: handle.toString(),
      identifier: tagIdentifierBytes,
      raw: tag,
      historicalBytes: tag.historicalBytes,
      hiLayerResponse: tag.hiLayerResponse,
    );

    return identTag;
  }
}

class _NfcKitNfcTag implements ident.NfcTag {
  final String? historicalBytes;
  final String? hiLayerResponse;

  @override
  final String handle;

  final Uint8List? _identifier;

  @override
  Future<Uint8List?> get identifier async => _identifier;

  @override
  final dynamic raw;

  _NfcKitNfcTag(
      {required this.handle,
      required Uint8List? identifier,
      required this.raw,
      this.historicalBytes,
      this.hiLayerResponse})
      : _identifier = identifier;

  @override
  Future<Uint8List?> getAt() async {
    return _fromRadixString(historicalBytes ?? // used in NfcA underlying tech
        hiLayerResponse); // used in NfcB underlying tech
  }

  Uint8List? _fromRadixString(String? str) {
    if (str == null) {
      return null;
    }
    final hexValues = str.split(r':');
    final intValues =
        hexValues.map((hex) => int.tryParse(hex, radix: 16)).nonNulls.toList();
    return intValues.length == hexValues.length
        ? Uint8List.fromList(intValues)
        : null; // return null if some values could not be parsed
  }

  @override
  Future<Uint8List?> transceive(Uint8List data) async {
    return await FlutterNfcKit.transceive(data);
  }
}
