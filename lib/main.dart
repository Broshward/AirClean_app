import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:esp_blufi/esp_blufi.dart'; // Основная библиотека
import 'dart:typed_data';                 // Для работы с Uint8List
import 'dart:convert';                    // Для работы с utf8.encode
import 'package:flutter/services.dart';	//Для фиксации поворота
import 'package:flutter/src/material/card_theme.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart'; // Для форматирования времени


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

enum ValueType { float, integer, boolean }
// Этот ключ — как "пульт управления" конкретным экземпляром экрана
//final GlobalKey<SensorScreenState> sensorScreenKey = GlobalKey<SensorScreenState>();


class SensorChartPage extends StatefulWidget {
  // Эти поля ДОЛЖНЫ быть здесь объявлены
  final SensorModel sensor; 
  final Function(String) onCommand;

  // Конструктор теперь их видит
  SensorChartPage({required this.sensor, required this.onCommand});

  @override
  _SensorChartPageState createState() => _SensorChartPageState();
}

class _SensorChartPageState extends State<SensorChartPage> {
  @override
  Widget build(BuildContext context) {
    // Внутри State мы обращаемся к ним через widget.sensor и widget.onCommand
    return Scaffold(
      appBar: AppBar(title: Text("История: ${widget.sensor.label}")),
      body: Column(
        children: [
          // ... тут твой код графика (LineChart) ...
            Text("Последние значения", style: TextStyle(fontSize: 18, color: Colors.grey)),
            const SizedBox(height: 30),
            AspectRatio(
              aspectRatio: 1.7,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true, drawVerticalLine: false),
                  titlesData: FlTitlesData(
                    // Настройка времени снизу
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final date = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                          return Text(DateFormat('HH:mm').format(date), style: TextStyle(fontSize: 10));
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: true, border: Border.all(color: Colors.black12)),
                  lineBarsData: [
                    LineChartBarData(
                      spots: widget.sensor.history.map((p) => FlSpot(p.time.millisecondsSinceEpoch.toDouble(), p.value)).toList(),
                      isCurved: true,
                      color: Colors.blueAccent,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(show: true), // Показывать точки замеров
                      belowBarData: BarAreaData(show: true, color: Colors.blueAccent.withOpacity(0.1)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          // spots: widget.sensor.history.map(...).toList(),
          
          ElevatedButton(
            onPressed: () => widget.onCommand("HIST:${widget.sensor.id}:144:2"),
            child: Text("Запросить историю"),
          ),
        ],
      ),
    );
  }
}

class ChartPoint 
{
  final DateTime time;
  final double value;
  ChartPoint(this.time, this.value);
}

class SensorModel 
{
  final int id;
  final ValueType valType;
  final String typeName;
  final String label;
  dynamic value; // Здесь будет лежать само значение (0.5, 10 или true)
  List<ChartPoint> history = []; // Сюда парсер будет складывать "H|" пакеты

  SensorModel({
    required this.id,
    required this.valType,
    required this.typeName,
    required this.label,
    this.value = 0,
  });

  // Магия парсинга строки "1:0:temp:Heater"
  factory SensorModel.fromString(String raw) {
    var parts = raw.split(':');
    return SensorModel(
      id: int.parse(parts[0]),
      valType: ValueType.values[int.parse(parts[1])],
      typeName: parts[2],
      label: parts[3],
    );
  }
}

class BlufiPage extends StatefulWidget 
{
  @override
  _BlufiPageState createState() => _BlufiPageState();
}

class _BlufiPageState extends State<BlufiPage> 
{
  List<String> devices = [];
  Map<String, String> deviceNames = {}; // Адрес: Имя
  bool isConnected = false;
  EspBlufi blufi = EspBlufi();

  bool _passwordVisible = false; // По умолчанию пароль скрыт
  List<dynamic> wifiNetworks = [];
  bool isScanningWifi = false; // Состояние поиска
  String? selectedSSID=null;
  TextEditingController passwordController = TextEditingController();
  
  TextEditingController ipController = TextEditingController(text: "0.0.0.0");
  TextEditingController maskController = TextEditingController(text: "0.0.0.0");
  TextEditingController gwController = TextEditingController(text: "0.0.0.0");

  List<String> eventLog = [];

  bool isStatic = false; // true - Static, false - DHCP

  String syncTime = "--:--:--"; // Время
  String deviceTime = "--:--:--"; // Время
  String deviceDate = "-- - -- - ----"; // Date
  int timeZone = 3;

  double otaProgress = 0.0; // 0.0 to 1.0  
  bool isUpdating = false;

  // Переменные для наших датчиков
  String lastConnectedAddress = ""; // Храним MAC последнего успешного входа

  final Map<String, int> timezones = {
    "Лондон (UTC+0)": 0,
    "Париж (UTC+1)": 1,
    "Калининград (UTC+2)": 2,
    "Москва (UTC+3)": 3,
    "Самара (UTC+4)": 4,
    "Екатеринбург (UTC+5)": 5,
    "Новосибирск (UTC+7)": 7,
    "Владивосток (UTC+10)": 10,
  };
  String selectedCity = "Москва (UTC+3)"; // Дефолтное значение

  BluetoothCharacteristic? commandCharacteristic;

  List<SensorModel> sensors = [];

  int viewMode = 0; // 0 - Поиск, 1 - Мониторинг, 2 - График
  SensorModel? selectedSensor; // Датчик, график которого мы сейчас смотрим

		  
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
            String raw = msg['value']; 
            
    }

		  // В. Сканирование Wifi
		  if (msg['key'] == 'wifi_info') {
            // Данные приходят в формате {"ssid": "MyRouter", "rssi": -50}
            var net = msg['value'];
            String ssid = net['ssid'] ?? "Unknown";
            int rssi = int.parse(net['rssi'] ?? '0');
            isScanningWifi = false;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isConnected ? lastConnectedAddress : "Поиск устройств"),
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
                itemBuilder: (ctx, i) {
                  // Проверяем, совпадает ли адрес в списке с последним удачным
                  bool isLast = devices[i] == lastConnectedAddress;
                
                  return ListTile(
                    leading: Icon(Icons.developer_board, color: isLast ? Colors.green : Colors.indigo),
                    title: Text(deviceNames[devices[i]] ?? "Unknown Device"),
                    subtitle: Text(devices[i]),
                    onTap: () => connect(devices[i]),
                    // Иконка link только для "старого знакомого", для остальных - ничего или просто стрелочка
                    trailing: isLast 
                      ? Icon(Icons.link, color: Colors.green) 
                      : Icon(Icons.chevron_right, color: Colors.grey),
                  );
                },
              ),
            ),

