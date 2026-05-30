import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
    Locale('fr')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'TuniTransport'**
  String get appTitle;

  /// No description provided for @splashSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your smart transport assistant'**
  String get splashSubtitle;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get register;

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @favorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favorites;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// No description provided for @journeys.
  ///
  /// In en, this message translates to:
  /// **'Journeys'**
  String get journeys;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @messages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get messages;

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @loginAsAdmin.
  ///
  /// In en, this message translates to:
  /// **'Login as Admin'**
  String get loginAsAdmin;

  /// No description provided for @adminLogin.
  ///
  /// In en, this message translates to:
  /// **'Admin Login'**
  String get adminLogin;

  /// No description provided for @adminDashboard.
  ///
  /// In en, this message translates to:
  /// **'Admin Dashboard'**
  String get adminDashboard;

  /// No description provided for @administratorAccess.
  ///
  /// In en, this message translates to:
  /// **'Administrator Access'**
  String get administratorAccess;

  /// No description provided for @matricule.
  ///
  /// In en, this message translates to:
  /// **'Matricule'**
  String get matricule;

  /// No description provided for @role.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get role;

  /// No description provided for @backToUserLogin.
  ///
  /// In en, this message translates to:
  /// **'Back to User Login'**
  String get backToUserLogin;

  /// No description provided for @manageUsers.
  ///
  /// In en, this message translates to:
  /// **'Manage Users'**
  String get manageUsers;

  /// No description provided for @manageJourneys.
  ///
  /// In en, this message translates to:
  /// **'Manage Journeys'**
  String get manageJourneys;

  /// No description provided for @manageStations.
  ///
  /// In en, this message translates to:
  /// **'Manage Stations'**
  String get manageStations;

  /// No description provided for @manageTariffs.
  ///
  /// In en, this message translates to:
  /// **'Manage Tariffs'**
  String get manageTariffs;

  /// No description provided for @manageAdminRolesPermissions.
  ///
  /// In en, this message translates to:
  /// **'Manage Roles and Permissions'**
  String get manageAdminRolesPermissions;

  /// No description provided for @globalPlatformSupervision.
  ///
  /// In en, this message translates to:
  /// **'Global Supervision'**
  String get globalPlatformSupervision;

  /// No description provided for @addRoute.
  ///
  /// In en, this message translates to:
  /// **'Add Route'**
  String get addRoute;

  /// No description provided for @editRoute.
  ///
  /// In en, this message translates to:
  /// **'Edit Route'**
  String get editRoute;

  /// No description provided for @routeAdded.
  ///
  /// In en, this message translates to:
  /// **'Route added successfully'**
  String get routeAdded;

  /// No description provided for @routeUpdated.
  ///
  /// In en, this message translates to:
  /// **'Route updated'**
  String get routeUpdated;

  /// No description provided for @addTariff.
  ///
  /// In en, this message translates to:
  /// **'Add Tariff'**
  String get addTariff;

  /// No description provided for @editTariff.
  ///
  /// In en, this message translates to:
  /// **'Edit Tariff'**
  String get editTariff;

  /// No description provided for @tariffUpdated.
  ///
  /// In en, this message translates to:
  /// **'Tariff updated. The new price is visible to users.'**
  String get tariffUpdated;

  /// No description provided for @adminBus.
  ///
  /// In en, this message translates to:
  /// **'Admin Bus'**
  String get adminBus;

  /// No description provided for @adminMetroTrain.
  ///
  /// In en, this message translates to:
  /// **'Admin Metro / Train'**
  String get adminMetroTrain;

  /// No description provided for @adminTaxiCollectifs.
  ///
  /// In en, this message translates to:
  /// **'Admin Taxi Collectifs'**
  String get adminTaxiCollectifs;

  /// No description provided for @adminLouage.
  ///
  /// In en, this message translates to:
  /// **'Admin Louage'**
  String get adminLouage;

  /// No description provided for @accessDenied.
  ///
  /// In en, this message translates to:
  /// **'Access denied'**
  String get accessDenied;

  /// No description provided for @confirmDelete.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete?'**
  String get confirmDelete;

  /// No description provided for @rolesTab.
  ///
  /// In en, this message translates to:
  /// **'Roles Management'**
  String get rolesTab;

  /// No description provided for @supervisionTab.
  ///
  /// In en, this message translates to:
  /// **'Supervision'**
  String get supervisionTab;

  /// No description provided for @totalRoutes.
  ///
  /// In en, this message translates to:
  /// **'Total routes'**
  String get totalRoutes;

  /// No description provided for @activeRoutes.
  ///
  /// In en, this message translates to:
  /// **'Active routes'**
  String get activeRoutes;

  /// No description provided for @totalUsers.
  ///
  /// In en, this message translates to:
  /// **'Total users'**
  String get totalUsers;

  /// No description provided for @totalAdmins.
  ///
  /// In en, this message translates to:
  /// **'Total admins'**
  String get totalAdmins;

  /// No description provided for @switchToUserMode.
  ///
  /// In en, this message translates to:
  /// **'Switch to user mode'**
  String get switchToUserMode;

  /// No description provided for @manageAdmins.
  ///
  /// In en, this message translates to:
  /// **'Manage Admins'**
  String get manageAdmins;

  /// No description provided for @promoteToAdmin.
  ///
  /// In en, this message translates to:
  /// **'Promote to Admin'**
  String get promoteToAdmin;

  /// No description provided for @revokeAdminAccess.
  ///
  /// In en, this message translates to:
  /// **'Revoke Admin Access'**
  String get revokeAdminAccess;

  /// No description provided for @activateAdminAccount.
  ///
  /// In en, this message translates to:
  /// **'Activate'**
  String get activateAdminAccount;

  /// No description provided for @deactivateAdminAccount.
  ///
  /// In en, this message translates to:
  /// **'Deactivate'**
  String get deactivateAdminAccount;

  /// No description provided for @adminTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Admin Type'**
  String get adminTypeLabel;

  /// No description provided for @adminPermissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get adminPermissions;

  /// No description provided for @searchAdminByEmail.
  ///
  /// In en, this message translates to:
  /// **'Search user by email to promote…'**
  String get searchAdminByEmail;

  /// No description provided for @adminPromotedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Admin promoted successfully.'**
  String get adminPromotedSuccess;

  /// No description provided for @adminRevokedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Admin access revoked.'**
  String get adminRevokedSuccess;

  /// No description provided for @adminActivatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Admin activated.'**
  String get adminActivatedSuccess;

  /// No description provided for @adminDeactivatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Admin deactivated.'**
  String get adminDeactivatedSuccess;

  /// No description provided for @adminsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load admins.'**
  String get adminsLoadError;

  /// No description provided for @noAdminsFound.
  ///
  /// In en, this message translates to:
  /// **'No admins found.'**
  String get noAdminsFound;

  /// No description provided for @confirmRevokeAdmin.
  ///
  /// In en, this message translates to:
  /// **'Revoke admin access for this user? They will revert to a regular user.'**
  String get confirmRevokeAdmin;

  /// No description provided for @overviewTab.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overviewTab;

  /// No description provided for @adminManagementTab.
  ///
  /// In en, this message translates to:
  /// **'Admin Management'**
  String get adminManagementTab;

  /// No description provided for @platformSupervisionTab.
  ///
  /// In en, this message translates to:
  /// **'Platform'**
  String get platformSupervisionTab;

  /// No description provided for @activityLogs.
  ///
  /// In en, this message translates to:
  /// **'Activity Logs'**
  String get activityLogs;

  /// No description provided for @systemStats.
  ///
  /// In en, this message translates to:
  /// **'System Stats'**
  String get systemStats;

  /// No description provided for @noActivityLogs.
  ///
  /// In en, this message translates to:
  /// **'No activity logs yet.'**
  String get noActivityLogs;

  /// No description provided for @operationFailed.
  ///
  /// In en, this message translates to:
  /// **'Operation failed.'**
  String get operationFailed;

  /// No description provided for @editRolesPermissions.
  ///
  /// In en, this message translates to:
  /// **'Edit type & permissions'**
  String get editRolesPermissions;

  /// No description provided for @permBus.
  ///
  /// In en, this message translates to:
  /// **'Bus (TRANSTU)'**
  String get permBus;

  /// No description provided for @permMetroTrain.
  ///
  /// In en, this message translates to:
  /// **'Métro / Train'**
  String get permMetroTrain;

  /// No description provided for @permTaxi.
  ///
  /// In en, this message translates to:
  /// **'Taxi Collectifs'**
  String get permTaxi;

  /// No description provided for @permLouage.
  ///
  /// In en, this message translates to:
  /// **'Louage'**
  String get permLouage;

  /// No description provided for @permNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get permNotifications;

  /// No description provided for @permReports.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get permReports;

  /// No description provided for @permUsersModeration.
  ///
  /// In en, this message translates to:
  /// **'Users / Moderation'**
  String get permUsersModeration;

  /// No description provided for @sendNotifications.
  ///
  /// In en, this message translates to:
  /// **'Send Notifications'**
  String get sendNotifications;

  /// No description provided for @connectedRole.
  ///
  /// In en, this message translates to:
  /// **'Connected role: {role}'**
  String connectedRole(Object role);

  /// No description provided for @invalidAdminCredentials.
  ///
  /// In en, this message translates to:
  /// **'Invalid matricule or password.'**
  String get invalidAdminCredentials;

  /// No description provided for @requiredField.
  ///
  /// In en, this message translates to:
  /// **'This field is required.'**
  String get requiredField;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @themeMode.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get themeMode;

  /// No description provided for @lightMode.
  ///
  /// In en, this message translates to:
  /// **'Light mode'**
  String get lightMode;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark mode'**
  String get darkMode;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get systemDefault;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @french.
  ///
  /// In en, this message translates to:
  /// **'Français'**
  String get french;

  /// No description provided for @arabic.
  ///
  /// In en, this message translates to:
  /// **'العربية'**
  String get arabic;

  /// No description provided for @savedJourneys.
  ///
  /// In en, this message translates to:
  /// **'Your saved journeys'**
  String get savedJourneys;

  /// No description provided for @planJourney.
  ///
  /// In en, this message translates to:
  /// **'Plan your journey'**
  String get planJourney;

  /// No description provided for @findBestOptions.
  ///
  /// In en, this message translates to:
  /// **'Find the best options'**
  String get findBestOptions;

  /// No description provided for @departurePoint.
  ///
  /// In en, this message translates to:
  /// **'Departure point'**
  String get departurePoint;

  /// No description provided for @arrivalPoint.
  ///
  /// In en, this message translates to:
  /// **'Arrival point'**
  String get arrivalPoint;

  /// No description provided for @currentLocation.
  ///
  /// In en, this message translates to:
  /// **'Current location'**
  String get currentLocation;

  /// No description provided for @useMyGpsPosition.
  ///
  /// In en, this message translates to:
  /// **'Use my GPS position'**
  String get useMyGpsPosition;

  /// No description provided for @fetchingLocation.
  ///
  /// In en, this message translates to:
  /// **'Getting your location...'**
  String get fetchingLocation;

  /// No description provided for @locationServiceDisabled.
  ///
  /// In en, this message translates to:
  /// **'Location service is disabled.'**
  String get locationServiceDisabled;

  /// No description provided for @locationPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Location permission denied.'**
  String get locationPermissionDenied;

  /// No description provided for @unableGetGps.
  ///
  /// In en, this message translates to:
  /// **'Unable to get your GPS position.'**
  String get unableGetGps;

  /// No description provided for @fillAllFields.
  ///
  /// In en, this message translates to:
  /// **'Please fill in all fields'**
  String get fillAllFields;

  /// No description provided for @searchJourney.
  ///
  /// In en, this message translates to:
  /// **'Search journey'**
  String get searchJourney;

  /// No description provided for @recentJourneys.
  ///
  /// In en, this message translates to:
  /// **'Recent journeys'**
  String get recentJourneys;

  /// No description provided for @community.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get community;

  /// No description provided for @publicDiscussion.
  ///
  /// In en, this message translates to:
  /// **'Public discussion'**
  String get publicDiscussion;

  /// No description provided for @writeMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Write a message...'**
  String get writeMessageHint;

  /// No description provided for @signInToParticipate.
  ///
  /// In en, this message translates to:
  /// **'Sign in to participate'**
  String get signInToParticipate;

  /// No description provided for @unableSendMessage.
  ///
  /// In en, this message translates to:
  /// **'Unable to send message.'**
  String get unableSendMessage;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @messagesLoadError.
  ///
  /// In en, this message translates to:
  /// **'Error loading messages'**
  String get messagesLoadError;

  /// No description provided for @beFirstToWrite.
  ///
  /// In en, this message translates to:
  /// **'Be the first to write!'**
  String get beFirstToWrite;

  /// No description provided for @replyToUser.
  ///
  /// In en, this message translates to:
  /// **'Reply to {username}'**
  String replyToUser(Object username);

  /// No description provided for @cancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get cancelReply;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @firstName.
  ///
  /// In en, this message translates to:
  /// **'First name'**
  String get firstName;

  /// No description provided for @lastName.
  ///
  /// In en, this message translates to:
  /// **'Last name'**
  String get lastName;

  /// No description provided for @city.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get city;

  /// No description provided for @addCity.
  ///
  /// In en, this message translates to:
  /// **'Add a city'**
  String get addCity;

  /// No description provided for @changePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get changePassword;

  /// No description provided for @currentPassword.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get currentPassword;

  /// No description provided for @newPassword.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get newPassword;

  /// No description provided for @confirmNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get confirmNewPassword;

  /// No description provided for @enterCurrentPassword.
  ///
  /// In en, this message translates to:
  /// **'Please enter your current password'**
  String get enterCurrentPassword;

  /// No description provided for @enterNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Please enter the new password'**
  String get enterNewPassword;

  /// No description provided for @confirmNewPasswordPrompt.
  ///
  /// In en, this message translates to:
  /// **'Please confirm the new password'**
  String get confirmNewPasswordPrompt;

  /// No description provided for @passwordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

  /// No description provided for @passwordMinLength.
  ///
  /// In en, this message translates to:
  /// **'Password must contain at least 6 characters'**
  String get passwordMinLength;

  /// No description provided for @passwordChangedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Password changed successfully'**
  String get passwordChangedSuccessfully;

  /// No description provided for @chooseAvatar.
  ///
  /// In en, this message translates to:
  /// **'Choose an avatar'**
  String get chooseAvatar;

  /// No description provided for @uploadCustomAvatar.
  ///
  /// In en, this message translates to:
  /// **'Upload custom avatar'**
  String get uploadCustomAvatar;

  /// No description provided for @predefinedAvatars.
  ///
  /// In en, this message translates to:
  /// **'Predefined avatars'**
  String get predefinedAvatars;

  /// No description provided for @avatarUpdated.
  ///
  /// In en, this message translates to:
  /// **'Avatar updated'**
  String get avatarUpdated;

  /// No description provided for @avatarUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update avatar'**
  String get avatarUpdateFailed;

  /// No description provided for @confirmSignOut.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?'**
  String get confirmSignOut;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @profileUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Profile updated successfully'**
  String get profileUpdatedSuccessfully;

  /// No description provided for @profileUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update profile'**
  String get profileUpdateFailed;

  /// No description provided for @noFavoriteJourneysYet.
  ///
  /// In en, this message translates to:
  /// **'No favorite journeys yet'**
  String get noFavoriteJourneysYet;

  /// No description provided for @noNotificationsYet.
  ///
  /// In en, this message translates to:
  /// **'No notifications yet'**
  String get noNotificationsYet;

  /// No description provided for @markAllAsRead.
  ///
  /// In en, this message translates to:
  /// **'Mark all as read'**
  String get markAllAsRead;

  /// No description provided for @unreadCountLabel.
  ///
  /// In en, this message translates to:
  /// **'{count} unread'**
  String unreadCountLabel(int count);

  /// No description provided for @newNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'New notification'**
  String get newNotificationTitle;

  /// No description provided for @receivedNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'You received a notification'**
  String get receivedNotificationBody;

  /// No description provided for @newMessageNotification.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get newMessageNotification;

  /// No description provided for @newJourneyNotification.
  ///
  /// In en, this message translates to:
  /// **'New journey created'**
  String get newJourneyNotification;

  /// No description provided for @systemAnnouncementTitle.
  ///
  /// In en, this message translates to:
  /// **'System announcement'**
  String get systemAnnouncementTitle;

  /// No description provided for @systemWelcomeBody.
  ///
  /// In en, this message translates to:
  /// **'Welcome to TuniTranspo. Enjoy your trip!'**
  String get systemWelcomeBody;

  /// No description provided for @featureReadyToBeConnected.
  ///
  /// In en, this message translates to:
  /// **'{feature} feature is ready to be connected.'**
  String featureReadyToBeConnected(Object feature);

  /// No description provided for @authHeaderSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Login & Register'**
  String get authHeaderSubtitle;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome!'**
  String get welcomeTitle;

  /// No description provided for @signInToContinue.
  ///
  /// In en, this message translates to:
  /// **'Sign in to continue'**
  String get signInToContinue;

  /// No description provided for @createAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Create an account'**
  String get createAccountTitle;

  /// No description provided for @joinTuniTranspo.
  ///
  /// In en, this message translates to:
  /// **'Join TuniTranspo'**
  String get joinTuniTranspo;

  /// No description provided for @forgotPasswordShort.
  ///
  /// In en, this message translates to:
  /// **'Forgot?'**
  String get forgotPasswordShort;

  /// No description provided for @orLabel.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get orLabel;

  /// No description provided for @resetPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetPasswordTitle;

  /// No description provided for @resetPasswordPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter your email address to receive a reset link'**
  String get resetPasswordPrompt;

  /// No description provided for @sendingResetLink.
  ///
  /// In en, this message translates to:
  /// **'Sending reset link...'**
  String get sendingResetLink;

  /// No description provided for @resetLinkSent.
  ///
  /// In en, this message translates to:
  /// **'Check your email for the reset link'**
  String get resetLinkSent;

  /// No description provided for @errorPrefix.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorPrefix(Object message);

  /// No description provided for @fixFormErrors.
  ///
  /// In en, this message translates to:
  /// **'Please fix the form errors'**
  String get fixFormErrors;

  /// No description provided for @fillAllFieldsCorrectly.
  ///
  /// In en, this message translates to:
  /// **'Please fill all fields correctly'**
  String get fillAllFieldsCorrectly;

  /// No description provided for @loginSuccess.
  ///
  /// In en, this message translates to:
  /// **'Login successful!'**
  String get loginSuccess;

  /// No description provided for @signupSuccess.
  ///
  /// In en, this message translates to:
  /// **'Account created successfully!'**
  String get signupSuccess;

  /// No description provided for @emailVerificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify your email'**
  String get emailVerificationTitle;

  /// No description provided for @emailVerificationMessage.
  ///
  /// In en, this message translates to:
  /// **'A verification email has been sent to {email}. Please check your inbox and click the link before signing in.'**
  String emailVerificationMessage(Object email);

  /// No description provided for @emailNotVerified.
  ///
  /// In en, this message translates to:
  /// **'Your email is not yet verified. Please check your inbox.'**
  String get emailNotVerified;

  /// No description provided for @resendVerificationEmail.
  ///
  /// In en, this message translates to:
  /// **'Resend verification email'**
  String get resendVerificationEmail;

  /// No description provided for @verificationEmailResent.
  ///
  /// In en, this message translates to:
  /// **'Verification email resent. Check your inbox.'**
  String get verificationEmailResent;

  /// No description provided for @usernameTaken.
  ///
  /// In en, this message translates to:
  /// **'This username is already taken. Please choose another.'**
  String get usernameTaken;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get loginFailed;

  /// No description provided for @signupFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign up failed'**
  String get signupFailed;

  /// No description provided for @googleSignInSuccess.
  ///
  /// In en, this message translates to:
  /// **'Signed in with Google!'**
  String get googleSignInSuccess;

  /// No description provided for @googleSignInFailed.
  ///
  /// In en, this message translates to:
  /// **'Google sign in failed'**
  String get googleSignInFailed;

  /// No description provided for @signInWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get signInWithGoogle;

  /// No description provided for @signUpWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign up with Google'**
  String get signUpWithGoogle;

  /// No description provided for @favoriteUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to update favorites.'**
  String get favoriteUpdateFailed;

  /// No description provided for @searchByNameOrEmail.
  ///
  /// In en, this message translates to:
  /// **'Search by name or email…'**
  String get searchByNameOrEmail;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @filterActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get filterActive;

  /// No description provided for @filterInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get filterInactive;

  /// No description provided for @filterBanned.
  ///
  /// In en, this message translates to:
  /// **'Banned'**
  String get filterBanned;

  /// No description provided for @filterBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get filterBlocked;

  /// No description provided for @noUsersFound.
  ///
  /// In en, this message translates to:
  /// **'No users found.'**
  String get noUsersFound;

  /// No description provided for @noUsersMatchFilter.
  ///
  /// In en, this message translates to:
  /// **'No users match the current filter.'**
  String get noUsersMatchFilter;

  /// No description provided for @noJourneysMatchFilter.
  ///
  /// In en, this message translates to:
  /// **'No journeys match this search.'**
  String get noJourneysMatchFilter;

  /// No description provided for @statusActive.
  ///
  /// In en, this message translates to:
  /// **'Status: Active'**
  String get statusActive;

  /// No description provided for @statusBlocked.
  ///
  /// In en, this message translates to:
  /// **'Status: Blocked'**
  String get statusBlocked;

  /// No description provided for @statusBannedUntil.
  ///
  /// In en, this message translates to:
  /// **'Status: Banned until {date}'**
  String statusBannedUntil(Object date);

  /// No description provided for @statusBanned.
  ///
  /// In en, this message translates to:
  /// **'Status: Banned'**
  String get statusBanned;

  /// No description provided for @adminActions.
  ///
  /// In en, this message translates to:
  /// **'Admin Actions'**
  String get adminActions;

  /// No description provided for @adminActionsPrompt.
  ///
  /// In en, this message translates to:
  /// **'Select an action for this user.'**
  String get adminActionsPrompt;

  /// No description provided for @banFor3Days.
  ///
  /// In en, this message translates to:
  /// **'Ban for 3 days'**
  String get banFor3Days;

  /// No description provided for @banFor7Days.
  ///
  /// In en, this message translates to:
  /// **'Ban for 7 days'**
  String get banFor7Days;

  /// No description provided for @blockPermanently.
  ///
  /// In en, this message translates to:
  /// **'Block permanently'**
  String get blockPermanently;

  /// No description provided for @unblockUser.
  ///
  /// In en, this message translates to:
  /// **'Unblock user'**
  String get unblockUser;

  /// No description provided for @userBannedDays.
  ///
  /// In en, this message translates to:
  /// **'User banned for {days} days.'**
  String userBannedDays(int days);

  /// No description provided for @userBlockedPermanently.
  ///
  /// In en, this message translates to:
  /// **'User blocked permanently.'**
  String get userBlockedPermanently;

  /// No description provided for @userUnblocked.
  ///
  /// In en, this message translates to:
  /// **'User unblocked successfully.'**
  String get userUnblocked;

  /// No description provided for @accountBlockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Account Blocked'**
  String get accountBlockedTitle;

  /// No description provided for @accountBlockedBody.
  ///
  /// In en, this message translates to:
  /// **'Your account has been permanently blocked by an administrator.'**
  String get accountBlockedBody;

  /// No description provided for @accountBannedTitle.
  ///
  /// In en, this message translates to:
  /// **'Account Banned'**
  String get accountBannedTitle;

  /// No description provided for @accountBannedUntil.
  ///
  /// In en, this message translates to:
  /// **'Your account has been banned until {date}.'**
  String accountBannedUntil(Object date);

  /// No description provided for @accountBannedBody.
  ///
  /// In en, this message translates to:
  /// **'Your account has been banned by an administrator.'**
  String get accountBannedBody;

  /// No description provided for @firestoreUpdateError.
  ///
  /// In en, this message translates to:
  /// **'Unable to update user. Check Firestore permissions.'**
  String get firestoreUpdateError;

  /// No description provided for @journeyDetails.
  ///
  /// In en, this message translates to:
  /// **'Journey details'**
  String get journeyDetails;

  /// No description provided for @journeySteps.
  ///
  /// In en, this message translates to:
  /// **'Journey steps'**
  String get journeySteps;

  /// No description provided for @totalDuration.
  ///
  /// In en, this message translates to:
  /// **'Total duration'**
  String get totalDuration;

  /// No description provided for @fare.
  ///
  /// In en, this message translates to:
  /// **'Fare'**
  String get fare;

  /// No description provided for @journeyType.
  ///
  /// In en, this message translates to:
  /// **'Journey type'**
  String get journeyType;

  /// No description provided for @transfers.
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get transfers;

  /// No description provided for @direct.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get direct;

  /// No description provided for @interactiveMap.
  ///
  /// In en, this message translates to:
  /// **'Interactive map'**
  String get interactiveMap;

  /// No description provided for @settingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get settingsSaved;

  /// No description provided for @mode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get mode;

  /// No description provided for @minimum6Characters.
  ///
  /// In en, this message translates to:
  /// **'At least 6 characters'**
  String get minimum6Characters;

  /// No description provided for @uppercaseLetter.
  ///
  /// In en, this message translates to:
  /// **'Uppercase letter (A-Z)'**
  String get uppercaseLetter;

  /// No description provided for @lowercaseLetter.
  ///
  /// In en, this message translates to:
  /// **'Lowercase letter (a-z)'**
  String get lowercaseLetter;

  /// No description provided for @digit.
  ///
  /// In en, this message translates to:
  /// **'Digit (0-9)'**
  String get digit;

  /// No description provided for @specialCharacter.
  ///
  /// In en, this message translates to:
  /// **'Special character (!@#...)'**
  String get specialCharacter;

  /// No description provided for @passwordTooWeak.
  ///
  /// In en, this message translates to:
  /// **'Password is too weak'**
  String get passwordTooWeak;

  /// No description provided for @passwordIsRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get passwordIsRequired;

  /// No description provided for @emailIsRequired.
  ///
  /// In en, this message translates to:
  /// **'Email is required'**
  String get emailIsRequired;

  /// No description provided for @invalidEmailFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid email format'**
  String get invalidEmailFormat;

  /// No description provided for @fieldIsRequired.
  ///
  /// In en, this message translates to:
  /// **'{fieldName} is required'**
  String fieldIsRequired(Object fieldName);

  /// No description provided for @fieldMinLength.
  ///
  /// In en, this message translates to:
  /// **'{fieldName} must be at least {length} characters'**
  String fieldMinLength(Object fieldName, int length);

  /// No description provided for @fieldMaxLength.
  ///
  /// In en, this message translates to:
  /// **'{fieldName} must be at most {length} characters'**
  String fieldMaxLength(Object fieldName, int length);

  /// No description provided for @fieldCanOnlyContainLetters.
  ///
  /// In en, this message translates to:
  /// **'{fieldName} can only contain letters'**
  String fieldCanOnlyContainLetters(Object fieldName);

  /// No description provided for @usernameIsRequired.
  ///
  /// In en, this message translates to:
  /// **'Username is required'**
  String get usernameIsRequired;

  /// No description provided for @usernameMinLength.
  ///
  /// In en, this message translates to:
  /// **'Username must be at least 3 characters'**
  String get usernameMinLength;

  /// No description provided for @usernameMaxLength.
  ///
  /// In en, this message translates to:
  /// **'Username must be at most 20 characters'**
  String get usernameMaxLength;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @editJourneyTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit journey'**
  String get editJourneyTitle;

  /// No description provided for @addJourneyTitle.
  ///
  /// In en, this message translates to:
  /// **'Add journey'**
  String get addJourneyTitle;

  /// No description provided for @journeyTypeField.
  ///
  /// In en, this message translates to:
  /// **'Type (Bus, Metro, Train)'**
  String get journeyTypeField;

  /// No description provided for @departureTime.
  ///
  /// In en, this message translates to:
  /// **'Departure time'**
  String get departureTime;

  /// No description provided for @journeyUpdatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Journey updated successfully'**
  String get journeyUpdatedSuccess;

  /// No description provided for @journeyAddedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Journey added successfully'**
  String get journeyAddedSuccess;

  /// No description provided for @journeysLoadError.
  ///
  /// In en, this message translates to:
  /// **'Unable to load journeys'**
  String get journeysLoadError;

  /// No description provided for @noJourneysFound.
  ///
  /// In en, this message translates to:
  /// **'No journeys found'**
  String get noJourneysFound;

  /// No description provided for @editStationTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit station'**
  String get editStationTitle;

  /// No description provided for @addStationTitle.
  ///
  /// In en, this message translates to:
  /// **'Add station'**
  String get addStationTitle;

  /// No description provided for @stationName.
  ///
  /// In en, this message translates to:
  /// **'Station name'**
  String get stationName;

  /// No description provided for @stationType.
  ///
  /// In en, this message translates to:
  /// **'Type (Metro, Bus, Train)'**
  String get stationType;

  /// No description provided for @stationUpdatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Station updated successfully'**
  String get stationUpdatedSuccess;

  /// No description provided for @stationAddedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Station added successfully'**
  String get stationAddedSuccess;

  /// No description provided for @stationsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Unable to load stations'**
  String get stationsLoadError;

  /// No description provided for @noStationsFound.
  ///
  /// In en, this message translates to:
  /// **'No stations found'**
  String get noStationsFound;

  /// No description provided for @editTariffTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit tariff'**
  String get editTariffTitle;

  /// No description provided for @addTariffTitle.
  ///
  /// In en, this message translates to:
  /// **'Add tariff'**
  String get addTariffTitle;

  /// No description provided for @operatorId.
  ///
  /// In en, this message translates to:
  /// **'Operator ID'**
  String get operatorId;

  /// No description provided for @fromStationId.
  ///
  /// In en, this message translates to:
  /// **'From station ID'**
  String get fromStationId;

  /// No description provided for @toStationId.
  ///
  /// In en, this message translates to:
  /// **'To station ID'**
  String get toStationId;

  /// No description provided for @price.
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get price;

  /// No description provided for @currency.
  ///
  /// In en, this message translates to:
  /// **'Currency'**
  String get currency;

  /// No description provided for @tariffClass.
  ///
  /// In en, this message translates to:
  /// **'Class'**
  String get tariffClass;

  /// No description provided for @validFrom.
  ///
  /// In en, this message translates to:
  /// **'Valid from'**
  String get validFrom;

  /// No description provided for @validTo.
  ///
  /// In en, this message translates to:
  /// **'Valid to'**
  String get validTo;

  /// No description provided for @notes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notes;

  /// No description provided for @dateFormatHint.
  ///
  /// In en, this message translates to:
  /// **'Date format: YYYY-MM-DD'**
  String get dateFormatHint;

  /// No description provided for @invalidPrice.
  ///
  /// In en, this message translates to:
  /// **'Invalid price.'**
  String get invalidPrice;

  /// No description provided for @invalidDateFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid date format.'**
  String get invalidDateFormat;

  /// No description provided for @tariffUpdatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Tariff updated successfully'**
  String get tariffUpdatedSuccess;

  /// No description provided for @tariffAddedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Tariff added successfully'**
  String get tariffAddedSuccess;

  /// No description provided for @tariffsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Unable to load tariffs'**
  String get tariffsLoadError;

  /// No description provided for @noTariffsFound.
  ///
  /// In en, this message translates to:
  /// **'No tariffs found'**
  String get noTariffsFound;

  /// No description provided for @searchTariffsHint.
  ///
  /// In en, this message translates to:
  /// **'Search by operator or station…'**
  String get searchTariffsHint;

  /// No description provided for @tariffFilterActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get tariffFilterActive;

  /// No description provided for @tariffFilterExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get tariffFilterExpired;

  /// No description provided for @noTariffsMatchFilter.
  ///
  /// In en, this message translates to:
  /// **'No tariffs match the current filter.'**
  String get noTariffsMatchFilter;

  /// No description provided for @composeNotification.
  ///
  /// In en, this message translates to:
  /// **'Compose a notification'**
  String get composeNotification;

  /// No description provided for @title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// No description provided for @content.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get content;

  /// No description provided for @recipients.
  ///
  /// In en, this message translates to:
  /// **'Recipients'**
  String get recipients;

  /// No description provided for @allUsers.
  ///
  /// In en, this message translates to:
  /// **'All users'**
  String get allUsers;

  /// No description provided for @appUsers.
  ///
  /// In en, this message translates to:
  /// **'App users'**
  String get appUsers;

  /// No description provided for @drivers.
  ///
  /// In en, this message translates to:
  /// **'Drivers'**
  String get drivers;

  /// No description provided for @sendingInProgress.
  ///
  /// In en, this message translates to:
  /// **'Sending...'**
  String get sendingInProgress;

  /// No description provided for @sendNotificationAction.
  ///
  /// In en, this message translates to:
  /// **'Send notification'**
  String get sendNotificationAction;

  /// No description provided for @notificationsHistory.
  ///
  /// In en, this message translates to:
  /// **'Notifications history'**
  String get notificationsHistory;

  /// No description provided for @notificationsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Unable to load notifications'**
  String get notificationsLoadError;

  /// No description provided for @noNotificationSentYet.
  ///
  /// In en, this message translates to:
  /// **'No notifications sent yet'**
  String get noNotificationSentYet;

  /// No description provided for @notificationSavedForRecipients.
  ///
  /// In en, this message translates to:
  /// **'Notification saved for {count} recipients'**
  String notificationSavedForRecipients(int count);

  /// No description provided for @recipientsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} recipients'**
  String recipientsCount(int count);

  /// No description provided for @authErrorWeakPassword.
  ///
  /// In en, this message translates to:
  /// **'The password provided is too weak. Please use a stronger password.'**
  String get authErrorWeakPassword;

  /// No description provided for @authErrorEmailAlreadyInUse.
  ///
  /// In en, this message translates to:
  /// **'This email is already registered. Please sign in or use a different email.'**
  String get authErrorEmailAlreadyInUse;

  /// No description provided for @authErrorInvalidEmail.
  ///
  /// In en, this message translates to:
  /// **'The email address is invalid. Please check and try again.'**
  String get authErrorInvalidEmail;

  /// No description provided for @authErrorUserDisabled.
  ///
  /// In en, this message translates to:
  /// **'This user account has been disabled.'**
  String get authErrorUserDisabled;

  /// No description provided for @authErrorUserNotFound.
  ///
  /// In en, this message translates to:
  /// **'No account found with this email address.'**
  String get authErrorUserNotFound;

  /// No description provided for @authErrorWrongPassword.
  ///
  /// In en, this message translates to:
  /// **'The password is incorrect. Please try again.'**
  String get authErrorWrongPassword;

  /// No description provided for @authErrorTooManyRequests.
  ///
  /// In en, this message translates to:
  /// **'Too many login attempts. Please try again later.'**
  String get authErrorTooManyRequests;

  /// No description provided for @authErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'An authentication error occurred. Please try again.'**
  String get authErrorGeneric;

  /// No description provided for @authErrorAccountCreationFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to create user account.'**
  String get authErrorAccountCreationFailed;

  /// No description provided for @authErrorPasswordResetFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to send email. Please check your email address.'**
  String get authErrorPasswordResetFailed;

  /// No description provided for @authErrorAccountDeactivated.
  ///
  /// In en, this message translates to:
  /// **'Your account has been deactivated by an administrator. Please contact support for more information.'**
  String get authErrorAccountDeactivated;

  /// No description provided for @useCurrentLocationButton.
  ///
  /// In en, this message translates to:
  /// **'Use my current location'**
  String get useCurrentLocationButton;

  /// No description provided for @disableCurrentLocation.
  ///
  /// In en, this message translates to:
  /// **'Disable current location'**
  String get disableCurrentLocation;

  /// No description provided for @journeySearchResolutionFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed. Please check the stations you entered.'**
  String get journeySearchResolutionFailed;

  /// No description provided for @unableResolveCurrentLocation.
  ///
  /// In en, this message translates to:
  /// **'Unable to resolve your current location.'**
  String get unableResolveCurrentLocation;

  /// No description provided for @noNearbyStationFromLocation.
  ///
  /// In en, this message translates to:
  /// **'No nearby station found from your current location.'**
  String get noNearbyStationFromLocation;

  /// No description provided for @stationNotFound.
  ///
  /// In en, this message translates to:
  /// **'No station found for \'{query}\'.'**
  String stationNotFound(Object query);

  /// No description provided for @stationNotFoundWithSuggestions.
  ///
  /// In en, this message translates to:
  /// **'No station found for \'{query}\'. Here are the closest matches: {suggestions}'**
  String stationNotFoundWithSuggestions(Object query, Object suggestions);

  /// No description provided for @results.
  ///
  /// In en, this message translates to:
  /// **'Results'**
  String get results;

  /// No description provided for @routeMap.
  ///
  /// In en, this message translates to:
  /// **'Route Map'**
  String get routeMap;

  /// No description provided for @lineLabel.
  ///
  /// In en, this message translates to:
  /// **'Line'**
  String get lineLabel;

  /// No description provided for @legendStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get legendStart;

  /// No description provided for @legendStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get legendStop;

  /// No description provided for @legendEnd.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get legendEnd;

  /// No description provided for @failedToLoadOlderMessages.
  ///
  /// In en, this message translates to:
  /// **'Failed to load older messages.'**
  String get failedToLoadOlderMessages;

  /// No description provided for @reasonBestPrice.
  ///
  /// In en, this message translates to:
  /// **'Best price'**
  String get reasonBestPrice;

  /// No description provided for @reasonFastest.
  ///
  /// In en, this message translates to:
  /// **'Fastest'**
  String get reasonFastest;

  /// No description provided for @reasonBestOverall.
  ///
  /// In en, this message translates to:
  /// **'Best overall'**
  String get reasonBestOverall;

  /// No description provided for @departureStationLabel.
  ///
  /// In en, this message translates to:
  /// **'Departure station'**
  String get departureStationLabel;

  /// No description provided for @arrivalStationLabel.
  ///
  /// In en, this message translates to:
  /// **'Arrival station'**
  String get arrivalStationLabel;

  /// No description provided for @tripDurationLabel.
  ///
  /// In en, this message translates to:
  /// **'Trip duration'**
  String get tripDurationLabel;

  /// No description provided for @tariffLabel.
  ///
  /// In en, this message translates to:
  /// **'Fare'**
  String get tariffLabel;

  /// No description provided for @onDemand.
  ///
  /// In en, this message translates to:
  /// **'On demand'**
  String get onDemand;

  /// No description provided for @noServiceTonightPrefix.
  ///
  /// In en, this message translates to:
  /// **'No service tonight. Next departure tomorrow at '**
  String get noServiceTonightPrefix;

  /// No description provided for @routeTemporarilyDisabled.
  ///
  /// In en, this message translates to:
  /// **'Route temporarily disabled'**
  String get routeTemporarilyDisabled;

  /// No description provided for @moreDetails.
  ///
  /// In en, this message translates to:
  /// **'More details'**
  String get moreDetails;

  /// No description provided for @sendTooFast.
  ///
  /// In en, this message translates to:
  /// **'Please wait before sending again.'**
  String get sendTooFast;

  /// No description provided for @sendNotificationCooldown.
  ///
  /// In en, this message translates to:
  /// **'Please wait {seconds} seconds before sending again.'**
  String sendNotificationCooldown(int seconds);

  /// No description provided for @sendNotificationResend.
  ///
  /// In en, this message translates to:
  /// **'Resend in {seconds}s'**
  String sendNotificationResend(int seconds);
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['ar', 'en', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar': return AppLocalizationsAr();
    case 'en': return AppLocalizationsEn();
    case 'fr': return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
