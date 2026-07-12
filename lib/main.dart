import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

const firebaseOptions = FirebaseOptions(
  apiKey: "AIzaSyC0rFOiAx5LEpT-6s9Bc8sxNtc59RfsOcM",
  authDomain: "u-coffee.firebaseapp.com",
  databaseURL: "https://u-coffee-default-rtdb.firebaseio.com",
  projectId: "u-coffee",
  storageBucket: "u-coffee.firebasestorage.app",
  messagingSenderId: "971000964907",
  appId: "1:971000964907:web:b1e9271ca53fbfff6ac76e",
  measurementId: "G-M5HM5H2D75",
);

late final AppState globalAppState;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  try {
    await Firebase.initializeApp(options: firebaseOptions);
  } catch (e) {
    debugPrint("Firebase init error: $e");
  }

  globalAppState = AppState();
  runApp(const MockApp());
}

enum ShiftType { none, full, morning, evening }
enum PrefType { none, ready, readyAfter15, readyBefore15, notReady }

class AppState extends ChangeNotifier {
  List<String> baristas = [];
  Map<String, Map<String, ShiftType>> shifts = {};
  Map<String, Map<String, PrefType>> prefs = {};
  List<String> auditLogs = [];
  String? lastError;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _baristasLoaded = false;

  // Статус администратора — определяется через Firebase Auth
  bool get isAdmin => _auth.currentUser?.email == 'admin@u-coffee.app';

  AppState() {
    _initStreams();
  }

