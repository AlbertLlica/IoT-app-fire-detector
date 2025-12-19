import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

import 'mqtt_client_factory.dart';
import 'gcp_uploader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HiveMQ Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const MqttPage(),
    );
  }
}

class MqttPage extends StatefulWidget {
  const MqttPage({super.key});

  @override
  State<MqttPage> createState() => _MqttPageState();
}

class _MqttPageState extends State<MqttPage> {
  static const _host = 'c7bdc5a9cfe14052b0590a8a5952d7eb.s1.eu.hivemq.cloud';
  static const _username = 'levi123';
  static const _password = 'Levi_123';
  static const _clientId = 'flutter-client';
  static const _autoAudioSeconds = 3;
  static const _cooldownSeconds = 60;

  late final MqttClient _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _subscription;
  final _topicController = TextEditingController(text: 'iot/demo');
  final _messages = <String>[];
  String _status = 'Desconectado';
  bool _connecting = false;
  bool _uploading = false;
  bool _autoProcessing = false;
  bool _cooldownActive = false;
  String? _pickedImagePath;
  String? _recordingPath;
  String? _latestAutoImagePath;
  String? _imageUrl;
  String? _audioUrl;
  bool _isRecording = false;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  Timer? _cooldownTimer;
  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _cameraInitFuture = _initCamera();
    _client = createMqttClient(_host, _clientId)
      ..logging(on: false)
      ..keepAlivePeriod = 20
      ..onDisconnected = _onDisconnected
      ..onConnected = _onConnected
      ..onSubscribed = _onSubscribed
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier(_clientId)
          .authenticateAs(_username, _password)
          .keepAliveFor(20)
          .startClean();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _client.disconnect();
    _topicController.dispose();
    _recorder.dispose();
    _player.dispose();
    _cooldownTimer?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _connectAndSubscribe() async {
    final topic = _topicController.text.trim();
    if (topic.isEmpty) return;

    setState(() {
      _connecting = true;
      _status = 'Conectando...';
    });

    try {
      final res = await _client.connect(_username, _password);
      if (res?.state != MqttConnectionState.connected) {
        throw Exception('Estado: ${res?.state}');
      }

      _subscription?.cancel();
      _subscription = _client.updates?.listen(_onMessage);
      _client.subscribe(topic, MqttQos.atMostOnce);

      setState(() {
        _status = 'Conectado y suscrito a $topic';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
      _client.disconnect();
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No se encontró cámara');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _cameraError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Error al iniciar cámara: $e');
    }
  }

  Future<void> _autoCaptureAndUpload() async {
    if (_cooldownActive || _autoProcessing || _isRecording) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    setState(() => _autoProcessing = true);

    try {
      final image = await _cameraController!.takePicture();
      setState(() => _latestAutoImagePath = image.path);

      final dir = await getTemporaryDirectory();
      final audioPath =
          '${dir.path}/auto_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: audioPath,
      );
      setState(() {
        _isRecording = true;
        _recordingPath = audioPath;
      });
      await Future.delayed(const Duration(seconds: _autoAudioSeconds));
      await _recorder.stop();
      setState(() => _isRecording = false);

      setState(() => _uploading = true);
      final photoUrl = await GcpStorageUploader.instance.uploadFile(
        filePath: image.path,
      );
      setState(() => _imageUrl = photoUrl);

      final audioUrl = await GcpStorageUploader.instance.uploadFile(
        filePath: audioPath,
      );
      setState(() => _audioUrl = audioUrl);

      final fileName = p.basename(image.path);
      await _publishPhotoMessage(fileName);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto envío completado. Foto y audio subidos.'),
          ),
        );
      }

      _startCooldown();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error en auto captura: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _autoProcessing = false;
        });
      }
    }
  }

  void _startCooldown() {
    if (_cooldownActive) return;
    setState(() => _cooldownActive = true);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(const Duration(seconds: _cooldownSeconds), () {
      if (!mounted) return;
      setState(() => _cooldownActive = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cooldown finalizado, escuchando de nuevo'),
        ),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('En cooldown 1 minuto antes de la próxima auto captura'),
      ),
    );
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> event) {
    for (final message in event) {
      final payload = message.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );
      setState(() {
        _messages.insert(0, '[${message.topic}] ${text.trim()}');
      });
    }

    if (!_cooldownActive && !_autoProcessing && !_isRecording) {
      unawaited(_autoCaptureAndUpload());
    }
  }

  void _onConnected() {
    setState(() {
      _status = 'Conectado';
    });
  }

  void _onDisconnected() {
    setState(() {
      _status = 'Desconectado';
    });
  }

  void _onSubscribed(String topic) {
    setState(() {
      _status = 'Suscrito a $topic';
    });
  }

  Future<void> _disconnect() async {
    await _subscription?.cancel();
    _client.disconnect();
    setState(() {
      _status = 'Desconectado';
      _messages.clear();
    });
  }

  Future<void> _pickImage() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cámara no lista')));
      return;
    }
    final shot = await _cameraController!.takePicture();
    setState(() {
      _pickedImagePath = shot.path;
      _latestAutoImagePath = shot.path;
    });
  }

  Future<void> _startOrStopRecording() async {
    if (_isRecording) {
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _recordingPath = path;
      });
      return;
    }

    if (await _recorder.hasPermission()) {
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: filePath,
      );
      setState(() {
        _isRecording = true;
        _recordingPath = filePath;
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permiso de micrófono denegado')),
        );
      }
    }
  }

  Future<void> _playRecordedAudio() async {
    if (_recordingPath == null) return;
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(_recordingPath!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo reproducir el audio: $e')),
        );
      }
    }
  }

  Future<void> _sendImage() async {
    if (_pickedImagePath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Primero toma una foto')));
      return;
    }
    setState(() => _uploading = true);
    try {
      final url = await GcpStorageUploader.instance.uploadFile(
        filePath: _pickedImagePath!,
      );
      setState(() => _imageUrl = url);
      final fileName = p.basename(_pickedImagePath!);
      await _publishPhotoMessage(fileName);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Foto subida a GCP: $url')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al subir foto: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _publishPhotoMessage(String fileName) async {
    final status = _client.connectionStatus?.state;
    if (status != MqttConnectionState.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Conéctate a HiveMQ antes de publicar la foto'),
          ),
        );
      }
      return;
    }

    final builder = MqttClientPayloadBuilder()
      ..addString(jsonEncode({'photo': fileName}));
    _client.publishMessage('pic', MqttQos.atLeastOnce, builder.payload!);
    setState(() {
      _messages.insert(0, '[pic] {"photo":"$fileName"}');
    });
  }

  Future<void> _sendAudio() async {
    if (_recordingPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Graba un audio antes de enviar')),
      );
      return;
    }
    setState(() => _uploading = true);
    try {
      final url = await GcpStorageUploader.instance.uploadFile(
        filePath: _recordingPath!,
      );
      setState(() => _audioUrl = url);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Audio subido a GCP: $url')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al subir audio: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HiveMQ MQTT'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Estado: $_status',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _topicController,
                        decoration: const InputDecoration(
                          labelText: 'Tópico',
                          border: OutlineInputBorder(),
                          hintText: 'ej. sensores/temperatura',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _connecting
                                  ? null
                                  : _connectAndSubscribe,
                              icon: const Icon(Icons.cloud_sync),
                              label: const Text('Conectar y suscribir'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _disconnect,
                            icon: const Icon(Icons.link_off),
                            label: const Text('Desconectar'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Cámara en vivo',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          if (_cooldownActive)
                            Chip(
                              label: const Text('Cooldown'),
                              backgroundColor: Colors.orange.shade100,
                              labelStyle: const TextStyle(
                                color: Colors.deepOrange,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 220,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _cameraError != null
                              ? Container(
                                  color: Colors.red.shade50,
                                  alignment: Alignment.center,
                                  child: Text(
                                    _cameraError!,
                                    style: TextStyle(
                                      color: Colors.red.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : FutureBuilder<void>(
                                  future: _cameraInitFuture,
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState ==
                                        ConnectionState.waiting) {
                                      return const Center(
                                        child: CircularProgressIndicator(),
                                      );
                                    }
                                    if (_cameraController == null ||
                                        !_cameraController!
                                            .value
                                            .isInitialized) {
                                      return const Center(
                                        child: Text('Cámara no disponible'),
                                      );
                                    }
                                    return CameraPreview(_cameraController!);
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _uploading ? null : _pickImage,
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Tomar foto'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _uploading ? null : _sendImage,
                            icon: const Icon(Icons.cloud_upload),
                            label: const Text('Enviar foto'),
                          ),
                        ],
                      ),
                      if (_pickedImagePath != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Última foto manual: $_pickedImagePath',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            io.File(_pickedImagePath!),
                            height: 160,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ],
                      if (_latestAutoImagePath != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Última captura automática:',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            io.File(_latestAutoImagePath!),
                            height: 160,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _latestAutoImagePath!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (_imageUrl != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'URL foto: $_imageUrl',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audio',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _startOrStopRecording,
                              icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                              label: Text(
                                _isRecording ? 'Detener' : 'Grabar audio',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _uploading ? null : _sendAudio,
                            icon: const Icon(Icons.cloud_upload),
                            label: const Text('Enviar audio'),
                          ),
                        ],
                      ),
                      if (_recordingPath != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Audio listo: $_recordingPath',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            ElevatedButton.icon(
                              onPressed: _playRecordedAudio,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Reproducir'),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _isRecording
                                  ? 'Grabando...'
                                  : 'Listo para enviar',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                      if (_audioUrl != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'URL audio: $_audioUrl',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  height: 280,
                  child: _messages.isEmpty
                      ? const Center(child: Text('Sin mensajes aún'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.message_outlined),
                              title: Text(
                                msg,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
