import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:esp_blufi/esp_blufi.dart'; // Основная библиотека
import 'dart:typed_data';                 // Для работы с Uint8List
import 'dart:convert';                    // Для работы с utf8.encode
import 'package:flutter/services.dart';	//Для фиксации поворота
import 'package:flutter/src/material/card_theme.dart';

void main() async
{
  // 1. Обязательно инициализируем привязки Flutter
  WidgetsFlutterBinding.ensureInitialized();
  
  // 2. Блокируем ориентацию (только портретная)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(
    MaterialApp(
	  home: BlufiPage(),
	  debugShowCheckedModeBanner: false,
	  //Тёмная тема
      title: 'ESP32 BluFi Control',
      theme: ThemeData.dark().copyWith( // Включаем темную тему
        scaffoldBackgroundColor: const Color(0xFF0F111A), // Глубокий полночный синий
        primaryColor: Colors.cyanAccent,
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1D2E), // Цвет карточек чуть светлее фона
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),

	)
  );
}

class BlufiPage extends StatefulWidget {
  @override
  _BlufiPageState createState() => _BlufiPageState();
}
class _BlufiPageState extends State<BlufiPage> {
  List<String> devices = [];
  Map<String, String> deviceNames = {}; // Адрес: Имя
  bool isConnected = false;
  EspBlufi blufi = EspBlufi();

  bool _passwordVisible = false; // По умолчанию пароль скрыт
  List<dynamic> wifiNetworks = [];
  String? selectedSSID=null;
  TextEditingController passwordController = TextEditingController();
  
  TextEditingController ipController = TextEditingController(text: "0.0.0.0");
  TextEditingController maskController = TextEditingController(text: "0.0.0.0");
  TextEditingController gwController = TextEditingController(text: "0.0.0.0");

  List<String> eventLog = [];

  bool isStatic = false; // true - Static, false - DHCP

  String deviceTime = "Not sync"; // Время

  double otaProgress = 0.0; // 0.0 to 1.0  
  bool isUpdating = false;

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
          
          // А. Обработка сканирования
          if (msg['key'] == 'ble_scan_result') {
            String address = msg['value']['address'];
            String name = msg['value']['name'] ?? "Unknown";
          
            // ФИЛЬТР: Добавляем только если в имени есть "BLUFI" или "ESP32"
            if (name.toUpperCase().contains("BLUFI") || name.toUpperCase().contains("ESP32")) {
              setState(() {
                if (!devices.contains(address)) {
                  devices.add(address);
                  deviceNames[address] = name;
                }
              });
            }
          }
          
          if (msg['key'] == 'gatt_disconnected') {
            print("Событие: Соединение разорвано");
            onConnectionLost();
		  }

          // Б. Обработка данных от датчиков (Custom Data)
          if (msg['key'] == 'receive_device_custom_data') {
            String raw = msg['value']; // Например "Amb_temp:24.5"
            
            if (raw.startsWith("NET:")) {
              // Разрезаем строку по разделителям
              List<String> parts = raw.substring(4).split("|");
              if (parts.length == 4) {
                setState(() {
				  ipController.text = parts[0];
				  maskController.text = parts[1];
				  gwController.text = parts[2];
				  isStatic = (parts[3] == "1"); 
      
				  addToLog("Режим сети: ${isStatic ? 'Static' : 'DHCP'}");
    
                });
              }
            }
			else {
              setState(() {
                if (raw.startsWith("Amb_Temp:")) ambTemp = raw.split(":")[1];
                if (raw.startsWith("Chip_Temp:")) chipTemp = raw.split(":")[1];
                if (raw.startsWith("Lumin:")) lumin = raw.split(":")[1];
                if (raw.startsWith("Time:")) {
					deviceTime = raw.split(":")[1];
					if (deviceTime.compareTo("Not sync")!=0)
						deviceTime = deviceTime.replaceAll('_',':');
				}
		        // Г. вывод логов на экран
                addToLog("Получено: $raw"); // Видим всё, что шлет ESP32
                  // ... парсинг ...
              });
			}
          }