  /// Вход админа через Firebase Auth — пароль проверяется сервером
  Future<String?> signInAdmin(String pin) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: 'admin@u-coffee.app',
        password: pin,
      );
      notifyListeners();
      return null; // Успех
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        return 'Неверный PIN-код';
      }
      return 'Ошибка авторизации: ${e.message}';
    }
  }

  /// Выход из аккаунта
  Future<void> signOut() async {
    await _auth.signOut();
    notifyListeners();
  }

  void _initStreams() {
    try {
      // Список бариста из Firestore (с fallback на дефолтные)
      _db.collection('app_config').doc('baristas').snapshots().listen((snap) {
        if (snap.exists && snap.data()?['names'] != null) {
          baristas = List<String>.from(snap.data()!['names']);
        } else if (!_baristasLoaded) {
          // Первый запуск — инициализируем дефолтный список
          baristas = ['Юрий', 'Валерия', 'Дарьяна', 'Анастасия'];
          _db.collection('app_config').doc('baristas').set({
            'names': baristas,
          }).catchError((_) {}); // Может не записаться без прав — ок
        }
        _baristasLoaded = true;
        notifyListeners();
      });

      _db.collection('schedule_shifts_v2').snapshots().listen((snap) {
        shifts.clear();
        for (var doc in snap.docs) {
          final dateKey = doc.id;
          final data = doc.data();
          data.forEach((barista, typeIndex) {
            if (!shifts.containsKey(barista)) shifts[barista] = {};
            shifts[barista]![dateKey] =
                ShiftType.values[(typeIndex as num).toInt()];
          });
        }
        notifyListeners();
      }, onError: (e) {
        lastError = e.toString();
        notifyListeners();
      });

      _db.collection('schedule_prefs_v2').snapshots().listen((snap) {
        prefs.clear();
        for (var doc in snap.docs) {
          final dateKey = doc.id;
          final data = doc.data();
          data.forEach((barista, typeIndex) {
            if (!prefs.containsKey(barista)) prefs[barista] = {};
            prefs[barista]![dateKey] =
                PrefType.values[(typeIndex as num).toInt()];
          });
        }
        notifyListeners();
      });

      _db
          .collection('logs_v2')
          .orderBy('time', descending: true)
          .limit(50)
          .snapshots()
          .listen((snap) {
        auditLogs = snap.docs.map((doc) => doc.data()['text'] as String).toList();
        notifyListeners();
      });
    } catch (e) {
      lastError = "Ошибка инициализации потоков: $e";
      notifyListeners();
    }
  }

  // --- Управление сотрудниками (только админ) ---

  Future<void> _saveBaristas() async {
    await _db.collection('app_config').doc('baristas').set({
      'names': baristas,
    });
  }

  Future<String?> addBarista(String name) async {
    if (!isAdmin) return 'Нет доступа';
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Имя не может быть пустым';
    if (baristas.contains(trimmed)) return 'Сотрудник уже существует';
    try {
      baristas.add(trimmed);
      await _saveBaristas();
      await _logAction('Добавлен сотрудник: $trimmed');
      notifyListeners();
      return null;
    } catch (e) {
      return 'Ошибка: $e';
    }
  }

  Future<String?> renameBarista(String oldName, String newName) async {
    if (!isAdmin) return 'Нет доступа';
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return 'Имя не может быть пустым';
    if (trimmed == oldName) return null; // Ничего не менялось
    if (baristas.contains(trimmed)) return 'Сотрудник с таким именем уже есть';
    final index = baristas.indexOf(oldName);
    if (index == -1) return 'Сотрудник не найден';
    try {
      baristas[index] = trimmed;
      await _saveBaristas();
      // Переносим данные смен и пожеланий на новое имя
      await _migrateEmployeeData(oldName, trimmed);
      await _logAction('Переименован: $oldName → $trimmed');
      notifyListeners();
      return null;
    } catch (e) {
      return 'Ошибка: $e';
    }
  }

  Future<String?> removeBarista(String name) async {
    if (!isAdmin) return 'Нет доступа';
    if (!baristas.contains(name)) return 'Сотрудник не найден';
    try {
      baristas.remove(name);
      await _saveBaristas();
      await _logAction('Удалён сотрудник: $name');
      notifyListeners();
      return null;
    } catch (e) {
      return 'Ошибка: $e';
    }
  }

  /// Переносит смены и пожелания со старого имени на новое
  Future<void> _migrateEmployeeData(String oldName, String newName) async {
    // Смены
    final shiftsSnap = await _db.collection('schedule_shifts_v2').get();
    for (var doc in shiftsSnap.docs) {
      final data = doc.data();
      if (data.containsKey(oldName)) {
        await doc.reference.update({
          newName: data[oldName],
          oldName: FieldValue.delete(),
        });
      }
    }
    // Пожелания
    final prefsSnap = await _db.collection('schedule_prefs_v2').get();
    for (var doc in prefsSnap.docs) {
      final data = doc.data();
      if (data.containsKey(oldName)) {
        await doc.reference.update({
          newName: data[oldName],
          oldName: FieldValue.delete(),
        });
      }
    }
  }

  Future<void> _logAction(String text) async {
    final timeStr = DateFormat('HH:mm').format(DateTime.now());
    await _db.collection('logs_v2').add({
      'text': '$timeStr - $text',
      'time': FieldValue.serverTimestamp(),
    });
  }

  String _dateKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> toggleShift(String barista, DateTime date) async {
    // ЗАЩИТА: Если не админ, функция прерывается
    if (!isAdmin) return;

    String key = _dateKey(date);
    ShiftType current = shifts[barista]?[key] ?? ShiftType.none;
    ShiftType next = ShiftType.none;
    String actionName = '';

    switch (current) {
      case ShiftType.none:
        next = ShiftType.full;
        actionName = 'Полная смена';
        break;
      case ShiftType.full:
        next = ShiftType.morning;
        actionName = 'Утро';
        break;
      case ShiftType.morning:
        next = ShiftType.evening;
        actionName = 'Вечер';
        break;
      case ShiftType.evening:
        next = ShiftType.none;
        actionName = 'Снята смена';
        break;
    }

    if (!shifts.containsKey(barista)) shifts[barista] = {};
    shifts[barista]![key] = next;
    lastError = null;
    notifyListeners();

    try {
      await _db.collection('schedule_shifts_v2').doc(key).set({
        barista: next.index
      }, SetOptions(merge: true));

      final timeStr = DateFormat('HH:mm').format(DateTime.now());
      final dateStr = DateFormat('dd.MM').format(date);
      await _db.collection('logs_v2').add({
        'text': '$timeStr - $barista: $actionName на $dateStr',
        'time': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      lastError = "Ошибка доступа Firebase: проверьте правила (Test Mode).";
      notifyListeners();
    }
  }

  Future<void> togglePref(String barista, DateTime date) async {
    String key = _dateKey(date);
    PrefType current = prefs[barista]?[key] ?? PrefType.none;
    PrefType next = PrefType.none;

    switch (current) {
      case PrefType.none:
        next = PrefType.ready;
        break;
      case PrefType.ready:
        next = PrefType.readyAfter15;
        break;
      case PrefType.readyAfter15:
        next = PrefType.readyBefore15;
        break;
      case PrefType.readyBefore15:
        next = PrefType.notReady;
        break;
      case PrefType.notReady:
        next = PrefType.none;
        break;
    }

    if (!prefs.containsKey(barista)) prefs[barista] = {};
    prefs[barista]![key] = next;
    lastError = null;
    notifyListeners();

    try {
      await _db.collection('schedule_prefs_v2').doc(key).set({
        barista: next.index
      }, SetOptions(merge: true));
    } catch (e) {
      lastError = "Ошибка доступа Firebase: проверьте правила (Test Mode).";
      notifyListeners();
    }
  }

  ShiftType getShift(String barista, DateTime date) {
    return shifts[barista]?[_dateKey(date)] ?? ShiftType.none;
  }

  PrefType getPref(String barista, DateTime date) {
    return prefs[barista]?[_dateKey(date)] ?? PrefType.none;
  }

  double getHoursForMonth(String barista, DateTime month) {
    if (!shifts.containsKey(barista)) return 0;
    double totalHours = 0;
    shifts[barista]!.forEach((dateStr, type) {
      DateTime d = DateTime.parse(dateStr);
      if (d.month == month.month && d.year == month.year) {
        if (type == ShiftType.full) totalHours += 10;
        if (type == ShiftType.morning || type == ShiftType.evening) totalHours += 5;
      }
    });
    return totalHours;
  }

  /// Часы за конкретный диапазон дней (учитывает 28/29/30/31)
  double getHoursForPeriod(String barista, DateTime month, int fromDay, int toDay) {
    if (!shifts.containsKey(barista)) return 0;
    double total = 0;
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final end = toDay > lastDay ? lastDay : toDay;
    shifts[barista]!.forEach((dateStr, type) {
      final d = DateTime.parse(dateStr);
      if (d.month == month.month && d.year == month.year &&
          d.day >= fromDay && d.day <= end) {
        if (type == ShiftType.full) total += 10;
        if (type == ShiftType.morning || type == ShiftType.evening) total += 5;
      }
    });
    return total;
  }

  int getFullShiftsCount(String barista, DateTime month) {
    if (!shifts.containsKey(barista)) return 0;
    int count = 0;
    shifts[barista]!.forEach((dateStr, type) {
      DateTime d = DateTime.parse(dateStr);
      if (d.month == month.month && d.year == month.year && type == ShiftType.full) {
        count++;
      }
    });
    return count;
  }
}

class MockApp extends StatelessWidget {
  const MockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppStateProvider(
      state: globalAppState,
      child: MaterialApp(
        title: 'Ю Кофе',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4E342E)),
          scaffoldBackgroundColor: const Color(0xFFFFF8E1),
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            backgroundColor: Color(0xFF4E342E),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
        // ИЗМЕНЕНО: Стартовый экран теперь Экран Входа
        home: const LoginScreen(),
      ),
    );
  }
}

