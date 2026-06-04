import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/constants/avatar_options.dart';
import 'package:tuni_transport/controllers/profile_controller.dart';
import 'package:tuni_transport/controllers/auth_controller.dart';
import 'package:tuni_transport/models/user_model.dart';
import 'package:tuni_transport/utils/validation_utils.dart';

import '../theme/app_theme.dart';
import '../widgets/app_header.dart';
import '../widgets/app_settings.dart';
import '../widgets/profile_shared_widgets.dart';
import '../widgets/validated_text_field.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.showAppBar = true,
    this.showInlineActions = true,
    this.onActionStateChanged,
    this.isAdminContext = false,
  });

  final bool showAppBar;
  final bool showInlineActions;
  final VoidCallback? onActionStateChanged;
  final bool isAdminContext;

  @override
  State<ProfileScreen> createState() => ProfileScreenState();
}

class ProfileScreenState extends State<ProfileScreen> {
  late ProfileController _profileController;
  late AuthController _authController;
  bool _isEditing = false;
  bool _isLoading = false;
  String? _lastSyncedProfileFingerprint;
  late String _selectedLanguage;
  late ThemeMode _themeMode;

  // Text controllers for editing
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _usernameController;

  final _formKey = GlobalKey<FormState>();

  String _adminTypeLabel(String? type) => switch (type) {
    'bus'            => 'Admin Bus (TRANSTU)',
    'metro_train'    => 'Admin Métro / Train',
    'taxicollectifs' => 'Admin Taxi Collectifs',
    'louage'         => 'Admin Louage',
    'super_admin'    => 'Super Admin',
    _                => type ?? '-',
  };

  bool get _isPrivilegedReadOnlyMode {
    return _authController.isActingAsUser &&
        (_authController.cachedSession?.isPrivileged ?? false);
  }

  bool get canShowHeaderActions => !_isPrivilegedReadOnlyMode;
  bool get isEditing => _isEditing;
  bool get isLoading => _isLoading;

  void startEditingFromParent() {
    if (!_isPrivilegedReadOnlyMode && mounted) {
      setState(() => _isEditing = true);
      widget.onActionStateChanged?.call();
    }
  }

  Future<void> submitEditsFromParent() async {
    if (_isPrivilegedReadOnlyMode || _isLoading || !mounted) return;
    final profile = await _profileController.getCurrentProfile();
    if (profile != null && mounted) {
      await _saveProfile(profile);
    }
    widget.onActionStateChanged?.call();
  }

  void openSettingsFromParent() {
    if (_isPrivilegedReadOnlyMode || !mounted) return;
    _showSettingsDialog();
  }

