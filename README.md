# Flutter Multiplatform – MQTT + Carga a GCP

App Flutter (web/móvil) que:
- Se conecta a HiveMQ Cloud vía MQTT.
- Captura foto (cámara) y audio (micrófono), los sube a Google Cloud Storage usando un service account (lib/gcp.json) y muestra las URLs.
- En móvil permite previsualizar la foto y reproducir el audio grabado.

## Requisitos
- Flutter 3.10+ y SDK de Android/iOS configurados.
- Acceso a internet.
- Archivo `lib/gcp.json` con credenciales de service account (ya incluido). **Nota**: Exponer llaves en el cliente no es seguro para producción; se recomienda backend o Signed URLs.

## Dependencias clave
- mqtt_client
- image_picker, record, audioplayers
- googleapis, googleapis_auth, mime, path

## Configuración HiveMQ
En `lib/main.dart` define:
```dart
static const _host = '<tu-host>.s1.eu.hivemq.cloud';
static const _username = '<usuario>';
static const _password = '<clave>';
static const _clientId = 'flutter-client';
```
- Web usa WebSocket seguro (wss://host:8884/mqtt) en `mqtt_client_factory_web.dart`.
- Móvil/escritorio usa TLS por puerto 8883 en `mqtt_client_factory_io.dart`. Si tu instancia requiere certificado propio o WS, ajusta aquí.

## Permisos (Android)
`android/app/src/main/AndroidManifest.xml` incluye:
- INTERNET
- CAMERA
- RECORD_AUDIO

## Ejecutar
```bash
flutter pub get
flutter run -d chrome        # web
flutter run -d android       # dispositivo/emulador Android
```

## Flujo en la app
1) Conectar y suscribir a un tópico MQTT.
2) Tomar foto → se muestra preview → “Enviar foto” sube a GCP y muestra la URL.
3) Grabar audio → “Reproducir” para escucharlo → “Enviar audio” lo sube a GCP y muestra la URL.

## Build APK
```bash
flutter build apk
```

## Notas de seguridad
- No uses el JSON de service account en producción. Implementa backend que genere Signed URLs o reciba el archivo y lo suba al bucket.
