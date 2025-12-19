import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

MqttClient createPlatformClient(String host, String clientId) {
  final client = MqttServerClient(host, clientId)
    ..port = 8883
    ..secure = true;
  return client;
}
