import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

MqttClient createPlatformClient(String host, String clientId) {
  // Websocket seguro en HiveMQ Cloud (puerto 8884) con path /mqtt.
  final client = MqttBrowserClient('wss://$host:8884/mqtt', clientId)
    ..setProtocolV311()
    ..port = 8884;
  return client;
}
