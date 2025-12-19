import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

import 'mqtt_client_factory.dart';
import 'gcp_uploader.dart';

void main() {
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

  late final MqttClient _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _subscription;
  final _topicController = TextEditingController(text: 'iot/demo');
  final _messages = <String>[];
  String _status = 'Desconectado';
  bool _connecting = false;
  bool _uploading = false;
  String? _pickedImagePath;
  String? _recordingPath;
  String? _imageUrl;
  String? _audioUrl;
  bool _isRecording = false;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
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
    final picker = ImagePicker();
    final result = await picker.pickImage(source: ImageSource.camera);
    if (result != null) {
      setState(() {
        _pickedImagePath = result.path;
      });
    }
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
      appBar: AppBar(title: const Text('HiveMQ MQTT')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Estado: $_status',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
                    onPressed: _connecting ? null : _connectAndSubscribe,
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Tomar foto'),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _uploading ? null : _sendImage,
                  icon: const Icon(Icons.send),
                  label: const Text('Enviar foto'),
                ),
              ],
            ),
            if (_pickedImagePath != null) ...[
              const SizedBox(height: 8),
              Text(
                'Foto seleccionada: $_pickedImagePath',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: kIsWeb
                    ? Image.network(
                        _pickedImagePath!,
                        height: 180,
                        fit: BoxFit.cover,
                      )
                    : Image.file(
                        io.File(_pickedImagePath!),
                        height: 180,
                        fit: BoxFit.cover,
                      ),
              ),
            ],
            if (_imageUrl != null) ...[
              const SizedBox(height: 4),
              Text(
                'URL foto: $_imageUrl',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startOrStopRecording,
                    icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                    label: Text(_isRecording ? 'Detener' : 'Grabar audio'),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _uploading ? null : _sendAudio,
                  icon: const Icon(Icons.send),
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
                  const SizedBox(width: 8),
                  if (_isRecording)
                    const Text(
                      'Grabando...',
                      style: TextStyle(color: Colors.red),
                    ),
                ],
              ),
            ],
            if (_audioUrl != null) ...[
              const SizedBox(height: 4),
              Text(
                'URL audio: $_audioUrl',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _messages.isEmpty
                    ? const Center(child: Text('Sin mensajes aún'))
                    : ListView.builder(
                        reverse: false,
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
          ],
        ),
      ),
    );
  }
}
