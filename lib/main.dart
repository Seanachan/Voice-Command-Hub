import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart'
    as serial;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

// --- THEME COLORS ---
const Color kBgColor = Color(0xFF0D1117);
const Color kCardColor = Color(0xFF161B22);
const Color kBorderColor = Color(0xFF30363D);
const Color kAccentBlue = Color(0xFF2F81F7);
const Color kAccentGreen = Color(0xFF238636);
const Color kTextWhite = Color(0xFFF0F6FC);
const Color kTextGray = Color(0xFF8B949E);
const Color kCodeBg = Color(0xFF0A0C10);
const Color kErrorRed = Color(0xFFDA3633); // Added for Error UI

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const VoiceHubApp());
}

// 1. ROOT WIDGET
class VoiceHubApp extends StatelessWidget {
  const VoiceHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBgColor,
        cardColor: kCardColor,
        dialogBackgroundColor: kCardColor, // Ensure dialogs match theme
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: kTextWhite),
          bodySmall: TextStyle(color: kTextGray),
        ),
      ),
      home: const VoiceHubScreen(),
    );
  }
}

// 2. SCREEN WIDGET
class VoiceHubScreen extends StatefulWidget {
  const VoiceHubScreen({super.key});

  @override
  State<VoiceHubScreen> createState() => _VoiceHubScreenState();
}

class _VoiceHubScreenState extends State<VoiceHubScreen> {
  // --- STATE VARIABLES ---
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _lastWords = "Press mic to speak";
  bool _isConnectingHC05 = false;
  bool _isConnectingBLE = false;

  // BLE (Light Stick)
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _bleCharLed;
  bool _bleConnected = false;
  final String _ikeName = "I-KE-V3";
  final String _ledCharUuid = "8EC91004-F315-4F60-9FB8-838830DAEA50";

  // Classic Bluetooth (HC-05)
  serial.BluetoothConnection? _hc05Connection;
  bool _hc05Connected = false;

  // Sync Logic
  List<Timer> _activeTimers = [];
  final int _beatOffset = 120;

  List<Map<String, String>> historyLogs = [];