  @override
  void initState() {
    super.initState();
    _profileController = ProfileController();
    _authController = AuthController.instance;
    _selectedLanguage = 'fr';
    _themeMode = ThemeMode.light;
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _usernameController = TextEditingController();

    // Safety net: an admin not in user-mode should never land on the user
    // profile screen. Skip this redirect when explicitly in admin context
    // (e.g. /admin/profile or embedded in AdminDashboard).
    if (!widget.isAdminContext) {
      final session = _authController.cachedSession;
      if (session != null &&
          session.isPrivileged &&
          !_authController.isActingAsUser) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go('/admin');
        });
      }
    }
  }

  bool _prefsLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_prefsLoaded) {
      _prefsLoaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final settings = AppSettings.maybeOf(context);
        if (settings == null) return;
        _selectedLanguage = settings.settingsService.getLanguage();
        final themeSetting = settings.settingsService.getThemeMode();
        _themeMode = switch (themeSetting) {
          'dark' => ThemeMode.dark,
          'system' => ThemeMode.system,
          _ => ThemeMode.light,
        };
      });
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();

    super.dispose();
  }

  void _loadProfileData(User profile) {
    _firstNameController.text = profile.firstName ?? '';
    _lastNameController.text = profile.lastName ?? '';
    _usernameController.text = profile.username ?? '';

  }

  String _profileFingerprint(User profile) {
    return [
      profile.uid,
      profile.email,
      profile.firstName ?? '',
      profile.lastName ?? '',
      profile.username ?? '',
      profile.avatarId ?? '',
    ].join('|');
  }

  Future<void> _saveProfile(User profile) async {
    final l10n = AppLocalizations.of(context)!;
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      widget.onActionStateChanged?.call();

      final firstName = _firstNameController.text.trim();
      final lastName = _lastNameController.text.trim();
      final username = _usernameController.text.trim();
      final updatedProfile = profile.copyWith(
        firstName: firstName,
        lastName: lastName,
        username: username,
      );

      final success = await _profileController.updateProfile(updatedProfile);

  if (!mounted) return;

      setState(() => _isLoading = false);
      widget.onActionStateChanged?.call();

      if (success) {
        setState(() => _isEditing = false);
        widget.onActionStateChanged?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.profileUpdatedSuccessfully),
            backgroundColor: AppTheme.primaryTeal,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.profileUpdateFailed),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleSignOut() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.logout),
        content: Text(l10n.confirmSignOut),
        actions: [
          TextButton(
            key: const Key('profile_logout_cancel_button'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('profile_logout_confirm_button'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.logout),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await _authController.signOut();
    }
  }

  Future<void> _showAvatarPicker(User profile) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;

    final newAvatarId = await showAvatarPickerDialog(
      context,
      currentAvatarId: profile.avatarId ?? avatarOptions.first,
    );
    if (!mounted || newAvatarId == null) return;

    final success = await _profileController.updateProfileFields({
      'avatarId': newAvatarId,
      'customAvatarUrl': null,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? l10n.avatarUpdated : l10n.avatarUpdateFailed),
        backgroundColor: success ? AppTheme.primaryTeal : Colors.red,
      ),
    );
  }

  void _showChangePasswordDialog() {
    final l10n = AppLocalizations.of(context)!;
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool obscureCurrentPassword = true;
    bool obscureNewPassword = true;
    bool obscureConfirmPassword = true;

    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.changePassword),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Current password — plain field, no strength indicator needed.
                TextField(
                  controller: currentPasswordController,
                  obscureText: obscureCurrentPassword,
                  decoration: InputDecoration(
                    labelText: l10n.currentPassword,
                    suffixIcon: IconButton(
                      icon: Icon(obscureCurrentPassword
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setDialogState(() => obscureCurrentPassword = !obscureCurrentPassword),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                // New password — ValidatedTextField shows live strength indicator.
                ValidatedTextField(
                  controller: newPasswordController,
                  label: l10n.newPassword,
                  hintText: '••••••••',
                  prefixIcon: Icons.lock_outline,
                  validationType: 'password',
                  obscureText: obscureNewPassword,
                  isPasswordField: true,
                  onVisibilityToggle: () =>
                      setDialogState(() => obscureNewPassword = !obscureNewPassword),
                  // Rebuild so confirmPasswordValue stays in sync.
                  onValidationChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 16),
                // Confirm password — live match validation against new password.
                ValidatedTextField(
                  controller: confirmPasswordController,
                  label: l10n.confirmNewPassword,
                  hintText: '••••••••',
                  prefixIcon: Icons.lock_outline,
                  validationType: 'confirm_password',
                  confirmPasswordValue: newPasswordController.text,
                  obscureText: obscureConfirmPassword,
                  isPasswordField: true,
                  onVisibilityToggle: () =>
                      setDialogState(() => obscureConfirmPassword = !obscureConfirmPassword),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () async {
                final rootMessenger = ScaffoldMessenger.of(this.context);
                if (currentPasswordController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.enterCurrentPassword)),
                  );
                  return;
                }
                if (newPasswordController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.enterNewPassword)),
                  );
                  return;
                }
                if (confirmPasswordController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.confirmNewPasswordPrompt)),
                  );
                  return;
                }
                if (newPasswordController.text != confirmPasswordController.text) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.passwordsDoNotMatch)),
                  );
                  return;
                }
                if (newPasswordController.text.length < 6) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.passwordMinLength)),
                  );
                  return;
                }
                final strengthError = ValidationUtils.validatePassword(
                    newPasswordController.text);
                if (strengthError != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(strengthError),
                        backgroundColor: Colors.red),
                  );
                  return;
                }

                final errorMessage = await _profileController.changePassword(
                  currentPasswordController.text,
                  newPasswordController.text,
                );

                if (!context.mounted) return;
                if (errorMessage == null) {
                  Navigator.pop(context);
                  if (!mounted) return;
                  rootMessenger.showSnackBar(
                    SnackBar(
                      content: Text(l10n.passwordChangedSuccessfully),
                      backgroundColor: AppTheme.primaryTeal,
                    ),
                  );
                } else {
                  if (!mounted) return;
                  rootMessenger.showSnackBar(
                    SnackBar(
                      content: Text(errorMessage),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: Text(l10n.changePassword),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsDialog() {
    final l10n = AppLocalizations.of(context)!;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.settings),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Theme Mode Section
                Text(
                  l10n.themeMode,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.lightGrey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text(l10n.lightMode),
                          selected: _themeMode == ThemeMode.light,
                          onSelected: (_) =>
                              setDialogState(() => _themeMode = ThemeMode.light),
                        ),
                        ChoiceChip(
                          label: Text(l10n.darkMode),
                          selected: _themeMode == ThemeMode.dark,
                          onSelected: (_) =>
                              setDialogState(() => _themeMode = ThemeMode.dark),
                        ),
                        ChoiceChip(
                          label: Text(l10n.systemDefault),
                          selected: _themeMode == ThemeMode.system,
                          onSelected: (_) =>
                              setDialogState(() => _themeMode = ThemeMode.system),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Language Section
                Text(
                  l10n.language,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.lightGrey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text(l10n.french),
                          selected: _selectedLanguage == 'fr',
                          onSelected: (_) =>
                              setDialogState(() => _selectedLanguage = 'fr'),
                        ),
                        ChoiceChip(
                          label: Text(l10n.english),
                          selected: _selectedLanguage == 'en',
                          onSelected: (_) =>
                              setDialogState(() => _selectedLanguage = 'en'),
                        ),
                        ChoiceChip(
                          label: Text(l10n.arabic),
                          selected: _selectedLanguage == 'ar',
                          onSelected: (_) =>
                              setDialogState(() => _selectedLanguage = 'ar'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryTeal,
              ),
              onPressed: () async {
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  final settings = AppSettings.maybeOf(context);
                  if (settings == null) return;
                  // Save language preference
                  await settings.settingsService.setLanguage(_selectedLanguage);
                  
                  // Save and apply theme preference
                  final themeString = _themeMode == ThemeMode.dark ? 'dark' : 
                                     _themeMode == ThemeMode.system ? 'system' : 'light';
                  await settings.settingsService.setThemeMode(themeString);
                  
                  // Notify parent of theme change
                  settings.onThemeChanged(_themeMode);
                  settings.onLanguageChanged(_selectedLanguage);
                  
                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${l10n.settingsSaved} - ${l10n.mode}: ${_themeMode.name}, ${l10n.language}: $_selectedLanguage',
                      ),
                      backgroundColor: AppTheme.primaryTeal,
                    ),
                  );
                });
              },
              child: Text(
                l10n.save,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      body: Column(
        children: [
          if (widget.showAppBar)
            AppHeader(
              title: l10n.profile,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => context.go(
                    widget.isAdminContext ? '/admin' : '/home/journey-input'),
              ),
              trailing: !widget.showInlineActions
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_isEditing && !_isPrivilegedReadOnlyMode)
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.white),
                            onPressed: () {
                              setState(() => _isEditing = true);
                              widget.onActionStateChanged?.call();
                            },
                          ),
                        if (_isEditing && !_isPrivilegedReadOnlyMode)
                          IconButton(
                            icon: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor:
                                          AlwaysStoppedAnimation<Color>(
                                              Colors.white),
                                    ),
                                  )
                                : const Icon(Icons.check, color: Colors.white),
                            onPressed: _isLoading
                                ? null
                                : () async {
                                    final profile =
                                        await _profileController
                                            .getCurrentProfile();
                                    if (profile != null && mounted) {
                                      await _saveProfile(profile);
                                    }
                                  },
                          ),
                        if (!_isPrivilegedReadOnlyMode && !widget.isAdminContext)
                          IconButton(
                            icon: const Icon(Icons.settings, color: Colors.white),
                            onPressed: _showSettingsDialog,
                          ),
                      ],
                    ),
            ),
          Expanded(
            child: StreamBuilder<User?>(
              stream: _profileController.profileStream,
              builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final profile = snapshot.data;
          if (profile == null) {
            return const Center(
              child: Text('No profile data'),
            );
          }

          if (!_isEditing) {
            final fingerprint = _profileFingerprint(profile);
            if (_lastSyncedProfileFingerprint != fingerprint) {
              _loadProfileData(profile);
              _lastSyncedProfileFingerprint = fingerprint;
            }
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                if (!widget.showAppBar && widget.showInlineActions)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (!_isEditing && !_isPrivilegedReadOnlyMode)
                          IconButton(
                            icon: const Icon(Icons.edit),
                            tooltip: l10n.edit,
                            onPressed: () {
                              setState(() => _isEditing = true);
                              widget.onActionStateChanged?.call();
                            },
                          ),
                        if (_isEditing && !_isPrivilegedReadOnlyMode)
                          IconButton(
                            icon: _isLoading
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            tooltip: l10n.save,
                            onPressed: _isLoading
                                ? null
                                : () async {
                                    final profile =
                                        await _profileController.getCurrentProfile();
                                    if (profile != null && mounted) {
                                      await _saveProfile(profile);
                                    }
                                  },
                          ),
                        if (!_isPrivilegedReadOnlyMode && !widget.isAdminContext)
                          IconButton(
                            icon: const Icon(Icons.settings),
                            tooltip: l10n.settings,
                            onPressed: _showSettingsDialog,
                          ),
                      ],
                    ),
                  ),
                // Profile Header
                Center(
                  child: Column(
                    children: [
                      // User avatar with avatar picker
                      ProfileAvatarStack(
                        avatarId: profile.avatarId ??
                            (profile.username?.isNotEmpty == true
                                ? profile.username!
                                : profile.email),
                        customAvatarUrl: profile.customAvatarUrl,
                        onTap: () => _showAvatarPicker(profile),
                        disabled: _isPrivilegedReadOnlyMode,
                      ),
                      const SizedBox(height: 16),
                      // Full Name
                      Text(
                        '${profile.firstName ?? ''} ${profile.lastName ?? ''}'.trim(),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Username (if available)
                      if (profile.username != null && profile.username!.isNotEmpty)
                        Text(
                          '@${profile.username}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryTeal,
                          ),
                        ),
                      const SizedBox(height: 8),
                      // Email
                      Text(
                        profile.email,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.mediumGrey,
                        ),
                      ),
                      // Admin-type badge (admin context only)
                      if (widget.isAdminContext && profile.adminType != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryTeal.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: AppTheme.primaryTeal
                                    .withValues(alpha: 0.30)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.workspace_premium_outlined,
                                  size: 16, color: AppTheme.primaryTeal),
                              const SizedBox(width: 6),
                              Text(
                                _adminTypeLabel(profile.adminType),
                                style: const TextStyle(
                                  color: AppTheme.primaryTeal,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                // Profile Form or Details
                if (_isEditing)
                  _buildEditForm(profile)
                else
                  _buildProfileDetails(profile),
                const SizedBox(height: 32),
                if (!_isPrivilegedReadOnlyMode && !_profileController.isGoogleOnlyUser)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _showChangePasswordDialog,
                      icon: const Icon(Icons.lock),
                      label: Text(l10n.changePassword),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.darkTeal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                if (!_isPrivilegedReadOnlyMode && !_profileController.isGoogleOnlyUser)
                  const SizedBox(height: 16),
                // Sign Out Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    key: const Key('profile_logout_button'),
                    onPressed: _handleSignOut,
                    icon: const Icon(Icons.logout),
                    label: Text(l10n.logout),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileDetails(User profile) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProfileDetailRow(label: l10n.username, value: profile.username ?? l10n.notSet),
        ProfileDetailRow(label: l10n.firstName, value: profile.firstName ?? l10n.notSet),
        ProfileDetailRow(label: l10n.lastName, value: profile.lastName ?? l10n.notSet),
        ProfileDetailRow(label: l10n.email, value: profile.email),
        if (widget.isAdminContext && (profile.matricule?.isNotEmpty ?? false))
          ProfileDetailRow(
              label: l10n.matricule, value: profile.matricule!, locked: true),
      ],
    );
  }

  Widget _buildEditForm(User profile) {
    final l10n = AppLocalizations.of(context)!;
    return Form(
      key: _formKey,
      child: Column(
        children: [
          ProfileEditFields(
            firstNameController: _firstNameController,
            lastNameController: _lastNameController,
            usernameController: _usernameController,
          ),
          // Admin-only locked fields (visible in edit mode but not editable)
          if (widget.isAdminContext && profile.adminType != null) ...[
            const SizedBox(height: 16),
            _buildLockedField(
              icon: Icons.workspace_premium_outlined,
              label: l10n.role,
              value: _adminTypeLabel(profile.adminType),
            ),
          ],
          if (widget.isAdminContext &&
              (profile.matricule?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 16),
            _buildLockedField(
              icon: Icons.badge_outlined,
              label: l10n.matricule,
              value: profile.matricule!,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLockedField({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(children: [
        Icon(icon, color: AppTheme.mediumGrey, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.mediumGrey)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 16, color: AppTheme.textDark)),
            ],
          ),
        ),
        const Icon(Icons.lock_outline, size: 16, color: AppTheme.mediumGrey),
      ]),
    );
  }
}
