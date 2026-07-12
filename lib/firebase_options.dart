import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      default:
        throw UnsupportedError('DefaultFirebaseOptions are not supported for this platform.');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyC0rFOiAx5LEpT-6s9Bc8sxNtc59RfsOcM",
    authDomain: "u-coffee.firebaseapp.com",
    projectId: "u-coffee",
    storageBucket: "u-coffee.firebasestorage.app",
    messagingSenderId: "971000964907",
    appId: "1:971000964907:web:b1e9271ca53fbfff6ac76e",
    measurementId: "G-M5HM5H2D75",
    databaseURL: "https://u-coffee-default-rtdb.firebaseio.com",
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: "YOUR_ANDROID_API_KEY",
    appId: "YOUR_ANDROID_APP_ID",
    messagingSenderId: "971000964907",
    projectId: "u-coffee",
    storageBucket: "u-coffee.firebasestorage.app",
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: "YOUR_IOS_API_KEY",
    appId: "YOUR_IOS_APP_ID",
    messagingSenderId: "971000964907",
    projectId: "u-coffee",
    storageBucket: "u-coffee.firebasestorage.app",
    iosBundleId: "com.example.uCoffee",
  );

  static const FirebaseOptions macos = ios;
  static const FirebaseOptions windows = web;
  static const FirebaseOptions linux = web;
}