  final List<Map<String, dynamic>> _beatCues = [
    {'time': 827, 'r': 255, 'g': 0, 'b': 0, 'mode': 0x20, 'speed': 0},
    {'time': 1675, 'r': 255, 'g': 140, 'b': 58, 'mode': 0x20, 'speed': 0},
    {'time': 2523, 'r': 255, 'g': 255, 'b': 0, 'mode': 0x20, 'speed': 0},
    {'time': 2951, 'r': 0, 'g': 255, 'b': 0, 'mode': 0x20, 'speed': 0},
    {'time': 3378, 'r': 0, 'g': 255, 'b': 255, 'mode': 0x20, 'speed': 0},
    {'time': 4226, 'r': 0, 'g': 0, 'b': 255, 'mode': 0x20, 'speed': 0},
    {'time': 4226, 'r': 75, 'g': 0, 'b': 130, 'mode': 0x11, 'speed': 2},
    {'time': 12846, 'r': 138, 'g': 43, 'b': 226, 'mode': 0x21, 'speed': 1},
    {'time': 16287, 'r': 199, 'g': 21, 'b': 133, 'mode': 0x21, 'speed': 1},
    {'time': 17136, 'r': 255, 'g': 20, 'b': 147, 'mode': 0x11, 'speed': 2},
    {'time': 17987, 'r': 255, 'g': 69, 'b': 0, 'mode': 0x11, 'speed': 2},
    {'time': 19266, 'r': 255, 'g': 140, 'b': 58, 'mode': 0x11, 'speed': 2},
  ];
  @override
  void dispose() {
    // Gracefully disconnect HC-05
    if (_hc05Connection != null && _hc05Connection!.isConnected) {
      _hc05Connection!.dispose();
    }

    // Cancel any running music timers
    for (Timer t in _activeTimers) {
      t.cancel();
    }

    // Clean up BLE
    if (_bleDevice != null) {
      _bleDevice!.disconnect();
    }

    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.microphone,
    ].request();
  }

  // --- NEW: ROBUST ERROR UI ---
  void _showErrorDialog(String title, dynamic error) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: kErrorRed),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: kErrorRed)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Full Error Details:",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: kCodeBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: kBorderColor),
                ),
                child: Text(
                  error.toString(),
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 12,
                    color: kTextGray,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  void _log(String cmd) {
    final now = DateTime.now();
    final timeStr =
        "${now.hour > 12 ? now.hour - 12 : now.hour}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";

    setState(() {
      historyLogs.insert(0, {'cmd': cmd, 'time': timeStr, 'status': 'Sent'});
    });
    print(cmd);
  }

  Future<void> _startMusicSync() async {
    _stopMusicSync();

    await Future.delayed(const Duration(milliseconds: 500));

    _log("PLAY_MUSIC (Sync Started)");

    // 4. Now send the Play command (using await if you updated the helper)
    await _sendToHC05("PLAY_MUSIC");

    int maxTime = 0;

    for (var cue in _beatCues) {
      int cueTime = cue['time'] as int;
      if (cueTime > maxTime) maxTime = cueTime;

      int triggerTime = cueTime + _beatOffset;
      Timer t = Timer(Duration(milliseconds: triggerTime), () {
        _sendPacket(
          cue['mode'],
          cue['r'],
          cue['g'],
          cue['b'],
          cue['speed'] == 0 ? 255 : cue['speed'],
        );
      });
      _activeTimers.add(t);
    }

    // Finish Timer
    int finishTime = maxTime + _beatOffset + 2000;
    Timer finishTimer = Timer(Duration(milliseconds: finishTime), () {
      _sendPacket(0x20, 0, 255, 0, 255); // Green Static
      _log("Music Finished -> Static Green");
    });
    _activeTimers.add(finishTimer);
  }

  void _stopMusicSync() {
    for (Timer t in _activeTimers) {
      t.cancel();
    }
    _activeTimers.clear();
    _sendToHC05("STOP_MUSIC");
    _sendPacket(0x20, 0, 0, 0, 0);
    _log("STOP_MUSIC");
  }

  Future<String> _classifyCommandWithLLM(String userSpeech) async {
    const String url =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent";
    final String? apiKey = dotenv.env['Default_Gemini_API_Key'];

    if (apiKey == null || apiKey.isEmpty) return "ERROR";

    String systemPrompt = """
    You are a robot controller. Map the user's speech to one of these EXACT commands:
    [MOVEMENT]: FORWARD, REVERSE, PARK, GOGO
    [STEERING]: TURN_LEFT, TURN_RIGHT, STRAIGHT
    [GEARS]: HIGH, LOW
    [LIGHTS]: RED, BLUE, GREEN
    [MUSIC]: PLAY_MUSIC, STOP_MUSIC, VOL_UP, VOL_DOWN

    Rules: Return ONLY the command word. If unknown, return UNKNOWN. If asked about what love is, return WHAT_IS_LOVE.
    """;

    try {
      var response = await http.post(
        Uri.parse("$url?key=$apiKey"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {
                  "text":
                      "$systemPrompt\n\nUser Speech: \"$userSpeech\"\nCommand:",
                },
              ],
            },
          ],
        }),
      );

      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        if (data['candidates'] != null && data['candidates'].isNotEmpty) {
          return data['candidates'][0]['content']['parts'][0]['text']
              .trim()
              .toUpperCase();
        }
      }
      return "UNKNOWN";
    } catch (e) {
      return "ERROR";
    }
  }

  String _fallbackSimpleLogic(String text) {
    String t = text.toLowerCase();
    if (t.contains("forward")) return "FORWARD";
    if (t.contains("back")) return "REVERSE";
    if (t.contains("park") || t.contains("stop")) return "PARK";
    if (t.contains("go")) return "GOGO";
    if (t.contains("left")) return "TURN_LEFT";
    if (t.contains("right")) return "TURN_RIGHT";
    if (t.contains("straight")) return "STRAIGHT";
    if (t.contains("high")) return "HIGH_SPEED";
    if (t.contains("low")) return "LOW_SPEED";
    if (t.contains("red")) return "RED";
    if (t.contains("blue")) return "BLUE";
    if (t.contains("green")) return "GREEN";
    if (t.contains("play")) return "PLAY_MUSIC";
    if (t.contains("quiet")) return "STOP_MUSIC";
    if (t.contains("up")) return "VOL_UP";
    if (t.contains("down")) return "VOL_DOWN";
    if (t.contains("honk")) return "HONK";
    return "UNKNOWN";
  }

  Future<void> _processCommand(String text) async {
    print("Processing: $text");
    String command = await _classifyCommandWithLLM(text);

    if (command == "ERROR" || command == "UNKNOWN") {
      command = _fallbackSimpleLogic(text);
    }

    if (command != "PLAY_MUSIC" && command != "STOP_MUSIC") {
      _log(command);
    }

    switch (command) {
      case "GOGO":
        _sendToHC05("GO");
        break;
      case "FORWARD":
        _sendToHC05("FO");
        break;
      case "REVERSE":
        _sendToHC05("RE");
        break;
      case "PARK":
        _sendToHC05("PA");
        break;
      case "TURN_LEFT":
        _sendToHC05("LE");
        break;
      case "TURN_RIGHT":
        _sendToHC05("RI");
        break;
      case "HIGH":
        _sendToHC05("HI");
        break;
      case "LOW":
        _sendToHC05("LO");
        break;
      case "RED":
        _sendToHC05("RED");
        _sendPacket(0x20, 255, 0, 0, 255);
        break;
      case "BLUE":
        _sendPacket(0x20, 0, 0, 255, 255);
        break;
      case "GREEN":
        _sendPacket(0x20, 0, 255, 0, 255);
        break;
      case "PLAY_MUSIC":
        _startMusicSync();
        break;
      case "WHAT_IS_LOVE":
        _sendToHC05("WH");
        break;
      case "STOP_MUSIC":
        _stopMusicSync();
        break;
      case "VOL_UP":
        _sendToHC05("UP");
        break;
      case "VOL_DOWN":
        _sendToHC05("DO");
        break;
    }
  }

  // --- CONNECTIVITY HELPERS ---
  Future<void> _connectHC05() async {
    // 1. GUARD CLAUSE: If already connected or busy, DO NOTHING.
    if (_hc05Connected || _isConnectingHC05) {
      return;
    }

    // 2. Lock the function immediately
    setState(() => _isConnectingHC05 = true);

    List<serial.BluetoothDevice> devices = [];
    try {
      devices = await serial.FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      // If Bluetooth is off, this often throws.
      _showErrorDialog("Bluetooth Scan Error", e);
      return;
    }

    if (!mounted) return;

    serial.BluetoothDevice? selected = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardColor,
        title: const Text("Select HC-05", style: TextStyle(color: kTextWhite)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: devices
                .map(
                  (d) => ListTile(
                    title: Text(
                      d.name ?? d.address,
                      style: const TextStyle(color: kTextWhite),
                    ),
                    onTap: () => Navigator.pop(context, d),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );

    if (selected != null) {
      // NOTE: We do NOT set _isConnectingHC05 = true here,
      // because we already set it to true at the very top of the function.

      // 1. Cleanup: If there was a previous lingering connection, kill it now.
      if (_hc05Connection != null) {
        try {
          _hc05Connection!.dispose();
        } catch (e) {
          // Ignore errors during cleanup
        }
      }

      try {
        // 2. Attempt the Connection
        serial.BluetoothConnection connection =
            await serial.BluetoothConnection.toAddress(selected.address);

        // 3. Safety Check: Did user leave the screen while we were waiting?
        if (!mounted) {
          connection.dispose();
          return;
        }

        // 4. Success: Update UI
        setState(() {
          _hc05Connection = connection;
          _hc05Connected = true;
        });

        // 5. Setup Disconnection Listener (Crucial for "Disconnected by remote")
        connection.input!.listen(
          (event) {
            // Handle incoming data here if needed
            // print('Data: ${ascii.decode(event)}');
          },
          onDone: () {
            // Call when connection closes normally
            if (mounted) {
              setState(() {
                _hc05Connected = false;
                _hc05Connection = null;
              });
              _log("HC-05 Disconnected (Done)");
              _showErrorDialog("Disconnected", "Device connection lost.");
            }
          },
          onError: (error) {
            // Call when connection closes with error
            if (mounted) {
              setState(() {
                _hc05Connected = false;
                _hc05Connection = null;
              });
              _log("HC-05 Disconnected (Error)");
            }
          },
        );
      } catch (e) {
        // 6. Failure: Show Error
        if (mounted) {
          _showErrorDialog("Connection Failed", e);
        }
      } finally {
        // 7. CRITICAL: Stop the loading spinner regardless of Success or Failure
        if (mounted) {
          setState(() => _isConnectingHC05 = false);
        }
      }
    } else {
      // 8. User Cancelled the Dialog (tapped outside)
      // We must stop the loading spinner here too!
      if (mounted) {
        setState(() => _isConnectingHC05 = false);
      }
    }
  }

  Future<void> _sendToHC05(String command) async {
    if (_hc05Connection != null && _hc05Connected) {
      try {
        _hc05Connection!.output.add(utf8.encode("$command\r\n"));
        // 2. Add 'await' here to ensure the data is actually flushed
        await _hc05Connection!.output.allSent;
      } catch (e) {
        _showErrorDialog("Send Error", e);
      }
    }
  }

  Future<void> _connectLightStick() async {
    setState(() => _isConnectingBLE = true);
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    var subscription = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.platformName == _ikeName) {
          FlutterBluePlus.stopScan();
          await _initBleDevice(r.device);
          break;
        }
      }
    });

    await Future.delayed(const Duration(seconds: 5));
    if (!_bleConnected) {
      if (mounted) setState(() => _isConnectingBLE = false);
    }
    FlutterBluePlus.stopScan();
    subscription.cancel();
  }

  Future<void> _initBleDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      if (!mounted) return;

      setState(() {
        _bleDevice = device;
        _bleConnected = true;
        _isConnectingBLE = false;
      });

      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString().toUpperCase() == _ledCharUuid) {
            _bleCharLed = characteristic;
            _sendPacket(0x20, 0, 255, 0, 255);
            break;
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnectingBLE = false);
        _showErrorDialog("BLE Connection Error", e);
      }
    }
  }

  Future<void> _sendPacket(int mode, int r, int g, int b, int extra) async {
    if (!_bleConnected || _bleCharLed == null) return;
    List<int> pkt = List.filled(20, 0);
    pkt[0] = mode;
    pkt[10] = r;
    pkt[11] = g;
    pkt[12] = b;
    pkt[13] = extra;
    pkt[18] = 0x01;
    try {
      await _bleCharLed!.write(pkt, withoutResponse: false);
    } catch (e) {
      // BLE errors are common (e.g. device out of range),
      // usually we don't want to pop up a dialog for every packet failure
      // so we just log it or ignore.
      print("BLE Write Error: $e");
    }
  }

  void _listen() async {
    if (!_isListening) {
      bool available = await _speech.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            setState(() {
              _lastWords = val.recognizedWords;
            });
            if (val.finalResult) {
              _processCommand(_lastWords.toLowerCase());
              setState(() => _isListening = false);
            }
          },
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  // ==========================================================
  // UI BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: kAccentBlue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.bolt, color: kAccentBlue),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Voice Commander",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                ),
                Text(
                  "HC-05 & Light Stick Control",
                  style: TextStyle(fontSize: 12, color: kTextGray),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: Icon(
              _hc05Connected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _hc05Connected ? kAccentBlue : kTextGray,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- CONNECTION CARDS ---
            _buildConnectionCard(
              "HC-05 Controller",
              _hc05Connected ? "Connected" : "Not Connected",
              _hc05Connected,
              _connectHC05,
              isLoading: _isConnectingHC05,
            ),
            const SizedBox(height: 12),
            _buildConnectionCard(
              "Light Stick (BLE)",
              _bleConnected ? "Connected" : "Not Connected",
              _bleConnected,
              _connectLightStick,
              isLoading: _isConnectingBLE,
            ),

            const SizedBox(height: 24),

            // --- INSTRUCTIONS / INFO PANEL ---
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCardColor,
                border: Border.all(color: kBorderColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "HC-05 Connection:",
                    style: TextStyle(
                      color: kAccentBlue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildInfoRow("Ensure HC-05 LED is blinking."),
                  _buildInfoRow("Keep device within 10 meters."),
                  _buildInfoRow(
                    "Use strict commands: 'Forward', 'Red', 'Play Music'.",
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // --- COMMAND HISTORY HEADER ---
            const Row(
              children: [
                Icon(Icons.access_time, color: kAccentBlue, size: 20),
                SizedBox(width: 8),
                Text(
                  "Command History",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // --- HISTORY LIST (Simplified Version) ---
            Expanded(
              child: ListView.builder(
                itemCount: historyLogs.length,
                itemBuilder: (context, index) {
                  final log = historyLogs[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: kCardColor.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kBorderColor.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        // 1. COMMAND TEXT ONLY
                        Expanded(
                          child: Text(
                            log['cmd']!,
                            style: const TextStyle(
                              fontFamily: 'Courier',
                              color: kAccentBlue,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),

                        // 2. DELETE BUTTON
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: kTextGray,
                            size: 20,
                          ),
                          onPressed: () {
                            setState(() {
                              historyLogs.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),

      // --- MICROPHONE BUTTON ---
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: GestureDetector(
        onTap: _listen,
        child: Container(
          height: 70,
          width: 70,
          decoration: BoxDecoration(
            color: _isListening ? Colors.redAccent : kAccentBlue,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (_isListening ? Colors.red : kAccentBlue).withOpacity(
                  0.4,
                ),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Icon(
            _isListening ? Icons.mic : Icons.mic_none,
            color: Colors.white,
            size: 32,
          ),
        ),
      ),
    );
  }

  // --- UI WIDGET HELPERS ---

  Widget _buildConnectionCard(
    String title,
    String status,
    bool isConnected,
    VoidCallback onTap, {
    bool isLoading = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kCardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    size: 14,
                    color: isConnected ? kAccentBlue : kTextGray,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status,
                    style: TextStyle(
                      color: isConnected ? kAccentBlue : kTextGray,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ),
          ElevatedButton(
            onPressed: (isConnected || isLoading)
                ? null
                : onTap, // Disable button while loading/connected
            style: ElevatedButton.styleFrom(
              backgroundColor: isConnected ? kCardColor : kAccentBlue,
              foregroundColor: isConnected ? kAccentGreen : Colors.white,
              elevation: isConnected ? 0 : 4,
              side: isConnected ? const BorderSide(color: kAccentGreen) : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    children: [
                      Icon(
                        isConnected ? Icons.check : Icons.bluetooth,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(isConnected ? "Active" : "Connect"),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        children: [
          const Text("• ", style: TextStyle(color: kTextGray)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: kTextGray, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
