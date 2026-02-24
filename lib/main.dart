import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:esp_blufi/esp_blufi.dart'; // Основная библиотека
import 'dart:typed_data';                 // Для работы с Uint8List
import 'dart:convert';                    // Для работы с utf8.encode

void main() => runApp(MaterialApp(home: BlufiPage()));

class BlufiPage extends StatefulWidget {
  @override
  _BlufiPageState createState() => _BlufiPageState();
}
class _BlufiPageState extends State<BlufiPage> {
  List<String> devices = [];
  bool isConnected = false;
  EspBlufi blufi = EspBlufi();

  // Переменные для наших датчиков
  String ambTemp = "--";
  String chipTemp = "--";
  String lumin = "--";

  @override
  void initState() {
    super.initState();
    blufi.onMessageReceived(
      successCallback: (data) {
        try {
          Map<String, dynamic> msg = jsonDecode(data!);
          
          // А) Обработка сканирования
          if (msg['key'] == 'ble_scan_result') {
            String address = msg['value']['address'];
            if (!devices.contains(address)) {
              setState(() => devices.add(address));
            }
          }
          
          // Б) Обработка данных от датчиков (Custom Data)
          if (msg['key'] == 'receive_device_custom_data') {
            String raw = msg['value']; // Например "Amb_temp:24.5"
            
            setState(() {
              if (raw.startsWith("Amb_Temp:")) ambTemp = raw.split(":")[1];
              if (raw.startsWith("Chip_Temp:")) chipTemp = raw.split(":")[1];
              if (raw.startsWith("Lumin:")) lumin = raw.split(":")[1];
            });
          }
        } catch (e) {
          print("Ошибка парсинга: $e");
        }
      },
      errorCallback: (err) => print("Ошибка: $err")
    );
  }

  // Виджет одной карточки датчика
  Widget sensorCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 4,
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(value, style: TextStyle(fontSize: 20, color: color, fontWeight: FontWeight.bold)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("ESP32 Smart Home"), backgroundColor: Colors.blueGrey),
      body: Column(
        children: [
          // Блок кнопок управления
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: ElevatedButton(onPressed: startScan, child: Text("Поиск"))),
                SizedBox(width: 10),
                if (isConnected) Icon(Icons.bluetooth_connected, color: Colors.green),
              ],
            ),
          ),

          // Если НЕ подключены - показываем список устройств
          if (!isConnected)
            Expanded(
              child: ListView.builder(
                itemCount: devices.length,
                itemBuilder: (ctx, i) => ListTile(
                  title: Text(devices[i]),
                  onTap: () => connect(devices[i]),
                  trailing: Icon(Icons.arrow_forward_ios, size: 16),
                ),
              ),
            ),

          // Если ПОДКЛЮЧЕНЫ - показываем "Термометр" и датчики
          if (isConnected)
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(10),
                children: [
                  sensorCard("Окружающая среда", "$ambTemp °C", Icons.thermostat, Colors.red),
                  sensorCard("Температура чипа", "$chipTemp °C", Icons.memory, Colors.orange),
                  sensorCard("Освещенность", "$lumin Lux", Icons.lightbulb, Colors.yellow[700]!),
                  
                  // "Красивый" визуальный индикатор (прогресс-бар как термометр)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
                    child: Column(
                      children: [
                        Text("Уровень тепла"),
                        LinearProgressIndicator(
                          value: (double.tryParse(ambTemp) ?? 0) / 50, // Шкала до 50 градусов
                          backgroundColor: Colors.grey[300],
                          color: Colors.redAccent,
                          minHeight: 10,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
  
  // Функции startScan и connect остаются как были
  void startScan() async {
    print("Запуск поиска...");
    
    // 1. Сначала спрашиваем разрешения (как мы делали)
    if (await Permission.location.request().isGranted) {
      setState(() => devices.clear());

      // 2. Запускаем сканирование
      await blufi.scanDeviceInfo();

      // 3. УСТАНАВЛИВАЕМ ТАЙМЕР: Остановить через 5 секунд
      Future.delayed(Duration(seconds: 5), () async {
        print("Таймер: Останавливаем сканирование...");
        await blufi.stopScan();
        
        // После остановки пытаемся собрать всё, что нашло
        var found = await blufi.getAllPairedDevice();
        print("Итоговый список устройств: $found");
        
        setState(() {
           // Если библиотека вернула список, кладем его в нашу переменную для экрана
           if (found != null) devices = found;
        });
      });
      
    } else {
      print("Нет доступа к локации!");
    }
  }

  void connect(dynamic deviceAddress) async {
    print("Подключение к: $deviceAddress");
    try {
      await blufi.connectPeripheral(peripheralAddress: deviceAddress.toString());
      setState(() {
        isConnected = true;
      });
      print("Подключено!");
    } catch (e) {
      print("Не удалось подключиться: $e");
    }
  }

}