          // Если ПОДКЛЮЧЕНЫ - показываем датчики
          if (isConnected)
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(10),
                children: [
                  //SensorScreen(sensors: sensors),
                  buildSensorCards(),
                  Divider(height: 40, thickness: 2),
                  buildElegantClock(),
                  buildTimeSync(),
                  Divider(height: 40, thickness: 2),

                  Text("Настройка Wi-Fi (DHCP)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  // Кнопка запуска сканирования
                  ElevatedButton.icon(
                    onPressed: isScanningWifi ? null : startWifiScan, // Блокируем, пока ищем
                    icon: isScanningWifi 
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) 
                      : Icon(Icons.wifi_find),
                    label: Text(isScanningWifi ? "Поиск..." : "Найти сети"),
                    style: ElevatedButton.styleFrom(
                      // Если ищем - меняем цвет или делаем "вдавленной"
                      backgroundColor: isScanningWifi ? Colors.grey[300] : Colors.blue[300],
                      elevation: isScanningWifi ? 0 : 2,
                    ),
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
                        sendCommand("SET_DHCP");
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
                  child: Text("Перезагрузить устройство")
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    icon: Icon(Icons.memory),
                    label: Text("Обновить ПО"),
                    onPressed: updateFlash, 
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget buildTimeSync() {
    if (deviceTime.compareTo("Not sync")==0) 
      return Container(
        color: Colors.amber.shade100,
        padding: EdgeInsets.all(8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 10),
            Expanded(child: Text( "Время не синхронизировано!", 
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'monospace', // Моноширинный шрифт круто смотрится для часов
                color: Colors.grey[600],
              ),
            )),
          ],
        ),
      );
    else
      return Text(
        "Последняя синхронизация\nвремени: $syncTime",
        style: TextStyle(
        fontSize: 14,
        fontFamily: 'monospace', // Моноширинный шрифт круто смотрится для часов
        color: Colors.grey[600],
        ),
      );
  }

  Widget buildElegantClock() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(color: Colors.cyanAccent.withOpacity(0.05), blurRadius: 10)
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Блок Времени и Даты
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deviceTime, // 12:45:05
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              Text(deviceDate, // 14.03.2024
                  style: TextStyle(fontSize: 14, color: Colors.white54, letterSpacing: 1.1)),
            ],
          ),
          const SizedBox(width: 15),
          // Разделитель
          Container(width: 1, height: 30, color: Colors.white10),
          const SizedBox(width: 15),
          // Выбор города (убираем Dropdown, делаем через Popup или компактный клик)
          InkWell(
            onTap: () => _showCityPicker(), // Отдельная функция для выбора
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(selectedCity.split(" ").first, // Только название города
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(selectedCity.split(" ").last, // Только (UTC+3)
                        style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
                const Icon(Icons.arrow_drop_down, color: Colors.cyanAccent, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSensorCards() {
    if (sensors.isEmpty) {
      return Column(
        children: const [
          SizedBox(height: 50),
          CircularProgressIndicator(), // Крутилка
          SizedBox(height: 20),
          Text("Ожидание данных от устройства...", 
               style: TextStyle(color: Colors.grey)),
        ],
      );

    }

    return Column(
      children: sensors.map((sensor) {
        return InkWell(
          onTap: () {
            // Открываем график и передаем ссылку на нашу функцию отправки
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SensorChartPage(
                  sensor: sensor,
                  onCommand: sendCommand, 
                ),
              ),
            );
          },
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            child: ListTile(
              leading: Icon(_getIcon(sensor.typeName), color: _getIconColor(sensor.typeName), size: 30),
              title: Text(sensor.label, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("ID: ${sensor.id}"),
              trailing: Text(
                "${sensor.value.toStringAsFixed(1)}",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _getIconColor(sensor.typeName)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  
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
      });
  
      // Возвращаемся на экран поиска
      Navigator.of(context).popUntil((route) => route.isFirst);
  
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Disconnected")),
      );
    }
  }

  void connect(dynamic deviceAddress) async {
  try {
    // 1. Сначала BluFi делает свою работу
    await blufi.connectPeripheral(peripheralAddress: deviceAddress.toString());
    
    setState(() {
      isConnected = true;
      lastConnectedAddress = deviceAddress.toString();
    });

    // 2. КРИТИЧЕСКИ ВАЖНО: Даем Android "продышаться" перед вторым коннектом
    // Если броситься сразу — получим 133.
    await Future.delayed(Duration(milliseconds: 1500)); 
    setupFastSensors(deviceAddress.toString());

    Future.delayed(Duration(seconds: 3), () { 
      requestNetworkStatus();
      requestSyncTime();
      requestSensors();
    });
  } catch (e) {
    // Обработка ошибок
  }
}

  void disconnect() async {
    print("Возврат к списку устройств...");
    
    // 1. Сначала меняем состояние интерфейса (экран переключится мгновенно)
    setState(() {
      isConnected = false;
      // Опционально очищаем данные датчиков, чтобы при новом входе не было старых цифр
      ipController = TextEditingController(text: "0.0.0.0");
      maskController = TextEditingController(text: "0.0.0.0");
      gwController = TextEditingController(text: "0.0.0.0");

      selectedSSID=null;
	  wifiNetworks.clear();
	  syncTime='--:--:--';
	  deviceTime='--:--:--'; 
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
  void startWifiScan() async {
    setState(() => isScanningWifi = true); // Нажали!
    
    try {
      await sendCommand("WIFI_SCAN"); // Посылаем команду в новую трубу
      blufi.requestDeviceWifiScan();
      
      // Ждем немного или до прихода списка сетей
      await Future.delayed(Duration(seconds: 10)); 
    } finally {
      setState(() => isScanningWifi = false); // Отпустили
    }
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
  
	//Запрос времени синхронизации часов	  
  void requestSyncTime() async {
    if (isConnected) {
      print("Запрос времени синхронизации...");
      // Отправляем простую текстовую команду
      sendCommand("GET_SYNC_TIME");
    }
  }
  //Функция отправки команды запроса состояния сети
  void requestNetworkStatus() async {
    if (isConnected) {
      print("Запрос сетевого статуса...");
      // Отправляем простую текстовую команду
      sendCommand("GET_NET");
    }
  }
  //Функция запроса датчиков
  void requestSensors() {
    if (isConnected) {
      print("Запрос датчиков...");
      // Отправляем простую текстовую команду
      //await blufi.sendCustomData(data: "GET_SENSORS");
      sendCommand("GET_SENSORS");
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
    sendCommand(cmd);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Настройки отправлены..."), backgroundColor: Colors.orange),
    );
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
      sendCommand("RESET");
	}
  }
  //Функция загрузки обновления
  void updateFlash() async {
    if (isConnected) {
      print("Загрузка обновления прошивки...");
	  isUpdating = true;
      // Отправляем простую текстовую команду
      sendCommand("START_OTA");
    }
  }
  // Функция выбора часового пояса
  void _showCityPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1D2E), // Твой цвет Dark Mode
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: ListView(
            shrinkWrap: true, // Чтобы окно было по размеру списка
            children: timezones.keys.map((String city) {
              return ListTile(
                leading: const Icon(Icons.location_city, color: Colors.cyanAccent),
                title: Text(city, style: const TextStyle(color: Colors.white)),
                trailing: city == selectedCity 
                    ? const Icon(Icons.check, color: Colors.cyanAccent) 
                    : null,
                onTap: () {
                  setState(() {
                    selectedCity = city;
                    int offset = timezones[city]!;
                    sendCommand("SET_TZ:$offset");
                  });
                  Navigator.pop(context); // Закрываем окно после выбора
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }
  //Функция установки часового пояса
  void updateCityByOffset(int offset) {
    // Ищем первый ключ, значение которого равно пришедшему offset
    String? foundCity = timezones.keys.firstWhere(
      (key) => timezones[key] == offset,
      orElse: () => "Неизвестно (UTC$offset)", // Если вдруг такого смещения нет в списке
    );
  
    setState(() {
      selectedCity = foundCity;
    });
  }

  // Вынесем поиск характеристик в отдельный метод
  void _initializeService(BluetoothDevice device) async {
    print("Настраиваем сервис датчиков для ${device.remoteId.str}");
    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid.toString().contains("00ff")) {
        for (var char in service.characteristics) {
          if (char.uuid.toString().contains("ff01")) {
            await char.setNotifyValue(true);
            char.lastValueStream.listen((value) {
              String data = String.fromCharCodes(value);
              print("FAST DATA RECEIVED: $data");
              // Здесь обновляется UI
              setState(() {
                if (data.startsWith("Time:")) {
                  deviceTime = data.replaceFirst("Time:", "");
                }
                if (data.startsWith("Date:")) deviceDate = data.split(":")[1];
                if (data.startsWith("Values:")) {
                  data = data.replaceFirst("Values:", ""); // Берем всё, что после палки
                  updateValuesFromDevice(data);
                }
                if (data.startsWith("Sensors:")) {
                    // Убираем слово "Sensors:" и передаем остальное
                    String configData = data.replaceFirst("Sensors:", "");
                    updateSensorsFromDevice(configData);
                }
                if (data.startsWith("NET:")) {
                  // Разрезаем строку по разделителям
                  List<String> parts = data.substring(4).split("|");
                  if (parts.length == 4) {
                    setState(() {
                      ipController.text = parts[0];
                      maskController.text = parts[1];
                      gwController.text = parts[2];
                      isStatic = (parts[3] == "1"); 
                    });
                  }
                }
                if (data.startsWith("TZ:")) {
                  timeZone = int.parse(data.split(":")[1]);
                  updateCityByOffset(timeZone); // Обновляем текст в UI
                  print("Часовой пояс устройства: $timeZone ($selectedCity)");
                }
                if (data.startsWith("Time_sync_sntp:")) {
                  syncTime = data.split(":")[1];
                  if (syncTime.compareTo("Not sync")!=0)
                    syncTime = syncTime.replaceAll('_',':');
                }
                //History sensors<D-2>
                if (data.startsWith("H|")) {
                  // Пакет: H|timestamp|id:value
                  // Например: H|1713800000|1:25.4
                  List<String> parts = data.split('|');
                  if (parts.length >= 3) {
                    int? ts = int.tryParse(parts[1]);
                    if (ts != null) {
                      DateTime time = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
                      
                      // Парсим ID и значение (1:25.4)
                      List<String> valParts = parts[2].split(':');
                      int id = int.parse(valParts[0]);
                      double val = double.parse(valParts[1]);

                      // Вызываем метод обновления истории
                      updateSensorHistory(id, ChartPoint(time, val));
                    }
                  }
                }

              });
            });
          }

          if (char.uuid.toString().contains("ff02")) {
            commandCharacteristic = char;
            print("Канал команд (Write) найден!");
          }
        }
      }
    }
  }

void setupFastSensors(String macAddress) async {
  final device = BluetoothDevice.fromId(macAddress);

  // Пытаемся подключиться с небольшим таймаутом и повтором
  try {
    // Перед коннектом можно попробовать вызвать disconnect, на случай если "хвост" висит
    // await device.disconnect(); 
    
    await device.connect(autoConnect: false).timeout(Duration(seconds: 5));
    _initializeService(device);
  } catch (e) {
    print("Ошибка FBP: $e. Пробуем переподключиться через секунду...");
    await Future.delayed(Duration(seconds: 1));
    // Рекурсивно пробуем еще раз или просто игнорим, если BluFi работает
  }
}
  Future<void> sendCommand(String cmd) async {
    if (commandCharacteristic == null) return;
    try {
      await commandCharacteristic!.write(utf8.encode(cmd))
          .timeout(Duration(seconds: 2));
      print("Команда $cmd подтверждена ESP32");
    } catch (e) {
      print("Ошибка доставки команды: $e");
      // Можно показать пользователю легкий виброотклик или красный индикатор
    }
  }

  void updateValuesFromDevice(String rawValues) {
    setState(() {
      var valuePairs = rawValues.split(';').where((s) => s.isNotEmpty);
  
      for (var pair in valuePairs) {
        var parts = pair.split(':');
        int id = int.parse(parts[0]); // ID всегда целое
        String valStr = parts[1];     // Само значение 
 
        int index = sensors.indexWhere((s) => s.id == id);
        if (index != -1) {
          if (sensors[index].valType == ValueType.boolean) {
            sensors[index].value = (valStr == "1");
          } else {
            // ИСПОЛЬЗУЕМ double.parse ВМЕСТО int.parse
            sensors[index].value = double.tryParse(valStr) ?? 0.0;
          }
        }
      }
    });
  }

  void updateSensorsFromDevice(String rawData) {
    if (!mounted) return; // Проверка, что экран еще существует
    setState(() {
      sensors = rawData
          .split(';')
          .where((s) => s.isNotEmpty)
          .map((s) => SensorModel.fromString(s))
          .toList();
    });
  }

  IconData _getIcon(String type) {
    switch (type) {
      case 't': return Icons.thermostat;
      case 'h': return Icons.water_drop_rounded;
//      case 'l': return Icons.lightbulb; // Лампочка!
      case 'l': return Icons.light_mode;
      case 'sw': return Icons.power_settings_new_rounded;
      default: return Icons.sensors_rounded;
//      case 'T': return Icons.thermostat;
//      case 'H': return Icons.water_drop;
//      case 'P': return Icons.speed;
//      case 'B': return Icons.toggle_on;
//      default: return Icons.sensors;

    }
  }

  Color _getIconColor(String type) {
    switch (type) {
      case 't': return Colors.red;//orangeAccent;
      case 'h': return Colors.blueAccent;
      case 'l': return Colors.yellow[700]!;
      case 'sw': return Colors.greenAccent;
      default: return Colors.blueGrey;
    }
  }

  void updateSensorHistory(int id, ChartPoint point) {
    setState(() {
      // Ищем датчик в нашем основном списке
      int index = sensors.indexWhere((s) => s.id == id);
      if (index != -1) {
        // Проверяем, нет ли уже такой точки (по времени), чтобы не дублировать
        bool exists = sensors[index].history.any((p) => p.time == point.time);
        if (!exists) {
          sensors[index].history.add(point);
          // Сортируем по времени, чтобы график не "ломался"
          sensors[index].history.sort((a, b) => a.time.compareTo(b.time));
          
          // Ограничиваем историю (например, последние 200 точек), чтобы не ело память
          if (sensors[index].history.length > 200) {
            sensors[index].history.removeAt(0);
          }
        }
      }
    });
  }
}
