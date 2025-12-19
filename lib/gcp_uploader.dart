import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis/storage/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

class GcpStorageUploader {
  GcpStorageUploader._();
  static final GcpStorageUploader instance = GcpStorageUploader._();

  static const String _bucketName = 'lithe-hallway-453615-q4';
  static const _scopes = [StorageApi.devstorageFullControlScope];

  Future<StorageApi>? _api;

  Future<StorageApi> _getApi() async {
    if (_api != null) return _api!;

    _api = () async {
      final jsonStr = await rootBundle.loadString('lib/gcp.json');
      final creds = ServiceAccountCredentials.fromJson(
        json.decode(jsonStr) as Map,
      );
      final client = await clientViaServiceAccount(creds, _scopes);
      return StorageApi(client);
    }();
    return _api!;
  }

  Future<String> uploadFile({
    required String filePath,
    String? objectName,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('El archivo no existe: $filePath');
    }

    final api = await _getApi();
    final contentType = lookupMimeType(filePath) ?? 'application/octet-stream';
    final media = Media(
      file.openRead(),
      await file.length(),
      contentType: contentType,
    );

    final name =
        objectName ??
        'uploads/${DateTime.now().millisecondsSinceEpoch}_${p.basename(filePath)}';

    final inserted = await api.objects.insert(
      Object()..name = name,
      _bucketName,
      uploadMedia: media,
    );

    final bucket = inserted.bucket ?? _bucketName;
    final objName = inserted.name ?? name;
    return 'https://storage.googleapis.com/$bucket/$objName';
  }
}
