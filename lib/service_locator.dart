import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:get_it/get_it.dart';

import 'services/admin_service.dart';
import 'services/admin_user_service.dart';
import 'services/analytics_service.dart';
import 'services/bus_service_repository.dart';
import 'services/settings_service.dart';
import 'services/station_repository.dart';

final GetIt sl = GetIt.instance;

/// Registers all app-wide singletons.
/// Call once in main() before runApp().
void setupServiceLocator({
  FirebaseFirestore? firestore,
  FirebaseAuth? auth,
  SettingsService? settingsService,
}) {
  sl.registerLazySingleton<FirebaseFirestore>(
    () => firestore ?? FirebaseFirestore.instance,
  );
  sl.registerLazySingleton<FirebaseAuth>(
    () => auth ?? FirebaseAuth.instance,
  );
  sl.registerLazySingleton<AnalyticsService>(
    () => AnalyticsService.instance,
  );
  sl.registerLazySingleton<BusServiceRepository>(
    () => BusServiceRepository(sl<FirebaseFirestore>()),
  );
  sl.registerLazySingleton<StationRepository>(
    () => StationRepository(sl<FirebaseFirestore>()),
  );
  sl.registerLazySingleton<AdminService>(
    () => AdminService(
      firestore: sl<FirebaseFirestore>(),
      auth: sl<FirebaseAuth>(),
    ),
  );
  sl.registerLazySingleton<AdminUserService>(
    () => AdminUserService(
      firestore: sl<FirebaseFirestore>(),
      auth: sl<FirebaseAuth>(),
    ),
  );
  if (settingsService != null) {
    sl.registerSingleton<SettingsService>(settingsService);
  }
}
