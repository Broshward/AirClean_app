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
  // Используем динамический список, чтобы избежать ошибок типизации
  List<String> devices = []; 
  bool isConnected = false;
  EspBlufi blufi = EspBlufi();

  @override
	void initState() {
	  super.initState();
	  blufi.onMessageReceived(
		successCallback: (data) {
		  // 1. Декодируем JSON-строку, которую прислала библиотека
		  try {
			Map<String, dynamic> msg = jsonDecode(data!);
			
			// 2. Если это результат сканирования (ble_scan_result)
			if (msg['key'] == 'ble_scan_result') {
			  var deviceData = msg['value'];
			  String address = deviceData['address'];
			  String name = deviceData['name'] ?? "Unknown";

			  setState(() {
				// Проверяем, нет ли уже этого адреса в списке
				if (!devices.contains(address)) {
				  devices.add(address); // Добавляем адрес в список для экрана
				  print("Добавлено в список: $name ($address)");
				}
			  });
			}
		  } catch (e) {
			print("Ошибка парсинга: $e");
		  }
		},
		errorCallback: (err) => print("Ошибка: $err")
	  );
	}

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("ESP32 BluFi 0.1.8")),
      body: Column(
        children: [
          ElevatedButton(onPressed: startScan, child: Text("1. Искать (scanDeviceInfo)")),
          // Если список пуст, выводим заглушку
          if (devices.isEmpty) Padding(padding: EdgeInsets.all(20), child: Text("Устройств пока нет")),
          Expanded(
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (ctx, i) => ListTile(
                title: Text("Устройство ${devices[i]}"),
                onTap: () => connect(devices[i]),
              ),
            ),
          ),
          if (isConnected)
            ElevatedButton(
              onPressed: () => blufi.sendCustomData(data: "Hello"),
              child: Text("2. Отправить Hello"),
            ),
        ],
      ),
    );
  }
}