class AppStateProvider extends InheritedNotifier<AppState> {
  const AppStateProvider({
    super.key,
    required AppState state,
    required Widget child,
  }) : super(notifier: state, child: child);

  static AppState of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppStateProvider>()!.notifier!;
  }
}

// ==========================================
// НОВЫЙ ЭКРАН: Вход и Выбор Роли
// ==========================================

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF4E342E),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.coffee, size: 80, color: Color(0xFFFFF8E1)),
              const SizedBox(height: 20),
              const Text('Ю КОФЕ', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 2)),
              const SizedBox(height: 10),
              const Text('Система управления', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 60),
              
              // Бариста — вход без авторизации (только чтение графика + пожелания)
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.person),
                  label: const Text('Войти как Бариста', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFF8E1), foregroundColor: const Color(0xFF4E342E)),
                  onPressed: () {
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScreen()));
                  },
                ),
              ),
              const SizedBox(height: 16),
              
              // Админ — вход через Firebase Auth
              SizedBox(
                width: double.infinity,
                height: 55,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.admin_panel_settings),
                  label: const Text('Управляющий', style: TextStyle(fontSize: 16)),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
                  onPressed: () => _showPinDialog(context, state),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPinDialog(BuildContext context, AppState state) {
    final ctrl = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Ввод PIN-кода'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            enabled: !isLoading,
            decoration: const InputDecoration(labelText: 'PIN', hintText: 'Введите пин-код'),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx),
              child: const Text('Отмена', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4E342E), foregroundColor: Colors.white),
              onPressed: isLoading ? null : () async {
                setDialogState(() => isLoading = true);
                
                // Пароль проверяется сервером Firebase — не хранится в коде
                final error = await state.signInAdmin(ctrl.text);
                
                if (error == null) {
                  Navigator.pop(ctx);
                  Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScreen()));
                } else {
                  setDialogState(() => isLoading = false);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                }
              },
              child: isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Войти'),
            ),
          ],
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final screens = const [
    ScheduleScreen(),
    ReportScreen(),
    PreferencesScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);
    return Scaffold(
      appBar: state.isAdmin
          ? AppBar(
              title: const Text('Ю Кофе — Админ'),
              backgroundColor: Colors.red.shade700,
              actions: [
                IconButton(
                  icon: const Icon(Icons.people),
                  tooltip: 'Сотрудники',
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ManageEmployeesScreen())),
                ),
                IconButton(
                  icon: const Icon(Icons.logout),
                  tooltip: 'Выйти',
                  onPressed: () async {
                    await state.signOut();
                    if (context.mounted) {
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                    }
                  },
                ),
              ],
            )
          : null,
      body: SafeArea(child: screens[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        selectedItemColor: const Color(0xFF4E342E),
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFFFFF8E1),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'График'),
          BottomNavigationBarItem(icon: Icon(Icons.analytics), label: 'Итоги'),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: 'Пожелания'),
        ],
      ),
    );
  }
}