		  // В. Сканирование Wifi
		  if (msg['key'] == 'wifi_info') {
            // Данные приходят в формате {"ssid": "MyRouter", "rssi": -50}
            var net = msg['value'];
            String ssid = net['ssid'] ?? "Unknown";
            int rssi = int.parse(net['rssi'] ?? '0');
          
            setState(() {
              // Добавляем сеть в список, если её там еще нет
              if (!wifiNetworks.any((element) => element['ssid'] == ssid)) {
                wifiNetworks.add(net);
                // Сортируем по силе сигнала (RSSI), чтобы лучшие были сверху
                wifiNetworks.sort((b,a) => b['rssi'].compareTo(a['rssi']));
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
    const double minTemp = 0;
    const double maxTemp = 50;
    const double step = 5; // Шаг цифр: 10, 15, 20...

    return Scaffold(
      appBar: AppBar(
        title: Text(isConnected ? "Мониторинг ESP32" : "Поиск устройств"),
        backgroundColor: isConnected ? Colors.blueGrey : Colors.indigo,
        leading: isConnected 
          ? IconButton(icon: Icon(Icons.arrow_back), onPressed: disconnect) 
          : Icon(Icons.bluetooth),
        actions: [
	      FutureBuilder(
            future: Permission.location.serviceStatus.isEnabled,
            builder: (context, snapshot) {
              if (snapshot.data == false) {
                return Icon(Icons.location_off, color: Colors.red);
              }
              return SizedBox();
            },
          ),
          if (!isConnected) IconButton(icon: Icon(Icons.refresh), onPressed: startScan)
        ],
      ),
      body: Column(
        children: [
          // Блок кнопок управления
          if (!isConnected) Padding(
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
				  leading: Icon(Icons.developer_board, color: Colors.indigo),
				  title: Text(deviceNames[devices[i]] ?? "Unknown Device"),
				  subtitle: Text(devices[i]), // Здесь оставим MAC-адрес
				  onTap: () => connect(devices[i]),
				  trailing: Icon(Icons.link),
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
                        Text("Термометр 0-50 °C"),
                        LinearProgressIndicator(
                          value: (double.tryParse(ambTemp) ?? 0) / 50, // Шкала до 50 градусов
                          backgroundColor: Colors.grey[300],
                          color: getDynamicColor(ambTemp),
                          minHeight: 10,
                        ),
                      ],
                    ),
                  ),
				  //Ещё один термометер))
                  buildThermometerScale(double.tryParse(ambTemp) ?? 0),
                  Column(
                    children: [
                      Icon(
                        Icons.thermostat,
                        size: 40,
                        color: getDynamicColor(ambTemp), 
                      ),
                      Text(
                        "$ambTemp°C",
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: getDynamicColor(ambTemp),
                        ),
                      ),
                    ],
                  ),
                  if (deviceTime.compareTo("Not sync")==0) Container(
                    color: Colors.amber.shade100,
                    padding: EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orange),
                        SizedBox(width: 10),
                        Expanded(child: Text(
						  "Время не синхронизировано!", 
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace', // Моноширинный шрифт круто смотрится для часов
                            color: Colors.grey[600],
                          ),
						)),
                      ],
                    ),
                  )
		          else
                    Text(
                      "Время на устройстве: $deviceTime",
                      style: TextStyle(
                    	fontSize: 14,
                    	fontFamily: 'monospace', // Моноширинный шрифт круто смотрится для часов
                    	color: Colors.grey[600],
                      ),
                    ),
                  Divider(height: 40, thickness: 2),
                  Text("Настройка Wi-Fi (DHCP)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  
                  const SizedBox(height: 10),
                  
                  // Кнопка запуска сканирования
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                    icon: Icon(Icons.search),
                    label: Text("Найти Wi-Fi сети"),
                    onPressed: scanWifi, 
                  ),
                  
