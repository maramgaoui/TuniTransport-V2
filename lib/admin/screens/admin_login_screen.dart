import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tuni_transport/l10n/app_localizations.dart';
import 'package:tuni_transport/admin/controllers/admin_auth_controller.dart';
import 'package:tuni_transport/theme/app_theme.dart';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  // Accepts either a real email address or a legacy matricule number.
  final _emailOrMatriculeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _adminAuthController = AdminAuthController();

  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailOrMatriculeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleForgotPassword() async {
    final inputController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          var isSending = false;
          String? resultMessage;
          bool isSuccess = false;

          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: const Text('Mot de passe oublié'),
              content: resultMessage != null
                  ? Text(
                      resultMessage!,
                      style: TextStyle(
                        color: isSuccess ? Colors.green : Colors.red,
                      ),
                    )
                  : Form(
                      key: formKey,
                      child: TextFormField(
                        controller: inputController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email ou Matricule',
                          prefixIcon: Icon(Icons.badge_outlined),
                          helperText: 'Entrez votre email ou votre matricule',
                        ),
                        validator: (v) =>
                            (v?.trim().isEmpty ?? true) ? 'Champ obligatoire' : null,
                      ),
                    ),
              actions: <Widget>[
                TextButton(
                  onPressed: isSending ? null : () => Navigator.pop(ctx),
                  child: Text(resultMessage != null ? 'Fermer' : 'Annuler'),
                ),
                if (resultMessage == null)
                  FilledButton(
                    onPressed: isSending
                        ? null
                        : () async {
                            if (!formKey.currentState!.validate()) return;
                            final input = inputController.text.trim();
                            setDialogState(() => isSending = true);

                            try {
                              String emailToReset;
                              if (input.contains('@')) {
                                emailToReset = input.toLowerCase();
                              } else {
                                // Promoted admin: look up real email from Firestore.
                                final doc = await FirebaseFirestore.instance
                                    .collection('admin_login_lookup')
                                    .doc(input.toLowerCase())
                                    .get();
                                final found =
                                    (doc.data()?['email'] as String? ?? '').trim();
                                if (found.isEmpty) {
                                  // Fall back to @admin.local for legacy accounts.
                                  emailToReset =
                                      '${input.toLowerCase()}@admin.local';
                                } else {
                                  emailToReset = found;
                                }
                              }
                              await FirebaseAuth.instance
                                  .sendPasswordResetEmail(email: emailToReset);
                              setDialogState(() {
                                isSending = false;
                                isSuccess = true;
                                resultMessage =
                                    'Si ce compte est enregistré, un lien de réinitialisation a été envoyé.';
                              });
                            } on FirebaseAuthException catch (e) {
                              final msg = switch (e.code) {
                                'user-not-found' =>
                                  'Aucun compte trouvé pour cet identifiant.',
                                'invalid-email' => 'Adresse email invalide.',
                                'too-many-requests' =>
                                  'Trop de tentatives. Réessayez plus tard.',
                                _ => e.message ?? 'Une erreur est survenue.',
                              };
                              setDialogState(() {
                                isSending = false;
                                isSuccess = false;
                                resultMessage = msg;
                              });
                            } catch (_) {
                              setDialogState(() {
                                isSending = false;
                                isSuccess = false;
                                resultMessage = 'Une erreur est survenue. Réessayez.';
                              });
                            }
                          },
                    child: isSending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Envoyer'),
                  ),
              ],
            ),
          );
        },
      );
    } finally {
      inputController.dispose();
    }
  }

  Future<void> _handleAdminLogin() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final result = await _adminAuthController.login(
      emailOrMatricule: _emailOrMatriculeController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.isAuthenticated) {
      context.go('/admin');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? l10n.invalidAdminCredentials),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.adminLogin),
        backgroundColor: AppTheme.primaryTeal,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/auth'),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.administratorAccess,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    key: const Key('admin_login_matricule_field'),
                    controller: _emailOrMatriculeController,
                    decoration: InputDecoration(
                      labelText: 'Email ou Matricule',
                      hintText: 'votre@email.com  ou  123456',
                      prefixIcon: const Icon(Icons.badge_outlined),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.requiredField;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const Key('admin_login_password_field'),
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: l10n.password,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    obscureText: _obscurePassword,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.requiredField;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 22),
                  ElevatedButton(
                    key: const Key('admin_login_submit_button'),
                    onPressed: _isLoading ? null : _handleAdminLogin,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.login),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _isLoading ? null : _handleForgotPassword,
                    child: const Text('Mot de passe oublié ?'),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    key: const Key('admin_login_back_to_user_button'),
                    onPressed: () => context.go('/auth'),
                    icon: const Icon(Icons.arrow_back),
                    label: Text(l10n.backToUserLogin),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