class CalendarUtils {
  static List<DateTime> getDaysInWeek(DateTime month, int weekIndex) {
    int startDay = weekIndex * 7 + 1;
    int endDay = startDay + 6;
    int lastDayOfMonth = DateTime(month.year, month.month + 1, 0).day;
    if (endDay > lastDayOfMonth) endDay = lastDayOfMonth;
    if (startDay > lastDayOfMonth) return [];
    List<DateTime> days = [];
    for (int i = startDay; i <= endDay; i++) {
      days.add(DateTime(month.year, month.month, i));
    }
    return days;
  }
}

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  int _selectedWeek = 0;

  void _nextMonth() => setState(() {
        _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1);
        _selectedWeek = 0;
      });

  void _prevMonth() => setState(() {
        _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1);
        _selectedWeek = 0;
      });

  void _setWeek(int index) => setState(() => _selectedWeek = index);

  void _safeToggleShift(AppState state, String barista, DateTime date) {
    try {
      state.toggleShift(barista, date);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Критическая ошибка: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);
    final daysToRender = CalendarUtils.getDaysInWeek(_selectedMonth, _selectedWeek);
    final monthName = DateFormat('LLLL yyyy', 'ru_RU').format(_selectedMonth);

    return Column(
      children: [
        // --- ПЛАШКА АДМИНА ---
        if (state.isAdmin)
          Container(
            width: double.infinity,
            color: Colors.red.shade100,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: const Text('Вы в режиме редактирования графика (Админ)', textAlign: TextAlign.center, style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
          ),

        if (state.lastError != null)
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.red.shade100,
            width: double.infinity,
            child: Text(
              state.lastError!,
              style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
        Container(
          color: Colors.brown.shade50,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(icon: const Icon(Icons.chevron_left), onPressed: _prevMonth, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                  Text(monthName.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  IconButton(icon: const Icon(Icons.chevron_right), onPressed: _nextMonth, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: List.generate(5, (index) {
                  if (CalendarUtils.getDaysInWeek(_selectedMonth, index).isEmpty) return const SizedBox();
                  bool isSelected = _selectedWeek == index;
                  return ChoiceChip(
                    label: Text('Н. ${index + 1}', style: const TextStyle(fontSize: 12)),
                    selected: isSelected,
                    onSelected: (_) => _setWeek(index),
                    selectedColor: Colors.brown.shade200,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                  );
                }),
              )
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              _legendDot(Colors.green.shade400, 'Полная (10ч)'),
              _legendDot(Colors.yellow.shade400, 'Утро (5ч)'),
              _legendDot(Colors.purple.shade300, 'Вечер (5ч)'),
            ],
          ),
        ),
        Expanded(
          flex: 5,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SingleChildScrollView(
              child: Table(
                defaultColumnWidth: const FixedColumnWidth(50.0),
                columnWidths: const {0: FixedColumnWidth(85.0)},
                border: TableBorder.all(color: Colors.brown.shade200, borderRadius: BorderRadius.circular(4)),
                children: [
                  TableRow(
                    decoration: BoxDecoration(color: Colors.brown.shade100),
                    children: [
                      const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 12.0), child: Text('Бариста', style: TextStyle(fontSize: 12)))),
                      ...daysToRender.map((d) => Center(child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Text(DateFormat('EE\ndd', 'ru_RU').format(d), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      )))
                    ],
                  ),
                  ...state.baristas.map((barista) {
                    return TableRow(
                      children: [
                        InkWell(
                          onTap: () => _showEmployeeStats(context, state, barista),
                          child: Container(
                            height: 55,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(left: 6.0),
                            child: Text(barista, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline, color: Color(0xFF4E342E))),
                          ),
                        ),
                        ...daysToRender.map((date) {
                          ShiftType type = state.getShift(barista, date);
                          Color cellColor;
                          switch (type) {
                            case ShiftType.full:
                              cellColor = Colors.green.shade400;
                              break;
                            case ShiftType.morning:
                              cellColor = Colors.yellow.shade400;
                              break;
                            case ShiftType.evening:
                              cellColor = Colors.purple.shade300;
                              break;
                            case ShiftType.none:
                              cellColor = Colors.transparent;
                              break;
                          }
                          return InkWell(
                            // ЗАЩИТА UI: Клик работает только если Админ
                            onTap: state.isAdmin ? () => _safeToggleShift(state, barista, date) : () {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Только администратор может изменять график'), duration: Duration(seconds: 2)));
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 55,
                              margin: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: cellColor,
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          );
                        })
                      ],
                    );
                  })
                ],
              ),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -5))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF4E342E),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: const Text('История изменений (Livestream)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                Expanded(
                  child: state.auditLogs.isEmpty
                      ? const Center(child: Text('Изменений пока нет', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)))
                      : ListView.separated(
                          itemCount: state.auditLogs.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
                          itemBuilder: (context, i) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                              child: Text(state.auditLogs[i], style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                            );
                          },
                        ),
                )
              ],
            ),
          ),
        )
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }

  void _showEmployeeStats(BuildContext context, AppState state, String barista) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)), margin: const EdgeInsets.only(bottom: 20)),
                    Text('Профиль: $barista', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setModalState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1))),
                        Text(DateFormat('LLLL yyyy', 'ru_RU').format(_selectedMonth).toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setModalState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1))),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: _statCard('Полных\nсмен', state.getFullShiftsCount(barista, _selectedMonth).toString(), Colors.green.shade100)),
                        const SizedBox(width: 16),
                        Expanded(child: _statCard('Всего\nчасов', state.getHoursForMonth(barista, _selectedMonth).toStringAsFixed(0), Colors.brown.shade100)),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, height: 1.2)),
        ],
      ),
    );
  }
}

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  DateTime _reportMonth = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);
    final monthName = DateFormat('LLLL yyyy', 'ru_RU').format(_reportMonth);
    final lastDay = DateTime(_reportMonth.year, _reportMonth.month + 1, 0).day;

    return Scaffold(
      appBar: AppBar(title: const Text('Итоги за месяц')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.brown.shade50,
              border: Border(bottom: BorderSide(color: Colors.brown.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _reportMonth = DateTime(_reportMonth.year, _reportMonth.month - 1))),
                Text(monthName.toUpperCase(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => _reportMonth = DateTime(_reportMonth.year, _reportMonth.month + 1))),
              ],
            ),
          ),
          // Заголовки периодов
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.brown.shade50,
            child: Row(
              children: [
                const SizedBox(width: 56), // Отступ под аватар
                const Expanded(flex: 3, child: SizedBox()),
                Expanded(flex: 2, child: Text('1–15', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.brown.shade700))),
                Expanded(flex: 2, child: Text('16–$lastDay', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.brown.shade700))),
                Expanded(flex: 2, child: Text('Итого', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.brown.shade900))),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: state.baristas.length,
              itemBuilder: (context, i) {
                String barista = state.baristas[i];
                double firstHalf = state.getHoursForPeriod(barista, _reportMonth, 1, 15);
                double secondHalf = state.getHoursForPeriod(barista, _reportMonth, 16, lastDay);
                double total = firstHalf + secondHalf;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    child: Row(
                      children: [
                        CircleAvatar(backgroundColor: Colors.brown.shade200, radius: 20, child: Text(barista[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                        const SizedBox(width: 10),
                        Expanded(flex: 3, child: Text(barista, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                        Expanded(flex: 2, child: Text('${firstHalf.toStringAsFixed(0)} ч.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.brown.shade600, fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text('${secondHalf.toStringAsFixed(0)} ч.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.brown.shade600, fontWeight: FontWeight.w600))),
                        Expanded(flex: 2, child: Text('${total.toStringAsFixed(0)} ч.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Color(0xFF4E342E), fontWeight: FontWeight.w900))),
                      ],
                    ),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }
}

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  String? _selectedBarista;
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  int _selectedWeek = 0;

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);
    _selectedBarista ??= state.baristas.first;
    final daysToRender = CalendarUtils.getDaysInWeek(_selectedMonth, _selectedWeek);
    final monthName = DateFormat('LLLL yyyy', 'ru_RU').format(_selectedMonth);

    return Scaffold(
      appBar: AppBar(title: const Text('Мои пожелания')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.white,
            child: DropdownButtonFormField<String>(
              decoration: InputDecoration(
                labelText: 'Ваш профиль',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              value: _selectedBarista,
              items: state.baristas
                  .map((b) => DropdownMenuItem(value: b, child: Text(b, style: const TextStyle(fontWeight: FontWeight.bold))))
                  .toList(),
              onChanged: (val) => setState(() => _selectedBarista = val),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.brown.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1))),
                Text(monthName.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1))),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.only(bottom: 8),
            color: Colors.brown.shade50,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: List.generate(5, (index) {
                if (CalendarUtils.getDaysInWeek(_selectedMonth, index).isEmpty) return const SizedBox();
                return ChoiceChip(
                  label: Text('Н. ${index + 1}', style: const TextStyle(fontSize: 12)),
                  selected: _selectedWeek == index,
                  selectedColor: Colors.brown.shade200,
                  onSelected: (_) => setState(() => _selectedWeek = index),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              _prefLegend(Colors.green.shade200, "Весь день"),
              _prefLegend(Colors.orange.shade200, "С 15:00"),
              _prefLegend(Colors.yellow.shade200, "До 15:00"),
              _prefLegend(Colors.red.shade200, "Не могу"),
            ],
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: daysToRender.length,
              itemBuilder: (context, i) {
                final date = daysToRender[i];
                PrefType type = state.getPref(_selectedBarista!, date);

                Color bg;
                String statusText;
                switch (type) {
                  case PrefType.ready:
                    bg = Colors.green.shade200;
                    statusText = "Готов работать";
                    break;
                  case PrefType.readyAfter15:
                    bg = Colors.orange.shade200;
                    statusText = "Готов с 15:00";
                    break;
                  case PrefType.readyBefore15:
                    bg = Colors.yellow.shade200;
                    statusText = "Готов до 15:00";
                    break;
                  case PrefType.notReady:
                    bg = Colors.red.shade200;
                    statusText = "Не могу";
                    break;
                  case PrefType.none:
                    bg = Colors.white;
                    statusText = "Не выбрано";
                    break;
                }

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: type == PrefType.none ? BorderSide(color: Colors.grey.shade300) : BorderSide.none,
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      try {
                        // Оставлять пожелания могут все (и бариста, и админ)
                        await state.togglePref(_selectedBarista!, date);
                      } catch (e) {}
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: ListTile(
                        title: Text(DateFormat('EEEE, dd MMMM', 'ru_RU').format(date), style: const TextStyle(fontSize: 14)),
                        trailing: Text(statusText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }

  Widget _prefLegend(Color c, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 14, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 11))
      ],
    );
  }
}

// ==========================================
// Экран управления сотрудниками (только Админ)
// ==========================================

class ManageEmployeesScreen extends StatelessWidget {
  const ManageEmployeesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateProvider.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Сотрудники'),
        backgroundColor: Colors.red.shade700,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF4E342E),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Добавить'),
        onPressed: () => _showAddDialog(context, state),
      ),
      body: state.baristas.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: state.baristas.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final name = state.baristas[i];
                return Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: Colors.brown.shade200,
                      child: Text(name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.edit, color: Colors.brown.shade400),
                          tooltip: 'Переименовать',
                          onPressed: () => _showRenameDialog(context, state, name),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                          tooltip: 'Удалить',
                          onPressed: () => _showDeleteDialog(context, state, name),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _showAddDialog(BuildContext context, AppState state) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый сотрудник'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Имя', hintText: 'Введите имя сотрудника'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4E342E), foregroundColor: Colors.white),
            onPressed: () async {
              final error = await state.addBarista(ctrl.text);
              if (error == null) {
                Navigator.pop(ctx);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
              }
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, AppState state, String oldName) {
    final ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'Новое имя', hintText: oldName),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4E342E), foregroundColor: Colors.white),
            onPressed: () async {
              final error = await state.renameBarista(oldName, ctrl.text);
              if (error == null) {
                Navigator.pop(ctx);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, AppState state, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сотрудника?'),
        content: Text('Удалить "$name" из списка? Данные смен сотрудника сохранятся в базе.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              final error = await state.removeBarista(name);
              Navigator.pop(ctx);
              if (error != null) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
              }
            },
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}