                  // Если сети найдены — показываем выбор
                  if (wifiNetworks.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blueGrey),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedSSID,
                          hint: Text("Выберите вашу сеть..."),
                          isExpanded: true,
                          items: wifiNetworks.map((net) {
                            return DropdownMenuItem<String>(
                              value: net['ssid'],
                              child: Text("${net['ssid']} [${net['rssi']} dBm]"),
                            );
                          }).toList(),
                          onChanged: (value) => setState(() => selectedSSID = value),
                        ),
                      ),
                    ),
                  ],
                  
                  // Поле для пароля (показываем только если выбрана сеть)
                  if (selectedSSID != null) ...[
                    TextField(
                      controller: passwordController,
                      obscureText: !_passwordVisible, // Если false — скрываем текст (точечки)
                      decoration: InputDecoration(
                        labelText: "Пароль от Wi-Fi",
                        border: OutlineInputBorder(), // Красивая рамка
                        suffixIcon: IconButton(
                          icon: Icon(
                            // Меняем иконку в зависимости от состояния
                            _passwordVisible ? Icons.visibility : Icons.visibility_off,
                            color: Colors.blueGrey,
                          ),
                          onPressed: () {
                            // Переключаем видимость при нажатии
                            setState(() {
                              _passwordVisible = !_passwordVisible;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      onPressed: sendWifiCredentials,
                      child: Text("ПОДКЛЮЧИТЬ"),
                    ),
                  ],
				  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Параметры сети", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: Icon(Icons.refresh, color: Colors.blue),
                        onPressed: requestNetworkStatus,
                        tooltip: "Обновить данные о сети",
                      ),
                    ],
                  ),
				  // Переключатель режима
                  SwitchListTile(
                    title: Text("Использовать статический IP"),
                    subtitle: Text(isStatic ? "Ручная настройка" : "Получать по DHCP автоматически"),
                    value: isStatic,
                    activeColor: Colors.orange,
                    onChanged: (bool value) {
                      setState(() {
                        isStatic = value;
                      });
                      // Если выключили статику — сразу шлем команду сброса на ESP32
                      if (!value) {
                        blufi.sendCustomData(data: "SET_DHCP");
                        addToLog("Переключение на DHCP...");
                      }
                    },
                  ),
                  
                  // Поля ввода (теперь они зависят от isStatic)
                  TextField(
                    controller: ipController,
                    enabled: isStatic, // Если DHCP — поле серое и нажать нельзя
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: "IP адрес",
                      fillColor: isStatic ? Colors.transparent : Colors.grey.withOpacity(0.1),
                      filled: !isStatic,
                    ),
                  ),
                  TextField(
                    controller: maskController,
                    enabled: isStatic, // Если DHCP — поле серое и нажать нельзя
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: "Маска подсети",
                      fillColor: isStatic ? Colors.transparent : Colors.grey.withOpacity(0.1),
                      filled: !isStatic,
                    ),
                  ),
                  TextField(
                    controller: gwController,
                    enabled: isStatic, // Если DHCP — поле серое и нажать нельзя
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: "Шлюз (Gateway)",
                      fillColor: isStatic ? Colors.transparent : Colors.grey.withOpacity(0.1),
                      filled: !isStatic,
                    ),
                  ),
                  
                  if (isStatic)
                    ElevatedButton(
                      onPressed: applyStaticIP,
                      child: Text("СОХРАНИТЬ STATIC IP"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                    ),


				  Divider(height: 40, thickness: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Лог событий", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      TextButton(onPressed: () => setState(() => eventLog.clear()), child: Text("Очистить")),
                    ],
                  ),
                  Container(
                    height: 150, // Ограничим высоту лога
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: eventLog.length,
                      itemBuilder: (ctx, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(eventLog[i], style: TextStyle(fontSize: 12, fontFamily: 'monospace')),
                      ),
                    ),
                  ),
				  TextButton(onPressed: resetDevice, 
					child: Text("Сбросить устройство")
				  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    icon: Icon(Icons.memory),
                    label: Text("Обновить ПО"),
                    onPressed: updateFlash, 
                  ),
                  if (isUpdating) 
                    LinearProgressIndicator(
                      value: otaProgress,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget buildThermometerScale(double currentTemp) {
    const double minTemp = 00;
    const double maxTemp = 50;
    const double step = 5; // Шаг цифр: 10, 15, 20...
  
    return Column(
      children: [
        // 1. Сама цветная полоска (твой прогресс-бар)
        Container(
          height: 12,
          width: 300,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            gradient: LinearGradient(colors: [Colors.blue, Colors.green, Colors.red]),
          ),
          child: 
            Stack(
              clipBehavior: Clip.none, // Чтобы свечение не обрезалось краями
              children: [
                
                AnimatedPositioned(
                  duration: Duration(milliseconds: 300), // Плавное движение за 0.3 сек
                  curve: Curves.easeOutCubic,
                  left: ((currentTemp - minTemp) / (maxTemp - minTemp) * 300) - 2, // -2 для центровки 4-пиксельного бара
                  top: -2, // Смещение вверх, чтобы перекрывал шкалу
                  child: buildGlowPointer(currentTemp),
                ),
              ],
            )
        ),
        SizedBox(height: 8),
        // 2. Шкала с цифрами
        Container(
          width: 300,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(((maxTemp - minTemp) / step).toInt() + 1, (index) {
              double val = minTemp + (index * step);
              return Column(
                children: [
                  Container(width: 1, height: 5, color: Colors.grey), // Риска
                  Text(
                    "${val.toInt()}",
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                  ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget buildGlowPointer(double currentTemp) {
    // Получаем цвет в зависимости от температуры (наша старая функция)
    Color pointerColor = getDynamicColor(currentTemp.toString());
    
    return Container(
      width: 4,
      height: 16, // Чуть выше шкалы, чтобы выделялся
      decoration: BoxDecoration(
        color: Colors.white, // Сам стержень белый для контраста
        borderRadius: BorderRadius.circular(2),
        boxShadow: [
          BoxShadow(
            color: pointerColor.withOpacity(0.8), // Свечение в цвет температуры
            blurRadius: 10,  // Насколько сильно рассеивается свет
            spreadRadius: 2, // Насколько широкое пятно
          ),
          BoxShadow(
            color: pointerColor.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
    );
  }

  
  // Функции startScan и connect остаются как были
  void startScan() async {
	checkHardwareServices(); // Сначала проверяем железо
  
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

  // Функция для разрыва связи
  void onConnectionLost() {
    if (mounted) { // Проверка, что экран еще открыт
      setState(() {
        isConnected = false;
        // Сбрасываем данные, чтобы не вводить в заблуждение
        ambTemp = "--"; 
      });
  
      // Возвращаемся на экран поиска
      Navigator.of(context).popUntil((route) => route.isFirst);
  
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Связь с устройством потеряна")),
      );
    }
  }

  void connect(dynamic deviceAddress) async {
    print("Подключение к: $deviceAddress");

    try {
      await blufi.connectPeripheral(peripheralAddress: deviceAddress.toString());
	  
      setState(() {
        isConnected = true;

      });
	  // Даем 1 секунду на "прогрев" соединения и запрашиваем статус сети
      Future.delayed(Duration(seconds: 2), () => requestNetworkStatus());

      print("Подключено!");
	  addToLog("Успешно подключено!");
    } catch (e) {
      // Показываем SnackBar с советом
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Не удалось подключиться. Попробуйте ещё раз!")),
      );
      print("Не удалось подключиться: $e");
	  addToLog("Не удалось подключиться $e!");
    }
  }

  void disconnect() async {
    print("Возврат к списку устройств...");
    
    // 1. Сначала меняем состояние интерфейса (экран переключится мгновенно)
    setState(() {
      isConnected = false;
      // Опционально очищаем данные датчиков, чтобы при новом входе не было старых цифр
      ambTemp = "--";
      chipTemp = "--";
      lumin = "--";
      ipController = TextEditingController(text: "0.0.0.0");
      maskController = TextEditingController(text: "0.0.0.0");
      gwController = TextEditingController(text: "0.0.0.0");

      selectedSSID=null;
	  wifiNetworks.clear();
	  deviceTime='Not sync';
    });
  
    // 2. Затем пытаемся корректно закрыть соединение в фоне
    try {
      await blufi.requestCloseConnection();
      print("Соединение закрыто на стороне Bluetooth");
    } catch (e) {
      print("Ошибка при закрытии соединения: $e");
    }
  }

  // Функция запроса сканирования сетей у ESP32
  void scanWifi() async {
    print("Запрос списка Wi-Fi у ESP32...");
    setState(() => wifiNetworks.clear());
    await blufi.requestDeviceWifiScan();
  }
  
  // Функция отправки SSID и Пароля на ESP32
  void sendWifiCredentials() async {
    if (selectedSSID != null) {
      print("Отправка данных Wi-Fi: $selectedSSID");
	  String? ssid=selectedSSID;
      selectedSSID=null;
	  wifiNetworks.clear();
      await blufi.configProvision(
        username: ssid, 
        password: passwordController.text
      );
      print("Данные отправлены! Ждем подключения...");
    }
  }
  
  //Функция отправки команды запроса состояния сети
  void requestNetworkStatus() async {
    if (isConnected) {
      print("Запрос сетевого статуса...");
      // Отправляем простую текстовую команду
      await blufi.sendCustomData(data: "GET_NET");
    }
  }
  // Функция установки статического IP-адреса
  bool isValidIP(String ip) {
    // Регулярное выражение для проверки формата 0.0.0.0 - 255.255.255.255
    final regExp = RegExp(r'^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$');
    return regExp.hasMatch(ip);
  }
  
  void applyStaticIP() async {
    if (!isValidIP(ipController.text) || 
        !isValidIP(maskController.text) || 
        !isValidIP(gwController.text)) {
      
      // Покажем всплывающее уведомление об ошибке
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Ошибка: Неверный формат IP-адреса!"), backgroundColor: Colors.red),
      );
      return;
    }
  
    String cmd = "SET_STATIC:${ipController.text}|${maskController.text}|${gwController.text}";
    print("Отправка статики: $cmd");
    await blufi.sendCustomData(data: cmd);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Настройки отправлены..."), backgroundColor: Colors.orange),
    );
    addToLog("Отправка Static IP: ${ipController.text}");
  }

  // Удобная функция для добавления записи с меткой времени
  void addToLog(String message) {
    String time = DateTime.now().toString().split('.').first.split(' ').last; // "14:20:05"
    setState(() {
      eventLog.insert(0, "[$time] $message"); // Новые записи — сверху
      if (eventLog.length > 50) eventLog.removeLast(); // Храним только последние 50 событий
    });
  }

  void checkHardwareServices() async {
    // 1. Проверяем Bluetooth
    if (await Permission.bluetooth.serviceStatus.isDisabled) {
      showServiceDialog("Bluetooth выключен", "Пожалуйста, включи Bluetooth для поиска ESP32.");
      return;
    }
  
    // 2. Проверяем Геолокацию (GPS)
    if (await Permission.location.serviceStatus.isDisabled) {
      showServiceDialog("Геолокация выключена", "Android требует включенный GPS для сканирования Bluetooth.");
      return;
    }
  }

  // Удобное окно с кнопкой перехода в настройки
  void showServiceDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("ОК"),
          ),
        ],
      ),
    );
  }

  Color getTemperatureColor(double temp) {
    if (temp <= 15) return Colors.blue;          // Холодно
    if (temp >= 35) return Colors.red;           // Жарко
    
    if (temp < 25) {
      // Переход от синего к зеленому (15°C - 25°C)
      return Color.lerp(Colors.blue, Colors.green, (temp - 15) / 10)!;
    } else {
      // Переход от зеленого к красному (25°C - 35°C)
      return Color.lerp(Colors.green, Colors.red, (temp - 25) / 10)!;
    }
  }

  Color getDynamicColor(String tempStr) {
    // Парсим строку в число, если не выходит — ставим 0.0
    double temp = double.tryParse(tempStr) ?? 0.0;
  
    if (temp <= 18) return Colors.blue;          // Холодно
    if (temp >= 30) return Colors.red;           // Жарко
    
    // Плавный переход Синий -> Зеленый (18-24 градуса)
    if (temp < 24) {
      double factor = (temp - 18) / 6; 
      return Color.lerp(Colors.blue, Colors.green, factor.clamp(0.0, 1.0))!;
    } 
    // Плавный переход Зеленый -> Красный (24-30 градусов)
    else {
      double factor = (temp - 24) / 6;
      return Color.lerp(Colors.green, Colors.red, factor.clamp(0.0, 1.0))!;
    }
  }

  // Program reset device
  void resetDevice() async {
    if (isConnected) {
      print("Программный сброс!...");
      await blufi.sendCustomData(data: "RESET");
	}
  }
  //Функция загрузки обновления
  void updateFlash() async {
    if (isConnected) {
      print("Загрузка обновления прошивки...");
	  isUpdating = true;
      // Отправляем простую текстовую команду
      await blufi.sendCustomData(data: "START_OTA");
    }
  }
}
